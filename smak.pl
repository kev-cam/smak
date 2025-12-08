#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use FindBin qw($RealBin);
use File::Path qw(make_path);
use POSIX qw(strftime);
use lib $RealBin;
use Smak qw(:all);

# Check for -cmake option early (passthrough to cmake)
if (@ARGV && $ARGV[0] eq '-cmake') {
    shift @ARGV;  # Remove -cmake
    # Execute cmake with remaining arguments
    exec('cmake', @ARGV);
    # exec never returns on success
    die "Failed to execute cmake: $!\n";
}

my $makefile = 'Makefile';
my $debug = 0;
my $help = 0;
my $script_file = '';
my $report = 0;
my $report_dir = '';
my $log_fh;
my $dry_run = 0;
my $silent = 0;
my $yes = 0;  # Auto-answer yes to prompts
my $jobs = 1;  # Number of parallel jobs (default: 1 = sequential)
my $cli = 0;  # CLI mode (interactive shell)

# Parse environment variable options first
if (defined $ENV{USR_SMAK_OPT}) {
    # Split the environment variable into arguments
    my @env_args = split(/\s+/, $ENV{USR_SMAK_OPT});
    # Save original @ARGV
    my @saved_argv = @ARGV;
    # Process environment options
    @ARGV = @env_args;
    GetOptions(
        'f|file|makefile=s' => \$makefile,
        'Kd|Kdebug' => \$debug,
        'h|help|Kh|Khelp' => \$help,
        'Ks|Kscript=s' => \$script_file,
        'Kreport' => \$report,
        'n|just-print|dry-run|recon' => \$dry_run,
        's|silent|quiet' => \$silent,
        'yes' => \$yes,
        'j|jobs:i' => \$jobs,  # :i means optional integer (allows -j and -j4)
        'cli' => \$cli,
    );
    # Restore and append remaining command line args
    @ARGV = @saved_argv;
}

# Parse command-line options (override environment)
GetOptions(
    'f|file|makefile=s' => \$makefile,
    'Kd|Kdebug' => \$debug,
    'h|help|Kh|Khelp' => \$help,
    'Ks|Kscript=s' => \$script_file,
    'Kreport' => \$report,
    'n|just-print|dry-run|recon' => \$dry_run,
    's|silent|quiet' => \$silent,
    'yes' => \$yes,
    'j|jobs:i' => \$jobs,  # :i means optional integer (allows -j and -j4)
    'cli' => \$cli,
) or die "Error in command line arguments\n";

# Handle -j without number (unlimited jobs, use CPU count)
if (defined $jobs && $jobs == 0) {
    # Try to detect CPU count
    my $cpu_count = 1;
    if (-f '/proc/cpuinfo') {
        $cpu_count = `grep -c ^processor /proc/cpuinfo 2>/dev/null` || 1;
        chomp $cpu_count;
    }
    $jobs = $cpu_count;
}

# Parse variable assignments and targets from remaining arguments
my @targets;
for my $arg (@ARGV) {
    if ($arg =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) {
        # Variable assignment (VAR=VALUE)
        Smak::set_cmd_var($1, $2);
    } else {
        # Target name
        push @targets, $arg;
    }
}

if ($help) {
    print_help();
    exit 0;
}

# Setup report directory if -Kreport is enabled
if ($report) {
    # Get project name from current directory
    use Cwd 'getcwd';
    my $cwd = getcwd();
    my $project_name = (split(/\//, $cwd))[-1];

    # Create date-stamped subdirectory in bugs directory where smak is located
    my $timestamp = strftime("%Y%m%d-%H%M%S", localtime);
    $report_dir = "$RealBin/bugs/$project_name-$timestamp";
    make_path($report_dir) or die "Cannot create report directory $report_dir: $!\n";

    # Open log file
    my $log_file = "$report_dir/build.log";
    open($log_fh, '>', $log_file) or die "Cannot open log file $log_file: $!\n";
    $log_fh->autoflush(1);

    # Enable report mode in the module
    set_report_mode(1, $log_fh);

    # Create smak.env file with environment variables for reproducing the build
    my $env_file = "$report_dir/smak.env";
    open(my $env_fh, '>', $env_file) or warn "Cannot create $env_file: $!\n";
    if ($env_fh) {
        print $env_fh "# Smak environment variables for bug report $timestamp\n";
        print $env_fh "# Source this file with: source smak.env\n\n";

        # Export smak-specific variables
        print $env_fh "export SMAK_INVOKED_AS='$ENV{SMAK_INVOKED_AS}'\n" if $ENV{SMAK_INVOKED_AS};
        print $env_fh "export SMAK_LAUNCHER='$ENV{SMAK_LAUNCHER}'\n" if $ENV{SMAK_LAUNCHER};

        # Export relevant build environment variables
        print $env_fh "export PATH='$ENV{PATH}'\n" if $ENV{PATH};
        print $env_fh "export SHELL='$ENV{SHELL}'\n" if $ENV{SHELL};
        print $env_fh "export USER='$ENV{USER}'\n" if $ENV{USER};
        print $env_fh "export HOME='$ENV{HOME}'\n" if $ENV{HOME};
        print $env_fh "export PWD='$ENV{PWD}'\n" if $ENV{PWD};

        # Export any USR_SMAK_OPT if set
        print $env_fh "export USR_SMAK_OPT='$ENV{USR_SMAK_OPT}'\n" if $ENV{USR_SMAK_OPT};

        close($env_fh);
    }

    # Copy Makefile(s) to bug directory for analysis
    use File::Copy;
    if (-f $makefile) {
        my $makefile_copy = "$report_dir/" . (split(/\//, $makefile))[-1];
        copy($makefile, $makefile_copy) or warn "Could not copy $makefile: $!\n";
    }

    # Capture directory listing for filesystem reconstruction
    my $listing_file = "$report_dir/directory-listing.txt";
    my $listing_pwd = $ENV{PWD} || `pwd`;
    chomp $listing_pwd;
    my $listing = `ls -lR . 2>&1`;
    open(my $listing_fh, '>', $listing_file) or warn "Cannot create $listing_file: $!\n";
    if ($listing_fh) {
        print $listing_fh "Directory listing from: $listing_pwd\n";
        print $listing_fh "=" x 50 . "\n\n";
        print $listing_fh $listing;
        close($listing_fh);
    }

    # Create tar file of Makefiles and source files for reconstruction
    my $tar_file = "$report_dir/files.tar";
    my @files_to_tar;

    # Always include the main Makefile if it exists
    push @files_to_tar, $makefile if -f $makefile;

    # Find other Makefiles and common source files
    my @patterns = qw(Makefile* makefile* *.mk *.make CMakeLists.txt);
    for my $pattern (@patterns) {
        my @found = glob($pattern);
        push @files_to_tar, @found;
    }

    # Parse Makefile(s) for include directives and add those files
    my @makefiles_to_scan = grep { -f $_ } @files_to_tar;
    my %processed_includes;
    while (@makefiles_to_scan) {
        my $mf = shift @makefiles_to_scan;
        next if $processed_includes{$mf}++;

        if (open(my $mf_fh, '<', $mf)) {
            while (my $line = <$mf_fh>) {
                # Match include and -include directives
                if ($line =~ /^-?include\s+(.+)/) {
                    my $inc = $1;
                    $inc =~ s/#.*$//;  # Remove comments
                    $inc =~ s/^\s+|\s+$//g;  # Trim whitespace

                    # Expand $(srcdir) and other simple variables
                    $inc =~ s/\$\(srcdir\)/./g;
                    $inc =~ s/\$\{srcdir\}/./g;

                    if (-f $inc) {
                        push @files_to_tar, $inc;
                        push @makefiles_to_scan, $inc;  # Recursively scan included files
                    }
                }
            }
            close($mf_fh);
        }
    }

    # Remove duplicates and non-existent files
    my %seen;
    @files_to_tar = grep { -f $_ && !$seen{$_}++ } @files_to_tar;

    # Create tar file if we have files to archive
    if (@files_to_tar) {
        my $files_list = join(' ', map { "'$_'" } @files_to_tar);
        system("tar -cf '$tar_file' $files_list 2>/dev/null");
        if (-f $tar_file && -s $tar_file) {
            # Create a list of archived files for reference
            my $tar_list = "$report_dir/files.txt";
            open(my $list_fh, '>', $tar_list);
            if ($list_fh) {
                print $list_fh "Files archived in files.tar:\n";
                print $list_fh join("\n", @files_to_tar) . "\n";
                close($list_fh);
            }
        }
    }

    # Print header to both terminal and log
    my $header = "=== SMAK BUILD REPORT ===\n" .
                 "Timestamp: $timestamp\n" .
                 "Makefile: $makefile\n" .
                 "Report directory: $report_dir\n" .
                 "=" x 50 . "\n\n";
    print STDOUT $header;
    print $log_fh $header;
}

sub print_help {
    print <<'HELP';
Usage: smak [options] [targets...]
   or: smak -cmake <cmake-args>

Options:
  -f, -file, -makefile FILE   Use FILE as a makefile (default: Makefile)
  -n, --just-print            Print commands without executing (dry-run)
  --dry-run, --recon          Same as -n
  -s, --silent, --quiet       Don't print commands being executed
  -j, --jobs [N]              Run N jobs in parallel (default: 1, -j = CPU count)
  -cli                        Enter CLI mode (interactive shell for building)
  -h, --help                  Display this help message
  --yes                       Auto-answer yes to prompts (for -Kreport)
  -cmake                      Run cmake with remaining arguments (passthrough)
  -Kd, -Kdebug                Enter interactive debug mode
  -Ks, -Kscript FILE          Load and execute smak commands from FILE
  -Kreport                    Create verbose build log and run make-cmp

Environment Variables:
  USR_SMAK_OPT                Options to prepend (e.g., "USR_SMAK_OPT=-Kd")

Examples:
  smak -n all                 Show what would be built without executing
  smak -s all                 Build silently without printing commands
  smak -cmake ..              Run cmake in parent directory
  smak -Ks fixes.smak all     Load fixes, then build target 'all'
  USR_SMAK_OPT='-Ks fixes.smak' smak target
  smak -Kreport all           Build with verbose logging to bugs directory
  smak -Kreport --yes all     Build with logging, auto-commit bug report

HELP
}

sub run_cli {
    use Term::ReadLine;

    print "Smak CLI mode - type 'help' for commands\n";
    print "Makefile: $makefile\n";
    print "Parallel jobs: $jobs\n";

    # Start job server now if parallel builds are configured
    my $jobserver_pid;
    if ($jobs > 1) {
        print "Starting job server...\n";
        start_job_server();
        $jobserver_pid = $Smak::job_server_pid;
    }
    print "\n";

    # Set up signal handlers for detach
    my $detached = 0;
    my $detach_handler = sub {
        $detached = 1;
    };
    local $SIG{INT} = $detach_handler;  # Ctrl-C

    my $term = Term::ReadLine->new('smak');

    my $line;
    while (defined($line = $term->readline('smak> '))) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;  # Trim whitespace

        next if $line eq '';  # Skip empty lines

        $term->addhistory($line) if $line =~ /\S/;

        my @words = split(/\s+/, $line);
        my $cmd = shift @words;

        if ($cmd eq 'quit' || $cmd eq 'exit' || $cmd eq 'q') {
            print "Shutting down and exiting...\n";
            return 1;  # Return 1 = stop job server

        } elsif ($cmd eq 'detach') {
            $detached = 1;
            last;

        } elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
            print <<'HELP';
Available commands:
  build <target>      Build the specified target
  list [pattern]      List all targets (optionally matching pattern)
  tasks, t            List pending and active tasks
  status              Show job server status (if parallel builds enabled)
  vars [pattern]      Show all variables (optionally matching pattern)
  deps <target>       Show dependencies for target
  kill                Kill all workers
  restart [N]         Restart workers (optionally specify count)
  detach              Detach from CLI, leave job server running
  help, h, ?          Show this help
  quit, exit, q       Shut down job server and exit

Keyboard shortcuts:
  Ctrl-C, Ctrl-D      Detach from CLI (same as 'detach' command)

Examples:
  build all           Build the 'all' target
  build clean         Build the 'clean' target
  list task           List targets matching 'task'
  deps foo.o          Show dependencies for foo.o
  tasks               List active and queued tasks
  restart 8           Restart workers with 8 workers
HELP

        } elsif ($cmd eq 'build' || $cmd eq 'b') {
            if (@words == 0) {
                # Build default target
                my $default_target = get_default_target();
                if (defined $default_target) {
                    print "Building default target: $default_target\n";
                    eval { build_target($default_target); };
                    if ($@) {
                        print "Build failed: $@\n";
                    } else {
                        print "Build succeeded.\n";
                    }
                } else {
                    print "No default target found.\n";
                }
            } else {
                # Build specified targets
                foreach my $target (@words) {
                    print "Building target: $target\n";
                    eval { build_target($target); };
                    if ($@) {
                        print "Build failed: $@\n";
                        last;
                    } else {
                        print "Build succeeded.\n";
                    }
                }
            }

        } elsif ($cmd eq 'list' || $cmd eq 'ls' || $cmd eq 'l') {
            my $pattern = @words > 0 ? $words[0] : '';
            my @targets = list_targets($pattern);

            if (@targets == 0) {
                print "No targets found.\n";
            } else {
                print "Targets:\n";
                foreach my $target (sort @targets) {
                    print "  $target\n";
                }
                print "\nTotal: " . scalar(@targets) . " targets\n";
            }

        } elsif ($cmd eq 'status' || $cmd eq 'st') {
            if ($jobs > 1 && defined $Smak::job_server_socket) {
                # Request status from job-master
                print "Job server running with $jobs workers (PID $Smak::job_server_pid)\n";
                # Could send STATUS request to job-master here
                print "Use: smak-attach -pid $Smak::job_server_pid\n";
            } elsif ($jobs > 1) {
                print "Job server configured for $jobs jobs but not currently active\n";
            } else {
                print "Sequential mode (no job server)\n";
            }

        } elsif ($cmd eq 'vars' || $cmd eq 'v') {
            my $pattern = @words > 0 ? $words[0] : '';
            my @vars = list_variables($pattern);

            if (@vars == 0) {
                print "No variables found.\n";
            } else {
                print "Variables:\n";
                foreach my $var (sort @vars) {
                    my $value = get_variable($var);
                    print "  $var = $value\n";
                }
                print "\nTotal: " . scalar(@vars) . " variables\n";
            }

        } elsif ($cmd eq 'deps' || $cmd eq 'd') {
            if (@words == 0) {
                print "Usage: deps <target>\n";
            } else {
                my $target = $words[0];
                show_dependencies($target);
            }

        } elsif ($cmd eq 'tasks' || $cmd eq 't') {
            if ($jobs > 1 && defined $Smak::job_server_socket) {
                # Request task list from job-master
                print $Smak::job_server_socket "LIST_TASKS\n";
                # Wait for response
                while (my $response = <$Smak::job_server_socket>) {
                    chomp $response;
                    last if $response eq 'TASKS_END';
                    print "$response\n";
                }
            } else {
                print "Job server not running.\n";
            }

        } elsif ($cmd eq 'kill') {
            if ($jobs > 1 && defined $Smak::job_server_socket) {
                print "Killing all workers...\n";
                print $Smak::job_server_socket "KILL_WORKERS\n";
                # Wait for response
                my $response = <$Smak::job_server_socket>;
                chomp $response if $response;
                print "$response\n" if $response;
            } else {
                print "Job server not running.\n";
            }

        } elsif ($cmd eq 'restart') {
            if ($jobs > 1 && defined $Smak::job_server_socket) {
                my $count = @words > 0 ? $words[0] : $jobs;
                print "Restarting workers ($count workers)...\n";
                print $Smak::job_server_socket "RESTART_WORKERS $count\n";
                # Wait for response
                my $response = <$Smak::job_server_socket>;
                chomp $response if $response;
                print "$response\n" if $response;
            } else {
                print "Job server not running.\n";
            }

        } else {
            print "Unknown command: $cmd\n";
            print "Type 'help' for available commands.\n";
        }

        # Check if detached by Ctrl-C
        if ($detached) {
            last;
        }
    }

    # After loop: check if we detached or quit normally
    # If $detached was set, it was explicit detach or Ctrl-C
    # If loop ended without $detached, it was Ctrl-D (EOF) - also treat as detach
    if ($detached || !defined($line)) {
        print "\nDetached from CLI.\n";
        if ($jobserver_pid) {
            print "Job server still running (PID $jobserver_pid).\n";
            print "To reconnect: ./smak-attach -pid $jobserver_pid\n";

            # Fork to keep master connection alive in background
            my $bg_pid = fork();
            if ($bg_pid == 0) {
                # Child process: keep master connection alive
                # Close STDIN/STDOUT/STDERR to fully detach
                close(STDIN);
                close(STDOUT);
                close(STDERR);

                # Just wait for job server to finish or be killed
                # The socket connection to job-master stays alive
                sleep while 1;
                exit 0;
            }
            # Parent continues to exit
        }
        return 0;  # Return 0 = don't stop job server
    }

    # Normal quit command
    return 1;  # Return 1 = stop job server
}

# Set dry-run mode if requested
if ($dry_run) {
    set_dry_run_mode(1);
}

# Set silent mode if requested
if ($silent) {
    set_silent_mode(1);
}

# Set number of parallel jobs
set_jobs($jobs);

# Start job server if parallel builds are requested
# Skip in debug, dry-run, or CLI mode
unless ($debug || $dry_run || $cli) {
    start_job_server();
}

# Parse the makefile
parse_makefile($makefile);

# Handle Makefile remaking (like GNU make)
# Check if the makefile itself has a rule and needs to be remade
# Skip in dry-run mode to avoid executing remake commands
unless ($debug || $dry_run) {
    my $makefile_has_rule = 0;
    my $key = "$makefile\t$makefile";

    # Check if makefile is a target
    if (exists $Smak::fixed_deps{$key} || exists $Smak::pattern_deps{$key} || exists $Smak::pseudo_deps{$key}) {
        $makefile_has_rule = 1;
    }

    if ($makefile_has_rule && -f $makefile) {
        # Get current modification time
        my $old_mtime = (stat($makefile))[9];

        # Try to build the makefile
        eval {
            build_target($makefile);
        };

        # Check if makefile was modified
        if (-f $makefile) {
            my $new_mtime = (stat($makefile))[9];
            if ($new_mtime > $old_mtime) {
                # Makefile was remade, re-parse it
                parse_makefile($makefile);
            }
        }
    }
}

# Execute script file if specified
if ($script_file) {
    execute_script($script_file);
}

# If CLI mode, enter interactive loop
if ($cli) {
    my $should_stop = run_cli();
    if ($should_stop) {
        stop_job_server();
    }
    exit 0;
}

# If not in debug mode, build targets
if (!$debug) {
    my $build_failed = 0;
    my $build_error = '';

    # Wrap build in eval to catch failures but still allow report prompt
    eval {
        # If no targets specified, build default target (like gmake)
        if (!@targets) {
            my $default_target = get_default_target();
            if (defined $default_target) {
                build_target($default_target);
            } else {
                die "smak: *** No targets. Stop.\n";
            }
        } else {
            # Build specified targets
            foreach my $target (@targets) {
                build_target($target);
            }
        }
    };

    # Check if build failed
    if ($@) {
        $build_failed = 1;
        $build_error = $@;
    }

    # Stop job server and clean up workers
    stop_job_server();

    # If in report mode, run dry-run comparison between smak and make
    if ($report) {
        tee_print("\n" . "=" x 50 . "\n");
        tee_print("Running dry-run comparison (smak -n vs make)...\n");
        tee_print("=" x 50 . "\n");

        # Build target list for commands
        my $target_args = @targets ? join(' ', @targets) : '';

        # Run smak -n
        my $smak_dryrun_file = "$report_dir/smak-dryrun.txt";
        my $smak_cmd = "$ENV{SMAK_LAUNCHER} -n -f '$makefile' $target_args 2>&1";
        my $smak_result = `$smak_cmd`;
        open(my $smak_fh, '>', $smak_dryrun_file) or warn "Cannot write to $smak_dryrun_file: $!\n";
        if ($smak_fh) {
            print $smak_fh $smak_result;
            close($smak_fh);
        }

        # Prompt for make comparison type
        my $make_type = 'full';  # Default to full build log
        if (!$yes) {
            print "\nSelect make comparison type:\n";
            print "  1) make -n only (fast dry-run)\n";
            print "  2) make clean ; make -n ; make --trace (complete build log)\n";
            print "Choice [2]: ";
            my $choice = <STDIN>;
            chomp $choice if defined $choice;
            $make_type = 'simple' if $choice eq '1';
        }

        # Run make comparison based on user choice
        my $make_dryrun_file = "$report_dir/make-dryrun.txt";
        if ($make_type eq 'full') {
            tee_print("Running full build: make clean ; make -n ; make --trace\n");

            # Run make clean
            tee_print("Running make clean...\n");
            my $clean_result = `make clean -f '$makefile' 2>&1`;
            my $clean_file = "$report_dir/make-clean.txt";
            open(my $clean_fh, '>', $clean_file) or warn "Cannot write to $clean_file: $!\n";
            if ($clean_fh) {
                print $clean_fh $clean_result;
                close($clean_fh);
            }

            # Run make -n
            tee_print("Running make -n...\n");
            my $make_cmd = "make -n -f '$makefile' $target_args 2>&1";
            my $make_result = `$make_cmd`;
            open(my $make_fh, '>', $make_dryrun_file) or warn "Cannot write to $make_dryrun_file: $!\n";
            if ($make_fh) {
                print $make_fh $make_result;
                close($make_fh);
            }

            # Run make --trace
            tee_print("Running make --trace (this will actually build)...\n");
            my $trace_file = "$report_dir/make-trace.txt";
            my $trace_cmd = "make --trace -f '$makefile' $target_args 2>&1";
            my $trace_result = `$trace_cmd`;
            open(my $trace_fh, '>', $trace_file) or warn "Cannot write to $trace_file: $!\n";
            if ($trace_fh) {
                print $trace_fh $trace_result;
                close($trace_fh);
            }

            tee_print("Full build outputs saved:\n");
            tee_print("  make clean: $clean_file\n");
            tee_print("  make -n: $make_dryrun_file\n");
            tee_print("  make --trace: $trace_file\n");
        } else {
            # Simple dry-run only
            my $make_cmd = "make -n -f '$makefile' $target_args 2>&1";
            my $make_result = `$make_cmd`;
            open(my $make_fh, '>', $make_dryrun_file) or warn "Cannot write to $make_dryrun_file: $!\n";
            if ($make_fh) {
                print $make_fh $make_result;
                close($make_fh);
            }
        }

        tee_print("Dry-run outputs saved:\n");
        tee_print("  smak -n: $smak_dryrun_file\n");
        tee_print("  make -n: $make_dryrun_file\n");

        tee_print("\n=== BUILD REPORT COMPLETE ===\n");
        tee_print("Log saved to: $report_dir/build.log\n");
        tee_print("Dry-run comparison: smak-dryrun.txt vs make-dryrun.txt\n");
        close($log_fh) if $log_fh;

        # Ask user if they want to commit the bug report (even if build failed)
        prompt_commit_bug_report($report_dir, $yes);

        # If build failed, exit with error after prompt
        if ($build_failed) {
            exit 1;
        }
    } else {
        # Not in report mode - re-throw the build error if it failed
        if ($build_failed) {
            die $build_error;
        }
    }

    exit 0;
}

sub prompt_commit_bug_report {
    my ($report_dir, $auto_yes) = @_;

    my $should_commit = 0;

    # If -yes flag is set, automatically commit
    if ($auto_yes) {
        print "\nAuto-committing bug report (--yes flag set)...\n";
        $should_commit = 1;
    } else {
        # Check if running interactively (has a terminal)
        if (!-t STDIN) {
            print "\nNote: Not running interactively, skipping commit prompt.\n";
            return;
        }

        print "\n";
        print "=" x 50 . "\n";
        print "Commit bug report to repository?\n";
        print "=" x 50 . "\n";
        print "Report directory: $report_dir\n\n";
        print "Do you want to commit this bug report to the git repository? (y/N): ";

        my $response = <STDIN>;
        chomp($response) if defined $response;

        $should_commit = ($response && $response =~ /^[Yy]/);
    }

    return unless $should_commit;

    # Save current directory
    use Cwd;
    my $original_dir = getcwd();

    # Change to smak directory (where bugs/ is located)
    chdir($RealBin) or do {
        warn "Warning: Cannot change to smak directory $RealBin: $!\n";
        return;
    };

    # Check if we're in a git repository
    my $in_git_repo = system("git rev-parse --git-dir >/dev/null 2>&1") == 0;

    if (!$in_git_repo) {
        print "\nNote: Not in a git repository, skipping commit prompt.\n";
        chdir($original_dir);
        return;
    }

    # Commit the bug report
    print "\nCommitting bug report...\n";

    # Get current branch name
    my $branch = `git branch --show-current`;
    chomp($branch);

    # Extract directory name (project-timestamp) from report directory
    my $dir_name = (split(/\//, $report_dir))[-1];

    # Get relative path for git (bugs/project-timestamp)
    my $git_path = "bugs/$dir_name";

    # Debug: show current directory and path being added
    my $cwd = getcwd();
    print "Current directory: $cwd\n" if $auto_yes;
    print "Adding path: $git_path\n" if $auto_yes;
    print "Path exists: " . (-d $git_path ? "yes" : "no") . "\n" if $auto_yes;

    # Add the bug report directory (force add since bugs/ is in .gitignore)
    my $add_result = system("git add -f $git_path");
    if ($add_result != 0) {
        if ($auto_yes) {
            warn "Warning: Failed to add bug report to git. Continuing anyway (--yes flag set)...\n";
        } else {
            warn "Warning: Failed to add bug report to git. Continue anyway? (y/N): ";
            my $cont = <STDIN>;
            chomp($cont) if defined $cont;
            chdir($original_dir);
            return unless $cont && $cont =~ /^[Yy]/;
        }
    }

    # Create commit message
    my $commit_msg = "Add bug report $dir_name\n\n" .
                    "Generated by smak -Kreport\n" .
                    "Makefile: $makefile\n" .
                    "Report directory: $report_dir\n";

    # Commit
    my $commit_result = system("git", "commit", "-m", $commit_msg);
    if ($commit_result != 0) {
        warn "Warning: Failed to commit bug report.\n";
        chdir($original_dir);
        return;
    }

    print "Bug report committed successfully.\n";

    # Push to remote (auto-push if auto_yes, otherwise prompt)
    if ($auto_yes) {
        print "\nAuto-pushing to remote (--yes flag set)...\n";
        my $push_result = system("git push origin $branch");
        if ($push_result == 0) {
            print "Bug report pushed successfully.\n";
        } else {
            warn "Warning: Failed to push to remote. Continuing anyway (--yes flag set)...\n";
        }
    } else {
        print "\nPush to remote repository? (y/N): ";
        my $push_response = <STDIN>;
        chomp($push_response) if defined $push_response;

        if ($push_response && $push_response =~ /^[Yy]/) {
            print "\nPushing to remote...\n";
            my $push_result = system("git push origin $branch");
            if ($push_result == 0) {
                print "Bug report pushed successfully.\n";
            } else {
                warn "Warning: Failed to push to remote.\n";
            }
        } else {
            print "Skipping push. You can push later with: git push origin $branch\n";
        }
    }

    # Return to original directory
    chdir($original_dir);
}

# Debug mode - enter interactive debugger
interactive_debug();
