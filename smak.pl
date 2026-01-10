#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config);
use FindBin qw($RealBin);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
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
my $jobs = 0;  # Number of parallel jobs (default: 0 => sequential)
my $cli = 0;  # CLI mode (interactive shell)
my $verbose = 0;  # Verbose mode - show smak-specific messages
my $directory = '';  # Directory to change to before running (-C option)
my $ssh_host = '';  # SSH host for remote workers ('fuse' = auto-detect from df)
my $remote_cd = '';  # Remote directory for SSH workers
my $norc = 0;  # Skip reading .smak.rc files
my $retries;  # Max retry count for failed jobs (undef = auto-detect based on -j)

# Check for -norc early (before reading .smak.rc)
for my $arg (@ARGV) {
    if ($arg eq '-norc' || $arg eq '--norc') {
        $norc = 1;
        last;
    }
}

# Read .smak.rc if it exists (before any other configuration)
# Priority: SMAK_RCFILE env var, then search upward for .smak.rc, then ~/.smak.rc
my $smakrc = '';
if (!$norc) {
    # Check for SMAK_RCFILE environment variable first
    if ($ENV{SMAK_RCFILE}) {
        $smakrc = $ENV{SMAK_RCFILE};
    } else {
        # Search upward from current directory for .smak.rc
        my $dir = abs_path('.');
        while (1) {
            my $rc = File::Spec->catfile($dir, '.smak.rc');
            if (-f $rc) {
                $smakrc = $rc;
                last;
            }

            # Move to parent directory
            my $parent = File::Spec->catdir($dir, File::Spec->updir());
            $parent = abs_path($parent);

            # Stop if we've reached the root
            last if $parent eq $dir;
            $dir = $parent;
        }

        # Fall back to ~/.smak.rc if no .smak.rc found in directory tree
        if (!$smakrc && $ENV{HOME} && -f "$ENV{HOME}/.smak.rc") {
            $smakrc = "$ENV{HOME}/.smak.rc";
        }
    }
}

my $reconnect = 0;
my $kill_old_js = 0;

# Whitelist of allowed variable names for 'set' command
my %allowed_vars = (
    jobs => 1,
    verbose => 1,
    silent => 1,
    dry_run => 1,
    makefile => 1,
    directory => 1,
    ssh_host => 1,
    remote_cd => 1,
    cli => 1,
    yes => 1,
    reconnect => 1,      # Special: reconnect to existing job server
    kill_old_js => 1,    # Special: kill old job server before reconnecting
);

if ($smakrc && -f $smakrc) {
    if (open(my $rc_fh, '<', $smakrc)) {
        my $line_num = 0;
        while (my $line = <$rc_fh>) {
            $line_num++;
            chomp $line;
            # Skip comments and empty lines
            next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

            # Handle 'set name = value' command
            if ($line =~ /^\s*set\s+(\w+)\s*=\s*(.+?)\s*$/) {
                my ($name, $value) = ($1, $2);

                # Check if variable is allowed
                unless (exists $allowed_vars{$name}) {
                    warn "$smakrc:$line_num: Unknown variable '$name' (not in whitelist)\n";
                    next;
                }

                # Translate to Perl assignment
                my $perl_code = "\$$name = $value";
                eval $perl_code;
                if ($@) {
                    warn "$smakrc:$line_num: $@";
                }
                next;
            }

            # Otherwise execute as Perl code
            eval $line;
            warn "$smakrc:$line_num: $@" if $@;
        }
        close($rc_fh);
    } else {
        warn "Warning: Cannot read $smakrc: $!\n";
    }
}

# Handle special reconnect and kill_old_js options
if ($reconnect || $kill_old_js) {
    my $connect_file = '.smak.connect';

    if (-l $connect_file || -f $connect_file) {
        # Read port file
        if (open(my $port_fh, '<', $connect_file)) {
            my $observer_port = <$port_fh>;
            my $master_port = <$port_fh>;
            close($port_fh);

            if ($observer_port && $master_port) {
                chomp($observer_port, $master_port);

                # If kill_old_js is set, try to shutdown old server
                if ($kill_old_js) {
                    my $shutdown_socket = IO::Socket::INET->new(
                        PeerHost => '127.0.0.1',
                        PeerPort => $master_port,
                        Proto    => 'tcp',
                        Timeout  => 2,
                    );
                    if ($shutdown_socket) {
                        print $shutdown_socket "SHUTDOWN\n";
                        my $ack = <$shutdown_socket>;
                        close($shutdown_socket);
                        print "Shutdown old job server\n" if $verbose;
                        # Wait a moment for shutdown to complete
                        select(undef, undef, undef, 0.5);
                    }
                }

                # If reconnect is set, try to connect to existing server
                if ($reconnect && !$kill_old_js) {
                    use IO::Socket::INET;
                    my $test_socket = IO::Socket::INET->new(
                        PeerHost => '127.0.0.1',
                        PeerPort => $master_port,
                        Proto    => 'tcp',
                        Timeout  => 2,
                    );
                    if ($test_socket) {
                        close($test_socket);
                        # Set jobs to non-zero to indicate parallel mode
                        # The actual connection will happen later via start_job_server
                        $jobs = 1 unless $jobs;
                        $Smak::job_server_master_port = $master_port;
                        print "Reconnecting to existing job server (port $master_port)\n" if $verbose;
                    } else {
                        warn "Cannot connect to job server at port $master_port (may have already exited)\n";
                    }
                }
            }
        }
    } elsif ($reconnect && $ENV{SMAK_VERBOSE}) {
        warn "Cannot reconnect: .smak.connect not found\n";
    }
}

# Detect recursive invocation early to prevent USR_SMAK_OPT from enabling parallel builds
my $is_recursive = 0;
if (defined $ENV{SMAK_RECURSION_LEVEL}) {
    $is_recursive = 1;
    $ENV{SMAK_RECURSION_LEVEL}++;
} else {
    $ENV{SMAK_RECURSION_LEVEL} = 0;
}

# Parse environment variable options first (skip if recursive to avoid deadlock)
if (defined $ENV{USR_SMAK_OPT} && !$is_recursive) {
    # Split the environment variable into arguments
    my @env_args = split(/\s+/, $ENV{USR_SMAK_OPT});
    # Save original @ARGV
    my @saved_argv = @ARGV;
    # Process environment options
    @ARGV = @env_args;
    GetOptions(
        'f|file|makefile=s' => \$makefile,
        'C|directory=s' => \$directory,
        'Kd|Kdebug' => \$debug,
        'h|help|Kh|Khelp' => \$help,
        'Ks|Kscript=s' => \$script_file,
        'Kreport' => \$report,
        'n|just-print|dry-run|recon' => \$dry_run,
        's|silent|quiet' => \$silent,
        'yes' => \$yes,
        'j|jobs:i' => \$jobs,
        'cli' => \$cli,
        'v|verbose' => \$verbose,
        'ssh=s' => \$ssh_host,
        'cd=s' => \$remote_cd,
        'norc' => \$norc,
        'retries=i' => \$retries,
    );
    # Restore and append remaining command line args
    @ARGV = @saved_argv;
}

# Parse command-line options (override environment)
my $scanner_paths;
GetOptions(
    'f|file|makefile=s' => \$makefile,
    'C|directory=s' => \$directory,
    'Kd|Kdebug' => \$debug,
    'h|help|Kh|Khelp' => \$help,
    'Ks|Kscript=s' => \$script_file,
    'Kreport' => \$report,
    'n|just-print|dry-run|recon' => \$dry_run,
    's|silent|quiet' => \$silent,
    'yes' => \$yes,
    'j|jobs:i' => \$jobs,
    'cli' => \$cli,
    'v|verbose' => \$verbose,
    'ssh=s' => \$ssh_host,
    'cd=s' => \$remote_cd,
    'norc' => \$norc,
    'scanner=s' => \$scanner_paths,
    'retries=i' => \$retries,
) or die "Error in command line arguments\n";

# Handle -j without number (unlimited jobs, use CPU count)
if (defined $jobs && $jobs eq "auto") {
    # Try to detect CPU count
    my $cpu_count = 1;
    if (-f '/proc/cpuinfo') {
        $cpu_count = `grep -c ^processor /proc/cpuinfo 2>/dev/null` || 1;
        chomp $cpu_count;
    }
    $jobs = $cpu_count;
}

# Set default retry count if not specified
# Default: 1 for parallel builds (-j > 0), 0 for sequential
if (!defined $retries) {
    $retries = ($jobs > 0) ? 1 : 0;
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

# Change directory if -C option is specified
if ($directory) {
    chdir($directory) or die "smak: Cannot change to directory '$directory': $!\n";
}

# Handle -ssh=fuse option to auto-detect FUSE remote server
if ($ssh_host eq 'fuse') {
    my ($server, $remote_path) = Smak::get_fuse_remote_info('.');
    if (defined $server) {
        $ssh_host = $server;
        # Use remote path as default if -cd not specified
        $remote_cd = $remote_path unless $remote_cd;
        print "Detected FUSE mount: $server:$remote_path\n" if $verbose;
    } else {
        die "smak: -ssh=fuse specified but current directory is not on a FUSE filesystem\n";
    }
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
  -C, --directory DIR         Change to DIR before doing anything
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
  -scanner PATH[,PATH...]     Run as standalone file watcher (outputs CREATE/MODIFY/DELETE events)

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

sub execute_script_file {
    my ($script_file, $depth) = @_;
    $depth ||= 0;

    # Prevent infinite recursion
    if ($depth >= 10) {
        print "Error: Maximum source nesting depth (10) exceeded\n";
        return;
    }

    unless (-f $script_file) {
        print "Error: File '$script_file' not found\n";
        return;
    }

    my $script_fh;
    unless (open($script_fh, '<', $script_file)) {
        print "Error: Cannot open '$script_file': $!\n";
        return;
    }

    my $line_num = 0;
    while (my $script_line = <$script_fh>) {
        $line_num++;
        chomp $script_line;

        # Skip comments and blank lines
        next if $script_line =~ /^\s*#/;
        next if $script_line =~ /^\s*$/;

        # Strip inline comments (but not in quoted strings)
        $script_line =~ s/(?<!\\)#.*$//;  # Remove # and everything after (unless escaped)
        $script_line =~ s/^\s+|\s+$//g;    # Trim whitespace

        next if $script_line eq '';  # Skip if empty after trimming

        # Display command being executed (if debug mode)
        print "[$script_file:$line_num] $script_line\n" if $ENV{SMAK_DEBUG};

        # Handle nested source commands
        if ($script_line =~ /^source\s+(.+)$/) {
            my $nested_file = $1;
            $nested_file =~ s/^\s+|\s+$//g;
            execute_script_file($nested_file, $depth + 1);
            next;
        }

        # Handle shell command escape (!)
        if ($script_line =~ /^!(.+)$/) {
            my $shell_cmd = $1;
            $shell_cmd =~ s/^\s+//;
            if (my $pid = open(my $cmd_fh, '-|', $shell_cmd . ' 2>&1')) {
                while (my $output = <$cmd_fh>) {
                    print $output;
                }
                close($cmd_fh);
                my $exit_code = $? >> 8;
                if ($exit_code != 0) {
                    print STDERR "[$script_file:$line_num] Command exited with code $exit_code\n";
                }
            } else {
                print STDERR "[$script_file:$line_num] Failed to execute command: $!\n";
            }
            next;
        }

        # Handle Perl eval command
        if ($script_line =~ /^eval\s+(.+)$/) {
            my $expr = $1;
            my $result = eval $expr;
            if ($@) {
                print "[$script_file:$line_num] Error: $@\n";
            } else {
                print "$result\n" if defined $result;
            }
            next;
        }

        # Parse and execute regular commands
        my @words = split(/\s+/, $script_line);
        my $cmd = shift @words;

        # Execute command (this is a simplified version - add more as needed)
        eval {
            if ($cmd eq 'build' || $cmd eq 'b') {
                if (defined $Smak::job_server_socket) {
                    if (@words == 0) {
                        my $default_target = get_default_target();
                        if (defined $default_target) {
                            print "Building default target: $default_target\n";
                            print $Smak::job_server_socket "BUILD:$default_target\n";
                            my $success = 0;
                            while (my $response = <$Smak::job_server_socket>) {
                                chomp $response;
                                last if $response eq 'BUILD_END';
                                if ($response eq 'BUILD_SUCCESS') {
                                    $success = 1;
                                } elsif ($response =~ /^BUILD_ERROR:(.+)$/) {
                                    print "Build failed: $1\n";
                                }
                            }
                            print "Build succeeded.\n" if $success;
                        }
                    } else {
                        foreach my $target (@words) {
                            print "Building target: $target\n";
                            print $Smak::job_server_socket "BUILD:$target\n";
                            my $success = 0;
                            while (my $response = <$Smak::job_server_socket>) {
                                chomp $response;
                                last if $response eq 'BUILD_END';
                                if ($response eq 'BUILD_SUCCESS') {
                                    $success = 1;
                                } elsif ($response =~ /^BUILD_ERROR:(.+)$/) {
                                    print "Build failed: $1\n";
                                }
                            }
                            print "Build succeeded.\n" if $success;
                        }
                    }
                } else {
                    print "Job server not running. Use 'start' to enable.\n";
                }
            } elsif ($cmd eq 'dirty') {
                cmd_dirty(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'touch') {
                cmd_touch(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'rm') {
                cmd_rm(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'needs') {
                cmd_needs(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'stale') {
                if (defined $Smak::job_server_socket) {
                    print $Smak::job_server_socket "LIST_STALE\n";
                    my $count = 0;
                    while (my $response = <$Smak::job_server_socket>) {
                        chomp $response;
                        last if $response eq 'STALE_END';
                        if ($response =~ /^STALE:(.+)$/) {
                            print "  $1\n";
                            $count++;
                        }
                    }
                    if ($count == 0) {
                        print "No stale targets (nothing needs rebuilding)\n";
                    } else {
                        my $target_label = $count == 1 ? "target" : "targets";
                        print "\n$count $target_label need rebuilding\n";
                    }
                } else {
                    print "Job server not running. Use 'start' to enable.\n";
                }
            } elsif ($cmd eq 'auto-retry') {
                # Create minimal state hash for cmd_auto_retry
                my %state = (socket => \$Smak::job_server_socket);
                Smak::cmd_auto_retry(\@words, {}, \%state);
            } elsif ($cmd eq 'ignore') {
                Smak::cmd_ignore(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'assume') {
                Smak::cmd_assume(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'reset') {
                Smak::cmd_reset(\@words, $Smak::job_server_socket);
            } elsif ($cmd eq 'rescan') {
                Smak::cmd_rescan(\@words, $Smak::job_server_socket, undef);
            } elsif ($cmd eq 'start') {
                my %state = (socket => \$Smak::job_server_socket, server_pid => \$Smak::job_server_pid);
                Smak::cmd_start(\@words, {}, \%state);
            } elsif ($cmd eq 'stop') {
                my %state = (socket => \$Smak::job_server_socket, server_pid => \$Smak::job_server_pid);
                Smak::cmd_stop(\@words, {}, \%state);
            } elsif ($cmd eq 'kill') {
                Smak::cmd_kill($Smak::job_server_socket);
            } elsif ($cmd eq 'restart') {
                Smak::cmd_restart(\@words, $Smak::job_server_socket, {});
            } elsif ($cmd eq 'add-rule') {
                # Parse: add-rule <target> : <deps> : <rule>
                if ($script_line =~ /^\s*add-rule\s+(.+?)\s*:\s*(.+?)\s*:\s*(.+)$/i) {
                    my ($target, $deps, $rule_text) = ($1, $2, $3);

                    # Handle escape sequences
                    $rule_text =~ s/\\n/\n/g;
                    $rule_text =~ s/\\t/\t/g;

                    # Ensure each line starts with a tab
                    $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                    Smak::add_rule($target, $deps, $rule_text);
                } else {
                    print "[$script_file:$line_num] Usage: add-rule <target> : <deps> : <rule>\n";
                }
            } elsif ($cmd eq 'mod-rule') {
                # Parse: mod-rule <target> : <rule>
                if ($script_line =~ /^\s*mod-rule\s+(.+?)\s*:\s*(.+)$/i) {
                    my ($target, $rule_text) = ($1, $2);

                    # Handle escape sequences
                    $rule_text =~ s/\\n/\n/g;
                    $rule_text =~ s/\\t/\t/g;

                    # Ensure each line starts with a tab
                    $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                    Smak::modify_rule($target, $rule_text);
                } else {
                    print "[$script_file:$line_num] Usage: mod-rule <target> : <rule>\n";
                }
            } elsif ($cmd eq 'mod-deps') {
                # Parse: mod-deps <target> : <deps>
                if ($script_line =~ /^\s*mod-deps\s+(.+?)\s*:\s*(.+)$/i) {
                    my ($target, $deps) = ($1, $2);
                    Smak::modify_deps($target, $deps);
                } else {
                    print "[$script_file:$line_num] Usage: mod-deps <target> : <deps>\n";
                }
            } elsif ($cmd eq 'del-rule') {
                # Parse: del-rule <target>
                if (@words >= 1) {
                    my $target = $words[0];
                    Smak::delete_rule($target);
                } else {
                    print "[$script_file:$line_num] Usage: del-rule <target>\n";
                }
            } elsif ($cmd eq 'save') {
                # Parse: save <filename>
                if (@words >= 1) {
                    my $filename = $words[0];
                    Smak::save_modifications($filename);
                } else {
                    print "[$script_file:$line_num] Usage: save <filename>\n";
                }
            } else {
                print "[$script_file:$line_num] Unknown command: $cmd\n";
            }
        };
        if ($@) {
            print "[$script_file:$line_num] Error executing command: $@\n";
        }
    }
    close($script_fh);
}


# Set dry-run mode if requested
if ($dry_run) {
    set_dry_run_mode(1);
    # Force -j1 in dry-run mode to ensure job server is available with dry-worker
    # Built-ins (rm, recursive make) execute directly without going to workers
    # This keeps the infrastructure available while avoiding worker overhead for most commands
    $jobs = 1;
}

# Set silent mode if requested
if ($silent) {
    set_silent_mode(1);
}

# Set number of parallel jobs
set_jobs($jobs);

# Set maximum retry count
set_max_retries($retries);

# Set verbose mode via environment variable so Smak.pm can access it
# SMAK_DEBUG implies verbose mode, -cli defaults to wheel mode
if ($verbose || $ENV{SMAK_DEBUG}) {
    $ENV{SMAK_VERBOSE} = '1';
} elsif ($cli) {
    # CLI mode defaults to wheel mode
    $ENV{SMAK_VERBOSE} = '0'; # needs fixed !!!
} else {
    $ENV{SMAK_VERBOSE} = '0';
}

# Set SSH options for remote workers (before forking job-master)
$Smak::ssh_host = $ssh_host if $ssh_host;
$Smak::remote_cd = $remote_cd if $remote_cd;

# Detect FUSE filesystem early (before makefile parsing and Makefile.smak execution)
# This allows Makefile.smak to make decisions based on FUSE status (e.g., auto-rescan)
my $fuse_detected = 0;
my ($fuse_server, $fuse_path) = Smak::get_fuse_remote_info('.');
if (defined $fuse_server) {
    $fuse_detected = 1;
    $ENV{SMAK_FUSE_DETECTED} = 1;
    $ENV{SMAK_FUSE_SERVER} = $fuse_server;
    $ENV{SMAK_FUSE_PATH} = $fuse_path;
    print "Detected FUSE filesystem: $fuse_server at $fuse_path\n" unless $silent;
}

# If scanner mode, run standalone file watcher (no Makefile needed)
if (defined $scanner_paths) {
    my @paths = split(/,/, $scanner_paths);
    Smak::run_standalone_scanner(@paths);
    exit 0;
}

# Parse the makefile FIRST (before forking job-master)
# This ensures %rules is populated when job-master inherits it
parse_makefile($makefile);

# Auto-load <makefile>.smak if it exists
my $auto_script = "$makefile.smak";
if (-f $auto_script) {
    print "Auto-loading script: $auto_script\n" if $ENV{SMAK_DEBUG};
    execute_script_file($auto_script);
}

# Start job server if parallel builds are requested
# Skip in debug or CLI mode (CLI mode starts its own server in run_cli)
# Dry-run mode DOES use the job server (with dummy worker)
unless ($debug || $cli) {
    start_job_server();
}

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
        # Only rebuild if Makefile is out of date (like GNU make)
        if (Smak::needs_rebuild($makefile)) {
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
}

# Execute script file if specified
if ($script_file) {
    execute_script_file($script_file);
}

# If CLI mode, enter interactive loop
if ($cli) {
    # Set SSH options for remote workers
    $Smak::ssh_host = $ssh_host if $ssh_host;
    $Smak::remote_cd = $remote_cd if $remote_cd;

    print "Smak CLI mode - type 'help' for commands\n";
    print "Makefile: $makefile\n";
    print "Parallel jobs: $jobs\n";

    # Start job server if parallel builds are configured
    my $own_server = 0;
    if ($jobs > 1) {
        print "Starting job server...";
        start_job_server();
        print " ($Smak::job_server_pid)\n" if $Smak::job_server_pid;
        $own_server = 1;
    }
    print "\n";

    $SmakCli::cli_owner = $$;
    
    # Enter unified CLI
    my $quiet=0;
    my $result;
    while (1) {
	$result = Smak::unified_cli(
	    socket => $Smak::job_server_socket,
	    server_pid => $Smak::job_server_pid,
	    mode => 'standalone',
	    jobs => $jobs,
	    makefile => $makefile,
	    own_server => $own_server,
	    quiet => $quiet++,
	    );
	
	if (! defined $result) { # hard interrupt, reset IO and server
	    close STDIN;
	    open  STDIN,"</dev/tty";
	    if ($own_server) {
		stop_job_server();
		if ($jobs > 1) {
		    print "\rRestarting job server...";
		    start_job_server();
		    print " ($Smak::job_server_pid)\n" if $Smak::job_server_pid;
		}
	    }
	    next;
	}
	last;
    }

    $SmakCli::cli_owner = -1;
    
    # Stop job server if we own it
    if ($own_server && "stop" eq $result) {
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

    # Wait for all submitted jobs to complete before shutting down
    # Only wait if there are jobs pending - if all commands were handled as built-ins,
    # no jobs were submitted and we can skip straight to shutdown
    if ($Smak::job_server_socket && keys %Smak::in_progress) {
        # Keep reading until we get IDLE (all work complete) or connection closes
        while (1) {
            # Read job completion notifications from job server
            my $response = <$Smak::job_server_socket>;
            last unless defined $response;

            chomp $response;
            if ($response =~ /^JOB_COMPLETE (.+?) (\d+)$/) {
                my ($target, $exit_code) = ($1, $2);
                delete $Smak::in_progress{$target};
                if ($exit_code != 0) {
                    warn "Job failed: $target (exit $exit_code)\n" unless $Smak::silent_mode;
                }
            }
            # IDLE means all work is complete
            elsif ($response eq 'IDLE') {
                last;
            }
            # Also handle other messages to prevent blocking
            elsif ($response =~ /^OUTPUT (.*)$/) {
                print "$1\n" unless $Smak::silent_mode;
            }
            elsif ($response =~ /^ERROR (.*)$/) {
                warn "ERROR: $1\n";
            }
        }
    }

    # Stop job server and clean up workers (must be done before wait_for_jobs)
    stop_job_server();

    my $sts = wait_for_jobs();

    # Check if build failed
    if ($@) {
        $build_failed = 1;
        $build_error = $@;
    }

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

# Check if we're being run as a child of another smak with a job server
# If so, relay our command-line to the parent job server instead of building
if ($ENV{SMAK_JOB_SERVER} && !$ENV{SMAK_JOB_SERVER_RELAY_DONE}) {
    warn "Detected parent job server at $ENV{SMAK_JOB_SERVER}, relaying command\n" if $ENV{SMAK_DEBUG};

    # Reconstruct the command-line
    use Cwd 'getcwd';
    my $cwd = getcwd();
    my @targets_str = @targets ? @targets : ('all');
    my $cmd = "smak";
    $cmd .= " -C $cwd" if $cwd ne $ENV{PWD};
    $cmd .= " @targets_str";

    # Connect to parent job server
    my ($host, $port) = split(/:/, $ENV{SMAK_JOB_SERVER});
    use IO::Socket::INET;
    my $parent_socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );

    if ($parent_socket) {
        $parent_socket->autoflush(1);

        # Send the targets as a build request
        # Format: BUILD target1 target2 target3
        print $parent_socket "BUILD $cwd @targets_str\n";

        # Wait for completion
        my $response = <$parent_socket>;
        chomp $response if defined $response;

        close($parent_socket);

        # Exit with appropriate status
        if ($response && $response =~ /^COMPLETE (\d+)$/) {
            exit $1;
        } else {
            exit 0;  # Success by default
        }
    } else {
        warn "Failed to connect to parent job server, building normally\n";
    }
}

# Debug mode - enter interactive debugger
# Job server is optional - auto-rescan works without it via select() timeout
# If -j flag is specified, start job server for parallel builds
if ($jobs > 0 && !$Smak::job_server_socket) {
    start_job_server();
}

interactive_debug();

# Clean up job server if it was started
if ($Smak::job_server_socket) {
    stop_job_server();
}
