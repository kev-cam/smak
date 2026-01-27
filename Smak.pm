package Smak;

use strict;
use warnings;
use Exporter qw(import);
use POSIX ":sys_wait_h";
use Term::ReadLine;
use SmakCli;
use Time::HiRes qw(time);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy move);

use Carp 'verbose'; # for debug trace
	            # print STDERR Carp::confess( @_ ) if $ENV{SMAK_DEBUG};

our $VERSION = '1.0';

# Set process name visible in ps and /proc/*/comm
# Uses prctl(PR_SET_NAME) on Linux
sub set_process_name {
    my ($name) = @_;
    $0 = $name;  # Set command line (visible in ps aux)

    # PR_SET_NAME = 15, set process name (max 16 chars including null)
    my $PR_SET_NAME = 15;
    $name = substr($name, 0, 15);  # Truncate to 15 chars
    syscall(157, $PR_SET_NAME, $name);  # 157 = SYS_prctl on x86_64
}

# Assertion support - can be disabled for production builds
# To disable assertions, change this constant to 0
use constant ASSERTIONS_ENABLED => 1;

# Assert a condition or die with a message
# These assertions are designed to catch internal logic errors and can be
# stripped out by setting ASSERTIONS_ENABLED to 0 for production builds
sub assert_or_die {
    return unless ASSERTIONS_ENABLED;
    my ($condition, $message) = @_;
    unless ($condition) {
        die "ASSERTION FAILED: $message\n";
    }
}

# Helper function to print verbose messages (smak-specific, not GNU make compatible)
# If SMAK_VERBOSE='w', shows a spinning wheel instead of printing
my @wheel_chars = qw(/ - \\);
my $wheel_pos = 0;

sub vprint {
    my $mode;

    return if (! defined ($mode = $ENV{SMAK_VERBOSE}));

    if ($mode eq 'w') {
        # Spinning wheel mode - update in place
        # Only show wheel if STDERR is a real terminal
        return unless -t STDERR;
        # Clear line, show wheel, flush
        print STDERR "\r" . $wheel_chars[$wheel_pos] . "  \r";
        STDERR->flush();
        $wheel_pos = ($wheel_pos + 1) % scalar(@wheel_chars);
    } elsif (1 == $mode) {
        # Normal verbose mode
        print STDERR @_;
    }
}

sub dprint { # for debugging v->d
    print STDERR @_;
}

our @EXPORT_OK = qw(
    parse_makefile
    build_target
    dry_run_target
    interactive_debug
    execute_script
    get_default_target
    get_rules
    set_report_mode
    set_dry_run_mode
    set_silent_mode
    set_jobs
    set_max_retries
    start_job_server
    stop_job_server
    tee_print
    expand_vars
    add_rule
    cmd_rm
    cmd_touch
    cmd_ignore
    modify_rule
    modify_deps
    delete_rule
    save_modifications
    list_targets
    list_variables
    get_variable
    get_fuse_remote_info
    show_dependencies
    wait_for_jobs
    vprint
    cmd_needs
    cmd_touch
    cmd_rm
    cmd_ignore
    cmd_dirty
    run_check_mode
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

# Separate hashes for different rule types
our %fixed_rule;
our %fixed_deps;
our %fixed_order_only;  # Order-only prerequisites (after |) - don't affect rebuild timestamp checking
our %pattern_rule;
our %pattern_deps;
our %pattern_order_only;  # Order-only prerequisites for pattern rules
our %pseudo_rule;
our %pseudo_deps;
our %pseudo_order_only;  # Order-only prerequisites for pseudo rules

# Suffix rules
our @suffixes;  # List of suffixes from .SUFFIXES directive
our %suffix_rule;  # Suffix rules keyed by "$makefile\t$source_suffix\t$target_suffix"
our %suffix_deps;  # Suffix dependencies (usually empty)

# Track multi-output pattern rules (e.g., parse%cc parse%h: parse%y)
# Maps a canonical rule key to array of all target patterns in the group
# Key format: "makefile\tprereqs\tcommand"
# Value: ["target1", "target2", ...]
our %multi_output_groups;

# Reverse mapping: target pattern -> all patterns in its group
# Key format: "makefile\ttarget_pattern"
# Value: ["target1", "target2", ...] (all targets including this one)
our %multi_output_siblings;

# Runtime mapping: individual target -> compound target that builds it
# Populated when compound targets are queued, consulted when queueing dependencies
# Key: full target path (e.g., "vhdlpp/parse.h")
# Value: compound target name (e.g., "vhdlpp/parse.cc&vhdlpp/parse.h")
our %target_to_compound;

# Post-build hooks: target -> command string to run after successful build
# For compound targets, defaults to "check-siblings <sibling1> <sibling2> ..."
our %post_build;

# VPATH search directories: pattern => [directories]
our %vpath;

# Inactive implicit rule patterns - dynamically detected
# Maps pattern names to boolean (1 = inactive, skip processing)
our %inactive_patterns;

# Source control file extensions/suffixes to always ignore
# These should never be built as targets (prevents infinite recursion)
our %source_control_extensions = (
    ',v' => 1,      # RCS files (foo,v)
);

# Source control directory patterns that indicate recursion
# Check for repeated directories like RCS/RCS/ or SCCS/SCCS/
sub has_source_control_recursion {
    my ($path) = @_;

    # Check for repeated RCS/ directories
    return 1 if $path =~ m{RCS/.*RCS/};

    # Check for repeated SCCS/ directories
    return 1 if $path =~ m{SCCS/.*SCCS/};

    # Check for repeated s. prefix (SCCS recursion: s.s.foo)
    return 1 if $path =~ m{/s\..*[/.]s\.};
    return 1 if $path =~ m{^s\..*[/.]s\.};

    return 0;
}

# Check if a dependency should be filtered out (source control file)
# Returns 1 if dependency should be filtered, 0 otherwise
sub should_filter_dependency {
    my ($dep) = @_;

    # Filter source control pattern dependencies to prevent recursion
    # Only filter source control directories (RCS, SCCS, CVS) - not general build directories
    # The problem: rules like "%: RCS/%,v" create infinite loops
    # Solution: Filter these patterns when the source control directory doesn't exist
    if ($dep =~ /%/ && $dep =~ m{/}) {
        # Extract the directory part before the % wildcard
        if ($dep =~ m{^([^%/]+)/}) {
            my $dir_part = $1;
            # Only filter KNOWN source control directories when they don't exist
            # This prevents recursion (RCS/RCS/, SCCS/SCCS/) when the base dir doesn't exist
            # But allows normal build directories to work even if they don't exist yet
            if ($dir_part =~ /^(RCS|SCCS|CVS)$/ && !-d $dir_part) {
                warn "DEBUG: Filtering source control pattern dependency '$dep' - directory '$dir_part' does not exist\n" if $ENV{SMAK_DEBUG};
                return 1;
            }
        }
    }

    # Filter SCCS-style prefix patterns (s.%) when no matching files exist
    # This prevents infinite recursion from rules like "%: s.%" when no s.* files exist
    if ($dep =~ /^s\.%/) {
        my @matching_files = glob("s.*");
        if (@matching_files == 0) {
            warn "DEBUG: Filtering SCCS pattern dependency '$dep' - no s.* files exist\n" if $ENV{SMAK_DEBUG};
            return 1;
        }
    }

    # Check for source control file extensions (,v) in non-pattern deps
    for my $ext (keys %source_control_extensions) {
        return 1 if $dep =~ /\Q$ext\E/;
    }

    # Check for source control directory recursion (RCS/RCS/, SCCS/SCCS/)
    return 1 if has_source_control_recursion($dep);

    # Check for inactive patterns (legacy fallback for edge cases)
    return 1 if is_inactive_pattern($dep);

    return 0;
}

our @job_queue;

# Layered job scheduling - jobs organized by dependency depth
# Layer 0 = leaves (no buildable deps), higher layers depend on lower layers
# Dispatch from layer 0 upward; when layer N completes, layer N+1 can run
our @job_layers;         # Array of arrays: $job_layers[layer] = [job1, job2, ...]
our %target_layer;       # target => layer number
our $current_dispatch_layer = 0;  # Layer currently being dispatched from
our $max_dispatch_layer = 0;      # Highest layer number

# Hash for Makefile variables
our %MV;

# Command-line variable overrides (VAR=VALUE from command line)
our %cmd_vars;

# Track phony targets (from ninja builds)
our %phony_targets;

# Track modifications for saving
our @modifications;

# Cache of targets that need rebuilding (populated during initial pass/dry-run)
our %stale_targets_cache;

# Files to ignore for dependency checking
our %ignored_files;

# Directories to ignore for dependency checking (from SMAK_IGNORE_DIRS env var)
# These are system directories we know won't change during builds
our @ignore_dirs;
our %ignore_dir_mtimes;  # Cache of directory mtimes for ignored dirs

# State caching variables
our $cache_dir;  # Directory for cached state (from SMAK_CACHE_DIR or default)
our %parsed_file_mtimes;  # Track [mtime, size] of all parsed makefiles for cache validation
our $CACHE_VERSION = 13;  # Increment to invalidate old caches (bumped: always-on caching)

# Control variables
our $timeout = 5;  # Timeout for print command evaluation in seconds
our $prompt = "smak> ";  # Prompt string for interactive mode
our $echo = 0;  # Echo command lines (including prompt)

# Internal state
our $makefile;
our $default_target;
our $report_mode = 0;
our $log_fh;
our $dry_run_mode = 0;
our $silent_mode = 0;

# Rebuild behavior
# When true (default), rebuild missing intermediate files even if final target is up-to-date (matches make)
# When false, skip rebuilding missing intermediates if final target is up-to-date and sources unchanged
# Can be controlled via SMAK_REBUILD_INTERMEDIATES environment variable (0/1)
our $rebuild_missing_intermediates = $ENV{SMAK_REBUILD_INTERMEDIATES} // 1;  # Default: true (match make behavior)

# Job server state
our $jobs = 1;  # Number of parallel jobs
our $max_retries = 1;  # Maximum retry count for failed jobs
our $ssh_host = '';  # SSH host for remote workers
our $remote_cd = '';  # Remote directory for SSH workers
our $job_server_socket;  # Socket to job-master
our $job_server_pid;  # PID of job-master process
our $job_server_master_port;  # Master port for reconnection
our $project_root;  # Root directory of project (set by job-master at startup)

# Output control
our $stomp_prompt = "\r        \r";  # Clear spinner area (8 chars) before printing

sub set_report_mode {
    my ($enabled, $fh) = @_;
    $report_mode = $enabled;
    $log_fh = $fh if $fh;
}

sub set_dry_run_mode {
    my ($enabled) = @_;
    $dry_run_mode = $enabled;
}

sub set_silent_mode {
    my ($enabled) = @_;
    $silent_mode = $enabled;
}

sub set_jobs {
    my ($num_jobs) = @_;
    $jobs = $num_jobs;
}

sub set_max_retries {
    my ($num_retries) = @_;
    $max_retries = $num_retries;
}

sub start_job_server {
    my ($wait) = @_;
    $wait //= 0;  # Default to not waiting for workers

    use IO::Socket::INET;
    use IO::Select;
    use FindBin qw($RealBin);

    return if $jobs < 1;  # Need at least 1 worker for job server

    $SmakCli::cli_owner = $$; # parent not server or workers

    $job_server_pid = fork();
    die "Cannot fork job-master: $!\n" unless defined $job_server_pid;

    if ($job_server_pid == 0) {
        # Child - run job-master with full access to parsed Makefile data
        # This allows job-master to understand dependencies and parallelize intelligently
        set_process_name('smak-server');
        run_job_master($jobs, $RealBin);
        exit 99;  # Should never reach here
    }

    warn "Spawned job-master with PID $job_server_pid\n" if $ENV{SMAK_DEBUG};

    # Wait for job-master to create port file
    my $port_dir = get_port_file_dir();
    my $port_file = "$port_dir/smak-jobserver-$job_server_pid.port";
    my $timeout = 10;
    my $start = time();
    while (! -f $port_file) {
        if (time() - $start > $timeout) {
            die "Job-master failed to start (no port file)\n";
        }
        select(undef, undef, undef, 0.1);
    }

    # Read master port from file
    open(my $fh, '<', $port_file) or die "Cannot read port file: $!\n";
    my $observer_port = <$fh>;
    my $master_port = <$fh>;
    close($fh);
    chomp($observer_port, $master_port);

    $job_server_master_port = $master_port;  # Store for reconnection info
    warn "Job-master master port: $master_port\n" if $ENV{SMAK_DEBUG};

    # Connect to job-master
    $job_server_socket = IO::Socket::INET->new(
        PeerHost => '127.0.0.1',
        PeerPort => $master_port,
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "Cannot connect to job-master: $!\n";

    $job_server_socket->autoflush(1);
    warn "Connected to job-master\n" if $ENV{SMAK_DEBUG};

    # Export job server address for child smak processes
    # Child smak processes will detect this and relay commands instead of spawning new job servers
    $ENV{SMAK_JOB_SERVER} = "127.0.0.1:$master_port";
    warn "Exported SMAK_JOB_SERVER=$ENV{SMAK_JOB_SERVER}\n" if $ENV{SMAK_DEBUG};

    # Send environment to job-master
    for my $key (keys %ENV) {
        next if $key =~ /^(BASH_FUNC_|_)/;
        my $val = $ENV{$key};
        $val =~ s/\n/ /g;
        print $job_server_socket "ENV $key=$val\n";
    }
    print $job_server_socket "ENV_END\n";

    if ($wait) {
        # Wait for workers to be ready
        my $workers_ready = <$job_server_socket>;
        chomp $workers_ready if defined $workers_ready;
        die "Job-master workers not ready\n" unless $workers_ready eq 'JOBSERVER_WORKERS_READY';
        warn "Job-master and all workers ready\n" if $ENV{SMAK_DEBUG};
    } else {
        # Don't wait - workers can connect asynchronously
        # Just wait for acknowledgment that environment was received
        my $ack = <$job_server_socket>;
        chomp $ack if defined $ack;
        if ($ack ne 'JOBSERVER_WORKERS_READY') {
            # Put it back for later processing if it wasn't the ready message
            # This shouldn't happen, but handle gracefully
        }
        warn "Job-master started (workers will connect asynchronously)\n" if $ENV{SMAK_DEBUG};
    }
}

sub stop_job_server {
    return unless $job_server_socket;

    # Send shutdown to job-master
    print $job_server_socket "SHUTDOWN\n";
    $job_server_socket->flush();

    # Wait for acknowledgment
    my $ack = <$job_server_socket>;
    close($job_server_socket);
    $job_server_socket = undef;

    # Wait for job-master to exit
    if ($job_server_pid) {
        waitpid($job_server_pid, 0);
        $job_server_pid = undef;
    }
}

our %in_progress;
our @auto_retry_patterns;  # Patterns for automatic retry (e.g., "*.cc", "*.hh")
our %retry_counts;         # Track retry attempts per target
our %assumed_targets;      # Targets marked as already built (even if they don't exist)

sub submit_job {
    my ($target, $command, $dir) = @_;

    unless ($job_server_socket) {
	warn "ERROR: no job server\n";
	return -1;
    }

    # Use dir-qualified key for in_progress tracking to handle same target name in different directories
    my $progress_key = "$dir\t$target";
    if (my $prog = $in_progress{$progress_key}) {
	if ("queued" eq $prog) {
	    dispatch_jobs(1);
	    $prog = $in_progress{$progress_key};
	    return 1 if ("queued" ne $prog);
	}
	return 2;
    }

    $in_progress{$progress_key} = "queued";

    warn "SUBMIT_JOB: target=$target, dir=$dir, command=$command\n" if $ENV{SMAK_DEBUG};

    # Send job to job-master via socket protocol
    print $job_server_socket "SUBMIT_JOB\n";
    print $job_server_socket "$target\n";
    print $job_server_socket "$dir\n";
    print $job_server_socket "$command\n";

    return 0;
}

# Strip command prefixes (@ for silent, - for ignore errors) and return flags
# Returns: ($cleaned_cmd, $silent, $ignore_errors)
sub strip_command_prefixes {
    my ($cmd) = @_;

    my $ignore_errors = 0;
    my $silent = 0;

    # Strip leading @ (silent) or - (ignore errors) prefixes
    while ($cmd =~ s/^[@-]//) {
        $silent = 1 if $& eq '@';
        $ignore_errors = 1 if $& eq '-';
    }

    return ($cmd, $silent, $ignore_errors);
}

# Compute full target path by combining prefix with target name
# The prefix accumulates as we recurse into subdirectories
# Example: prefix="ivlpp", target="lexor.o" => "ivlpp/lexor.o"
sub target_with_prefix {
    my ($target, $prefix) = @_;

    # If target is already an absolute path, return as-is
    return $target if $target =~ m{^/};

    # If no prefix, return target as-is
    return $target unless defined $prefix && $prefix ne '';

    # Combine prefix with target
    return "$prefix/$target";
}

# Check if a command should be handled as a built-in (fast in-process execution)
# rather than being sent to a worker. This includes:
# - Recursive smak/make -C calls
# - Simple built-in commands (rm, mkdir, echo, true, false, cd)
# - Compound rm commands
# Returns 1 if should be built-in, 0 otherwise
sub is_builtin_command {
    my ($cmd) = @_;
    return 0 unless defined $cmd;

    # Strip command prefixes
    my $clean_cmd = $cmd;
    $clean_cmd =~ s/^[@-]+//;
    $clean_cmd =~ s/^\s+|\s+$//g;

    # Check for recursive smak/make calls
    # Match patterns like: smak -C dir target, smak -f Makefile target, make -C dir target
    # Also handles: ${VAR:-smak} -C dir target, perl /path/smak.pl -f Makefile target
    if ($clean_cmd =~ m{^(?:perl\s+)?(?:(?:\.\.?/|/)?[\w/.-]*(?:smak(?:\.pl)?|make)|\$\{[^\}]*(?:smak|make)[^\}]*\})(?:\s+-\S+)*\s+(?:-C|-f)\s+\S+}) {
        return 1;
    }

    # Check for chained recursive calls: smak -C d1 t1 && smak -C d2 t2 && ...
    my @parts = split(/\s+&&\s+/, $clean_cmd);
    my $all_recursive = 1;
    for my $part (@parts) {
        $part =~ s/^\s+|\s+$//g;
        $part =~ s/^[@-]+//;
        # Skip no-op commands
        next if $part eq 'true' || $part eq ':' || $part eq '';
        unless ($part =~ m{^(?:perl\s+)?(?:(?:\.\.?/|/)?[\w/.-]*(?:smak(?:\.pl)?|make)|\$\{[^\}]*(?:smak|make)[^\}]*\})(?:\s+-\S+)*\s+(?:-C|-f)\s+\S+}) {
            $all_recursive = 0;
            last;
        }
    }
    return 1 if $all_recursive && @parts > 0;

    # Check for simple built-in commands
    # But NOT if the command contains shell redirections (>, >>, <, |, etc.)
    # because our builtin implementations can't handle those
    if ($clean_cmd =~ /[|><]/) {
        return 0;
    }
    my @words = split(/\s+/, $clean_cmd);
    my $first_cmd = $words[0] || '';
    if ($first_cmd =~ /^(rm|mkdir|echo|true|false|cd|:)$/) {
        return 1;
    }

    # Check for compound rm commands like (rm -f x || true) && (rm -f y || true)
    if ($clean_cmd =~ /^\s*\(?\s*rm\s/) {
        return 1;
    }

    return 0;
}

# Execute a command using built-in Perl functions instead of shell
# Returns exit code (0 = success, non-zero = failure, undef = not a built-in)
sub execute_builtin {
    my ($cmd) = @_;

    # Strip leading @ (silent) or - (ignore errors) prefixes
    my $ignore_errors = 0;
    my $silent = 0;
    ($cmd, $silent, $ignore_errors) = strip_command_prefixes($cmd);

    $cmd =~ s/^\s+|\s+$//g;  # Trim whitespace

    # Parse command and arguments
    my @parts = split(/\s+/, $cmd);
    my $command = shift @parts;

    return undef unless defined $command;  # Empty command

    # rm [-f] [-r] [-rf] <files...>
    if ($command eq 'rm') {
        my $force = 0;
        my $recursive = 0;
        my @files;

        for my $arg (@parts) {
            if ($arg eq '-f') {
                $force = 1;
            } elsif ($arg eq '-r' || $arg eq '-R') {
                $recursive = 1;
            } elsif ($arg eq '-rf' || $arg eq '-fr') {
                $force = 1;
                $recursive = 1;
            } else {
                push @files, glob($arg);  # Expand wildcards
            }
        }

        for my $file (@files) {
            if (-d $file) {
                if ($recursive) {
                    remove_tree($file, {error => \my $err});
                    if (@$err && !$force) {
                        print STDERR "rm: cannot remove '$file': $!\n" unless $silent;
                        return 1 unless $ignore_errors;
                    }
                } else {
                    print STDERR "rm: cannot remove '$file': Is a directory\n" unless $silent;
                    return 1 unless $force || $ignore_errors;
                }
            } elsif (-e $file) {
                unless (unlink($file)) {
                    print STDERR "rm: cannot remove '$file': $!\n" unless $silent;
                    return 1 unless $force || $ignore_errors;
                }
            } elsif (!$force) {
                print STDERR "rm: cannot remove '$file': No such file or directory\n" unless $silent;
                return 1 unless $ignore_errors;
            }
        }
        return 0;
    }

    # mkdir [-p] <dirs...>
    elsif ($command eq 'mkdir') {
        my $parents = 0;
        my @dirs;

        for my $arg (@parts) {
            if ($arg eq '-p') {
                $parents = 1;
            } else {
                push @dirs, $arg;
            }
        }

        for my $dir (@dirs) {
            if (-d $dir) {
                # Directory already exists - just warn, don't fail
                warn "mkdir: directory '$dir' already exists (continuing)\n" unless $silent;
                next;  # Continue with next directory
            }
            if ($parents) {
                make_path($dir, {error => \my $err});
                if (@$err) {
                    print STDERR "mkdir: cannot create directory '$dir': $!\n" unless $silent;
                    return 1 unless $ignore_errors;
                }
            } else {
                unless (mkdir($dir)) {
                    print STDERR "mkdir: cannot create directory '$dir': $!\n" unless $silent;
                    return 1 unless $ignore_errors;
                }
            }
        }
        return 0;
    }

    # echo <text...>
    elsif ($command eq 'echo') {
        my $text = join(' ', @parts);
        # Remove surrounding quotes if present
        $text =~ s/^"(.*)"$/$1/;
        $text =~ s/^'(.*)'$/$1/;
        print "$text\n" unless $silent;
        return 0;
    }

    # true / : (no-op)
    elsif ($command eq 'true' || $command eq ':') {
        return 0;
    }

    # false
    elsif ($command eq 'false') {
        return $ignore_errors ? 0 : 1;
    }

    # cd <dir>
    elsif ($command eq 'cd') {
        my $dir = $parts[0] || $ENV{HOME};
        unless (chdir($dir)) {
            print STDERR "cd: $dir: $!\n" unless $silent;
            return 1 unless $ignore_errors;
        }
        return 0;
    }

    # check-siblings <file1> <file2> ... - verify sibling files from compound target exist
    elsif ($command eq 'check-siblings') {
        my @missing;
        for my $file (@parts) {
            unless (-e $file) {
                push @missing, $file;
            }
        }
        if (@missing) {
            print STDERR "check-siblings: missing files: " . join(', ', @missing) . "\n" unless $silent;
            return 1 unless $ignore_errors;
        }
        return 0;
    }

    # Not a recognized built-in
    return undef;
}

# Try to execute a compound command (e.g., "(rm -f *.o || true) && (rm -f src/*.o || true)")
# as built-in operations without spawning a shell.
# Optimizes by combining multiple rm commands into a single operation.
# Returns: 0 on success, non-zero on error, undef if command cannot be handled as built-in
sub try_execute_compound_builtin {
    my ($cmd, $silent_mode_flag) = @_;

    # Quick check: if command contains shell-specific features we can't handle, bail out
    # Commands should already have variables expanded when they reach here
    return undef if $cmd =~ /`/;                   # Backtick command substitution
    return undef if $cmd =~ /\$/;                  # Any variable (should be expanded already)
    return undef if $cmd =~ /(?<!\|)\|(?!\|)/;     # Single | (pipe), but allow || (or)
    return undef if $cmd =~ /[<>]/;                # Redirections
    return undef if $cmd =~ /;/;                   # Semicolon command separator

    # Split by && (respecting parentheses)
    my @parts;
    my $depth = 0;
    my $current = '';

    for my $char (split //, $cmd) {
        if ($char eq '(') {
            $depth++;
            $current .= $char;
        } elsif ($char eq ')') {
            $depth--;
            $current .= $char;
        } elsif ($depth == 0 && $current =~ /\&$/ && $char eq '&') {
            # Found && at depth 0
            $current =~ s/\&$//;  # Remove the first &
            $current =~ s/^\s+|\s+$//g;
            push @parts, $current if $current =~ /\S/;
            $current = '';
        } else {
            $current .= $char;
        }
    }
    $current =~ s/^\s+|\s+$//g;
    push @parts, $current if $current =~ /\S/;

    # Try to combine all parts into a single rm -f operation if possible
    # (rm -f x || true) && (rm -f y || true) => rm -f x y
    my @rm_patterns;
    my $all_rm_f = 1;

    for my $part (@parts) {
        my $inner_cmd = $part;

        # Handle (cmd || true) pattern - for rm -f this is redundant
        if ($part =~ /^\s*\((.+?)\s*\|\|\s*true\s*\)\s*$/) {
            $inner_cmd = $1;
        }
        # Handle (cmd) pattern - just unwrap
        elsif ($part =~ /^\s*\((.+)\)\s*$/) {
            $inner_cmd = $1;
        }

        # Strip @ and - prefixes
        $inner_cmd =~ s/^[@-]+//;
        $inner_cmd =~ s/^\s+|\s+$//g;

        # Check if it's "rm -f <patterns>"
        if ($inner_cmd =~ /^rm\s+(-f|-rf|-fr)\s+(.+)$/) {
            my $flags = $1;
            my $patterns = $2;
            # For now, only optimize plain "rm -f" (not -rf)
            if ($flags eq '-f') {
                push @rm_patterns, split(/\s+/, $patterns);
            } else {
                $all_rm_f = 0;
                last;
            }
        } elsif ($inner_cmd eq 'true' || $inner_cmd eq ':') {
            # No-op, skip
        } else {
            $all_rm_f = 0;
            last;
        }
    }

    # If all parts were "rm -f", execute as single operation
    if ($all_rm_f && @rm_patterns > 0) {
        print STDERR "DEBUG: Optimized compound rm -f: " . scalar(@rm_patterns) . " patterns\n" if $ENV{SMAK_DEBUG};

        # Expand globs and remove files
        for my $pattern (@rm_patterns) {
            my @files = glob($pattern);
            for my $file (@files) {
                if (-e $file && !-d $file) {
                    unlink($file);  # Ignore errors (like rm -f)
                }
            }
        }
        return 0;
    }

    # Fall back to executing parts individually
    for my $part (@parts) {
        my $ignore_errors = 0;
        my $inner_cmd = $part;

        # Handle (cmd || true) pattern - means ignore errors
        if ($part =~ /^\s*\((.+?)\s*\|\|\s*true\s*\)\s*$/) {
            $inner_cmd = $1;
            $ignore_errors = 1;
        }
        # Handle (cmd) pattern - just unwrap
        elsif ($part =~ /^\s*\((.+)\)\s*$/) {
            $inner_cmd = $1;
        }

        # Strip @ and - prefixes
        my $silent = 0;
        while ($inner_cmd =~ s/^[@-]//) {
            $silent = 1 if $& eq '@';
            $ignore_errors = 1 if $& eq '-';
        }
        $inner_cmd =~ s/^\s+|\s+$//g;

        # Try to execute as built-in
        my $exit = execute_builtin($inner_cmd);

        if (!defined $exit) {
            # Not a built-in, can't handle this compound command
            return undef;
        }

        if ($exit != 0 && !$ignore_errors) {
            # Command failed and we're not ignoring errors
            return $exit;
        }
    }

    return 0;  # All parts executed successfully
}

sub execute_command_sequential {
    my ($target, $command, $dir) = @_;

    warn "DEBUG[" . __LINE__ . "]: execute_command_sequential: target='$target' command='$command'\n" if $ENV{SMAK_DEBUG};

    my $old_dir;
    if ($dir && $dir ne '.') {
        use Cwd 'getcwd';
        $old_dir = getcwd();
        warn "DEBUG[" . __LINE__ . "]: Changing to directory: $dir\n" if $ENV{SMAK_DEBUG};
        chdir($dir) or die "Cannot chdir to $dir: $!\n";
    }

    # Check if command has recursive smak/make -C or -f calls
    # Even if mixed with other commands, we can optimize the recursive parts
    my @command_parts = split(/\s+&&\s+/, $command);
    my @recursive_calls;
    my @non_recursive_parts;
    my $found_non_recursive = 0;

    for my $part (@command_parts) {
        $part =~ s/^\s+|\s+$//g;  # Trim whitespace
        $part =~ s/^[@-]+//;      # Strip @ (silent) and - (ignore errors) prefixes
        # Match: smak -C <dir> <target> or make -C <dir> <target>
        # Also match relative paths like ../smak or ./smak
        # Also match shell variable syntax like ${USR_SMAK_SCRIPT:-smak}
        # Allow optional flags (like -j4) between smak and -C
        if ($part =~ m{^(?:perl\s+)?(?:(?:\.\.?/|/)?[\w/.-]*(?:smak(?:\.pl)?|make)|\$\{[^\}]*(?:smak|make)[^\}]*\})(?:\s+-\S+)*\s+-C\s+(\S+)\s+(.+)$}) {
            if (!$found_non_recursive) {
                push @recursive_calls, { dir => $1, target => $2, type => 'C' };
            } else {
                # Recursive call after non-recursive command - can't optimize safely
                @recursive_calls = ();
                last;
            }
        # Match: smak -f <makefile> <target> or perl /path/smak.pl -f <makefile> <target>
        } elsif ($part =~ m{^(?:perl\s+)?(?:(?:\.\.?/|/)?[\w/.-]*(?:smak(?:\.pl)?|make)|\$\{[^\}]*(?:smak|make)[^\}]*\})(?:\s+-\S+)*\s+-f\s+(\S+)\s+(.+)$}) {
            if (!$found_non_recursive) {
                push @recursive_calls, { makefile => $1, target => $2, type => 'f' };
            } else {
                # Recursive call after non-recursive command - can't optimize safely
                @recursive_calls = ();
                last;
            }
        } elsif ($part eq 'true' || $part eq ':' || $part eq '') {
            # Ignore no-op commands - they don't affect optimization
            next;
        } else {
            # Non-recursive command found
            $found_non_recursive = 1;
            push @non_recursive_parts, $part;
        }
    }

    # If we found recursive calls at the start, optimize them
    if (@recursive_calls > 0) {
        warn "DEBUG[" . __LINE__ . "]: Detected " . scalar(@recursive_calls) . " recursive build(s) in chain\n" if $ENV{SMAK_DEBUG};

        # Check if built-in optimizations are disabled (for testing)
        if ($ENV{SMAK_NO_BUILTINS}) {
            warn "DEBUG[" . __LINE__ . "]: SMAK_NO_BUILTINS set - skipping in-process optimization\n" if $ENV{SMAK_DEBUG};
            # Fall through to spawn subprocess
        } else {
            # Handle all recursive calls in-process
            use Cwd 'getcwd';
            my $saved_dir = getcwd();
            my $saved_makefile = $makefile;

            eval {
                for my $call (@recursive_calls) {
                    my $subtarget = $call->{target};

                    if ($call->{type} eq 'C') {
                        # -C dir: change to directory and build
                        my $subdir = $call->{dir};
                        warn "DEBUG[" . __LINE__ . "]: In-process build: -C dir='$subdir' target='$subtarget'\n" if $ENV{SMAK_DEBUG};

                        # Convert subdir to absolute path to avoid issues with relative paths
                        my $abs_subdir = $subdir;
                        unless ($abs_subdir =~ m{^/}) {
                            $abs_subdir = "$saved_dir/$subdir";
                        }

                        chdir($abs_subdir) or die "Cannot chdir to $abs_subdir: $!\n";

                        my $sub_makefile = "Makefile";
                        if (-f $sub_makefile) {
                            $makefile = $sub_makefile;
                            parse_makefile($sub_makefile) unless $parsed_file_mtimes{$sub_makefile};
                        }

                        build_target($subtarget);
                        chdir($saved_dir);
                        $makefile = $saved_makefile;
                    } elsif ($call->{type} eq 'f') {
                        # -f makefile: use different makefile in current directory
                        my $sub_makefile = $call->{makefile};
                        warn "DEBUG[" . __LINE__ . "]: In-process build: -f makefile='$sub_makefile' target='$subtarget'\n" if $ENV{SMAK_DEBUG};

                        if (-f $sub_makefile) {
                            $makefile = $sub_makefile;
                            parse_makefile($sub_makefile) unless $parsed_file_mtimes{$sub_makefile};
                        } else {
                            die "Makefile '$sub_makefile' not found\n";
                        }

                        build_target($subtarget);
                        $makefile = $saved_makefile;
                    }
                }
            };

            my $error = $@;

            # Restore directory and makefile
            chdir($saved_dir);
            $makefile = $saved_makefile;

            # If there are non-recursive commands after recursive ones, execute them
            if (!$error && @non_recursive_parts > 0) {
                warn "DEBUG[" . __LINE__ . "]: Executing " . scalar(@non_recursive_parts) . " remaining command(s)\n" if $ENV{SMAK_DEBUG};

                # Try to execute each command as a built-in first
                for my $cmd_part (@non_recursive_parts) {
                    my $builtin_exit = execute_builtin($cmd_part);

                    if (defined $builtin_exit) {
                        # Command was handled as built-in
                        if ($builtin_exit != 0) {
                            $error = "smak: *** [$target] Error $builtin_exit\n";
                            last;
                        }
                    } else {
                        # Not a built-in, execute via fork/pipe to capture output
                        warn "DEBUG[" . __LINE__ . "]: Executing via shell: $cmd_part\n" if $ENV{SMAK_DEBUG};

                        my $pid = open(my $cmd_fh, '-|', "$cmd_part 2>&1 ; echo EXIT_STATUS=\$?");
                        if (!defined $pid) {
                            $error = "Cannot execute command: $!\n";
                            last;
                        }

                        # Stream output line by line
                        my $shell_exit = 0;
                        while (my $line = <$cmd_fh>) {
                            if ($line =~ /^EXIT_STATUS=(\d+)$/) {
                                $shell_exit = $1;
                                next;
                            }
                            print STDOUT $line;
                            print $log_fh $line if $report_mode && $log_fh;
                        }
                        close($cmd_fh);

                        if ($shell_exit != 0) {
                            $error = "smak: *** [$target] Error $shell_exit\n";
                            last;
                        }
                    }
                }
            }

            chdir($old_dir) if $old_dir;

            if ($error) {
                die $error;
            }

            warn "DEBUG[" . __LINE__ . "]: In-process recursive builds and remaining commands complete\n" if $ENV{SMAK_DEBUG};
            return 0;
        }
    }

    # Assert that we should be using built-in optimizations (for testing)
    if ($ENV{SMAK_ASSERT_NO_SPAWN} && @recursive_calls > 0) {
        die "SMAK_ASSERT_NO_SPAWN: About to spawn subprocess for recursive build, but built-in should be used\n" .
            "Command: $command\n" .
            "Recursive calls detected: " . scalar(@recursive_calls) . "\n" .
            "Targets: " . join(", ", map { "$_->{dir}/$_->{target}" } @recursive_calls) . "\n";
    }

    # Execute command
    warn "DEBUG[" . __LINE__ . "]: About to execute command\n" if $ENV{SMAK_DEBUG};

    # Strip command prefixes (@ for silent, - for ignore errors)
    my ($clean_command, $cmd_silent, $ignore_errors) = strip_command_prefixes($command);

    # In dry-run mode, skip execution - caller (build_target) already printed the command
    if ($dry_run_mode) {
        chdir($old_dir) if $old_dir;
        return 0;
    }

    # Execute command as a pipe to stream output in real-time
    # Redirect stderr to stdout and append exit status marker
    my $pid = open(my $cmd_fh, '-|', "$clean_command 2>&1 ; echo EXIT_STATUS=\$?");
    if (!defined $pid) {
        die "Cannot execute command: $!\n";
    }

    # Stream output line by line as it comes in
    my $exit_code = 0;
    while (my $line = <$cmd_fh>) {
        # Check for exit status marker
        if ($line =~ /^EXIT_STATUS=(\d+)$/) {
            $exit_code = $1;
            next;  # Don't print the marker
        }
        # Always print command output - @ prefix only affects command echo, not output
        print STDOUT $line;
        print $log_fh $line if $report_mode && $log_fh;
    }

    close($cmd_fh);

    warn "DEBUG[" . __LINE__ . "]: Command executed, exit_code=$exit_code\n" if $ENV{SMAK_DEBUG};

    if ($exit_code != 0 && !$ignore_errors) {
        my $err_msg = "smak: *** [$target] Error $exit_code\n";
        tee_print($err_msg);
        chdir($old_dir) if $old_dir;
        die $err_msg;
    }

    # Successfully built - clear from dirty files and stale cache
    if (exists $Smak::dirty_files{$target}) {
        delete $Smak::dirty_files{$target};
        warn "DEBUG[" . __LINE__ . "]: Cleared '$target' from dirty files after successful build\n" if $ENV{SMAK_DEBUG};
    }
    if (exists $Smak::stale_targets_cache{$target}) {
        delete $Smak::stale_targets_cache{$target};
        warn "DEBUG[" . __LINE__ . "]: Cleared '$target' from stale cache after successful build\n" if $ENV{SMAK_DEBUG};
    }

    chdir($old_dir) if $old_dir;
    warn "DEBUG[" . __LINE__ . "]: execute_command_sequential complete\n" if $ENV{SMAK_DEBUG};
}

sub set_cmd_var {
    my ($var, $value) = @_;
    $cmd_vars{$var} = $value;
}

sub get_cmd_vars {
    return \%cmd_vars;
}

sub tee_print {
    my ($msg) = @_;
    print STDOUT $msg;
    print $log_fh $msg if $report_mode && $log_fh;
}

sub classify_target {
    my ($target) = @_;
    if ($target =~ /^\./) {
        return 'pseudo';
    } elsif ($target =~ /%/) {
        return 'pattern';
    } else {
        return 'fixed';
    }
}

sub expand_vars {
    my ($text, $depth) = @_;
    $depth ||= 0;
    return $text if $depth > 10;  # Prevent infinite recursion

    # Convert shell-style ${VAR} to make-style $(VAR) for uniform handling
    # This handles autoconf-generated Makefiles that use ${prefix}, ${exec_prefix}, etc.
    $text =~ s/\$\{(\w+)\}/\$($1)/g;

    # Prevent infinite loops from unsupported functions
    # Note: Large Makefiles (like automake-generated ones) can have hundreds of
    # variable references in a single command line, so we need a high limit
    my $max_iterations = 500;
    my $iterations = 0;

    # Expand $(function args) and $(VAR) references
    while ($text =~ /\$\(/) {
        if (++$iterations > $max_iterations) {
            warn "Warning: expand_vars hit iteration limit ($max_iterations), stopping expansion\n";
            warn "         This may indicate circular variable references or an unsupported make function\n";
            warn "         Remaining unexpanded: " . substr($text, 0, 200) . "...\n" if length($text) > 200;
            warn "         Iteration count: $iterations\n";
            last;
        }

        # Find the matching closing paren for balanced extraction
        my $start = index($text, '$(');
        last if $start < 0;

        my $pos = $start + 2;  # Start after '$('
        my $depth = 1;
        my $len = length($text);

        while ($pos < $len && $depth > 0) {
            my $char = substr($text, $pos, 1);
            # Count ALL parentheses, not just $() - shell commands can have
            # bare parens like ( md5sum ... ) which must be balanced
            if ($char eq '(') {
                $depth++;
            } elsif ($char eq ')') {
                $depth--;
            }
            $pos++;
        }

        if ($depth != 0) {
            # Unbalanced parentheses, skip this one
            warn "Warning: Unbalanced parentheses in: " . substr($text, $start, 50) . "...\n";
            last;
        }

        my $content = substr($text, $start + 2, $pos - $start - 3);
        my $replacement;

        # Check if it's a function call (contains space or comma)
        if ($content =~ /^(\w+)\s+(.+)$/ || $content =~ /^(\w+),(.+)$/) {
            my $func = $1;
            my $args_str = $2;

            # Split arguments by comma, but not within nested parentheses
            # Count ALL parens, not just $() - shell commands can have bare parens
            my @args;
            my $depth = 0;
            my $current = '';
            for my $char (split //, $args_str) {
                if ($char eq '(') {
                    $depth++;
                    $current .= $char;
                } elsif ($char eq ')') {
                    $depth--;
                    $current .= $char;
                } elsif ($char eq ',' && $depth == 0) {
                    push @args, $current;
                    $current = '';
                } else {
                    $current .= $char;
                }
            }
            push @args, $current if $current ne '';

            # Trim whitespace from arguments
            # NOTE: For foreach, preserve whitespace in the third argument (text template)
            if ($func eq 'foreach' && @args >= 3) {
                # Trim first two args, preserve exact whitespace in third arg (text)
                $args[0] =~ s/^\s+|\s+$//g;
                $args[1] =~ s/^\s+|\s+$//g;
                # $args[2] is NOT trimmed - whitespace is significant
            } else {
                @args = map { s/^\s+|\s+$//gr } @args;
            }

            # Recursively expand variables in arguments
            # NOTE: foreach is handled specially - don't pre-expand its arguments
            unless ($func eq 'foreach') {
                @args = map { expand_vars($_, $depth + 1) } @args;
            }

            # Process gmake functions
            if ($func eq 'patsubst') {
                # $(patsubst pattern,replacement,text)
                if (@args >= 3) {
                    my ($pattern, $repl, $text) = @args;
                    # Convert gmake pattern to regex
                    my $regex = $pattern;
                    $regex =~ s/%/(.+)/g;
                    $regex = "^$regex\$";
                    # Convert replacement pattern
                    $repl =~ s/%/\$1/g;
                    my @words = split /\s+/, $text;
                    @words = map { s/$regex/$repl/r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'subst') {
                # $(subst from,to,text)
                if (@args >= 3) {
                    my ($from, $to, $text) = @args;
                    $replacement = $text;
                    $replacement =~ s/\Q$from\E/$to/g;
                }
            } elsif ($func eq 'strip') {
                # $(strip string)
                if (@args >= 1) {
                    $replacement = $args[0];
                    $replacement =~ s/^\s+|\s+$//g;
                    $replacement =~ s/\s+/ /g;
                }
            } elsif ($func eq 'findstring') {
                # $(findstring find,in)
                if (@args >= 2) {
                    my ($find, $in) = @args;
                    $replacement = index($in, $find) >= 0 ? $find : '';
                }
            } elsif ($func eq 'filter') {
                # $(filter pattern...,text)
                if (@args >= 2) {
                    my $patterns = $args[0];
                    my $text = $args[1];
                    my @patterns = split /\s+/, $patterns;
                    my @words = split /\s+/, $text;
                    my @result;
                    for my $word (@words) {
                        for my $pat (@patterns) {
                            my $regex = $pat;
                            $regex =~ s/%/.*?/g;
                            if ($word =~ /^$regex$/) {
                                push @result, $word;
                                last;
                            }
                        }
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'filter-out') {
                # $(filter-out pattern...,text)
                if (@args >= 2) {
                    my $patterns = $args[0];
                    my $text = $args[1];
                    my @patterns = split /\s+/, $patterns;
                    my @words = split /\s+/, $text;
                    my @result;
                    for my $word (@words) {
                        my $matched = 0;
                        for my $pat (@patterns) {
                            my $regex = $pat;
                            $regex =~ s/%/.*?/g;
                            if ($word =~ /^$regex$/) {
                                $matched = 1;
                                last;
                            }
                        }
                        push @result, $word unless $matched;
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'sort') {
                # $(sort list)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    my %seen;
                    @words = grep { !$seen{$_}++ } sort @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'word') {
                # $(word n,text)
                if (@args >= 2) {
                    my ($n, $text) = @args;
                    my @words = split /\s+/, $text;
                    $replacement = $words[$n - 1] || '';
                }
            } elsif ($func eq 'wordlist') {
                # $(wordlist s,e,text)
                if (@args >= 3) {
                    my ($s, $e, $text) = @args;
                    my @words = split /\s+/, $text;
                    my @result = @words[($s-1)..($e-1)];
                    $replacement = join(' ', grep defined, @result);
                }
            } elsif ($func eq 'words') {
                # $(words text)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = scalar(@words);
                }
            } elsif ($func eq 'firstword') {
                # $(firstword names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = $words[0] || '';
                }
            } elsif ($func eq 'lastword') {
                # $(lastword names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = $words[-1] || '';
                }
            } elsif ($func eq 'dir') {
                # $(dir names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { m{(.*/)} ? $1 : './' } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'notdir') {
                # $(notdir names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { s{.*/}{}r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'suffix') {
                # $(suffix names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { /(\.[^.\/]*)$/ ? $1 : '' } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'basename') {
                # $(basename names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { s/\.[^.\/]*$//r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'addsuffix') {
                # $(addsuffix suffix,names...)
                if (@args >= 2) {
                    my ($suffix, $names) = @args;
                    my @words = split /\s+/, $names;
                    @words = map { $_ . $suffix } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'addprefix') {
                # $(addprefix prefix,names...)
                if (@args >= 2) {
                    my ($prefix, $names) = @args;
                    my @words = split /\s+/, $names;
                    @words = map { $prefix . $_ } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'join') {
                # $(join list1,list2)
                if (@args >= 2) {
                    my @list1 = split /\s+/, $args[0];
                    my @list2 = split /\s+/, $args[1];
                    my @result;
                    for (my $i = 0; $i < @list1 || $i < @list2; $i++) {
                        push @result, ($list1[$i] // '') . ($list2[$i] // '');
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'wildcard') {
                # $(wildcard pattern...)
                if (@args >= 1) {
                    my @patterns = split /\s+/, $args[0];
                    my @files;
                    for my $pattern (@patterns) {
                        push @files, glob($pattern);
                    }
                    $replacement = join(' ', @files);
                }
            } elsif ($func eq 'shell') {
                # $(shell command)
                if (@args >= 1) {
                    my $cmd = $args[0];
                    $replacement = `$cmd`;
                    chomp $replacement;
                }
            } elsif ($func eq 'foreach') {
                # $(foreach var,list,text)
                # NOTE: Arguments are NOT pre-expanded for foreach
                if (@args >= 3) {
                    my ($var, $list, $text) = @args;
                    # Expand the list to get the words to iterate over
                    $list = expand_vars($list, $depth + 1);
                    my @words = split /\s+/, $list;
                    my @results;
                    for my $word (@words) {
                        # Skip empty words
                        next if $word eq '';
                        # Temporarily set the loop variable
                        my $saved_val = $MV{$var};
                        $MV{$var} = $word;
                        # Expand the text with the loop variable set
                        # Note: text was NOT pre-expanded, so $(var) will be found
                        my $expanded = expand_vars($text, $depth + 1);
                        push @results, $expanded;
                        # Restore previous value
                        if (defined $saved_val) {
                            $MV{$var} = $saved_val;
                        } else {
                            delete $MV{$var};
                        }
                    }

                    # Concatenate all results (standard foreach behavior)
                    $replacement = join('', @results);
                }
            } elsif ($func eq 'realpath') {
                # $(realpath names...)
                if (@args >= 1) {
                    use Cwd 'abs_path';
                    my @paths = split /\s+/, $args[0];
                    my @resolved;
                    for my $path (@paths) {
                        next if $path eq '';
                        # abs_path returns undef if path doesn't exist
                        my $resolved = abs_path($path);
                        push @resolved, $resolved if defined $resolved;
                    }
                    $replacement = join(' ', @resolved);
                }
            } elsif ($func eq 'abspath') {
                # $(abspath names...)
                if (@args >= 1) {
                    use Cwd 'abs_path';
                    my @paths = split /\s+/, $args[0];
                    my @resolved;
                    for my $path (@paths) {
                        next if $path eq '';
                        my $resolved = abs_path($path) // $path;  # Fall back to original if doesn't exist
                        push @resolved, $resolved;
                    }
                    $replacement = join(' ', @resolved);
                }
            } else {
                # Unknown function, leave as-is
                $replacement = "\$($content)";
            }
        } else {
            # Simple variable reference
            # Check command-line variables first, then Makefile variables
            $replacement = $cmd_vars{$content} // $MV{$content} // '';
            # Convert any $MV{...} in the value to $(...) so they can be expanded
            $replacement = format_output($replacement);
        }

        # Replace in text using substring positions
        $replacement //= '';
        my $match_len = $pos - $start;
        $text = substr($text, 0, $start) . $replacement . substr($text, $pos);
    }

    return $text;
}

sub format_output {
    my ($text) = @_;
    # Convert $MV{VAR} back to $(VAR) for display/expansion
    $text =~ s/\$MV\{([^}]+)\}/\$($1)/g;
    # Also convert shell-style ${VAR} to $(VAR) for uniform handling
    # This handles autoconf-generated Makefiles that use ${prefix}, ${exec_prefix}, etc.
    $text =~ s/\$\{(\w+)\}/\$($1)/g;
    return $text;
}

sub transform_make_vars {
    my ($text) = @_;
    # Transform $$ to a placeholder to protect it from further expansion
    # In Makefiles, $$ means a literal $ that should be passed to the shell
    $text =~ s/\$\$/\x00DOLLAR\x00/g;

    # Transform $(VAR) to $MV{VAR} with proper nested parenthesis handling
    my $result = '';
    my $pos = 0;
    my $len = length($text);

    while ($pos < $len) {
        # Look for $(
        my $start = index($text, '$(', $pos);
        if ($start < 0) {
            # No more $(...) patterns, append rest of text
            $result .= substr($text, $pos);
            last;
        }

        # Append text before $(
        $result .= substr($text, $pos, $start - $pos);

        # Find matching closing paren
        my $scan_pos = $start + 2;
        my $depth = 1;

        while ($scan_pos < $len && $depth > 0) {
            my $char = substr($text, $scan_pos, 1);
            # Count ALL parentheses, not just $() - shell commands can contain
            # bare parens like ( md5sum ... ) which must be balanced
            if ($char eq '(') {
                $depth++;
            } elsif ($char eq ')') {
                $depth--;
            }
            $scan_pos++;
        }

        if ($depth == 0) {
            # Found balanced parentheses, extract content
            my $content = substr($text, $start + 2, $scan_pos - $start - 3);

            # Check if this is a function call - don't transform those
            # Function calls have format: $(func arg...) or $(func,arg,...)
            my @known_funcs = qw(patsubst subst strip findstring filter filter-out
                sort word wordlist words firstword lastword dir notdir suffix
                basename addsuffix addprefix join wildcard shell foreach
                realpath abspath if or and call value eval origin flavor info warning error);
            my $is_func = 0;
            for my $func (@known_funcs) {
                if ($content =~ /^\Q$func\E[\s,]/) {
                    $is_func = 1;
                    last;
                }
            }

            if ($is_func) {
                # Leave function calls as-is for expand_vars to handle
                $result .= '$(' . $content . ')';
            } else {
                # Convert variable references to $MV{...}
                $result .= '$MV{' . $content . '}';
            }
            $pos = $scan_pos;
        } else {
            # Unbalanced, just copy the $( and continue
            $result .= '$(';
            $pos = $start + 2;
        }
    }

    $text = $result;

    # Transform $X (single-letter variables) to $MV{X}, but not automatic vars like $@, $<, $^, $*, $?
    # Automatic variables are handled separately in expand_vars
    $text =~ s/\$([A-Za-z0-9_])(?![A-Za-z0-9_{])/\$MV{$1}/g;

    # Restore $$ as single $ (for shell execution)
    $text =~ s/\x00DOLLAR\x00/\$/g;

    return $text;
}

our %missing_inc; # bug workaround

sub parse_makefile {
    my ($makefile_path) = @_;

    $makefile = $makefile_path;
    undef $default_target;

    # Always initialize ignore_dirs from environment (not saved in cache)
    # This ensures SMAK_IGNORE_DIRS is respected even when using cached state
    init_ignore_dirs();

    # Try to load from cache if available and valid
    if (load_state_cache($makefile_path)) {
        warn "DEBUG: Using cached state, skipping parse\n" if $ENV{SMAK_DEBUG};

        # Ensure inactive patterns are detected even if cache didn't have them
        # (handles old caches created before this feature)
        if (!%inactive_patterns) {
            warn "DEBUG: Cache missing inactive patterns, detecting now\n" if $ENV{SMAK_DEBUG};
            detect_inactive_patterns();
        }

        return;  # Cache loaded successfully, skip parsing
    }

    # Reset state
    %fixed_rule = ();
    %fixed_deps = ();
    %pattern_rule = ();
    %pattern_deps = ();
    %pseudo_rule = ();
    %pseudo_deps = ();
    %MV = ();
    @modifications = ();
    %parsed_file_mtimes = ();

    # Reset suffix rules - initialize with GNU make default suffixes
    # These are the common suffixes used in C/C++ development
    @suffixes = qw(.out .a .ln .o .c .cc .C .cpp .cxx .h .s .S);
    %suffix_rule = ();
    %suffix_deps = ();

    # Set default built-in make variables
    # Use the actual invocation command for recursive makes
    # Check environment variable set by wrapper script, otherwise use $0
    $MV{MAKE} = $ENV{SMAK_INVOKED_AS} || $0;
    $MV{SHELL} = '/bin/sh';
    $MV{RM} = 'rm -f';
    $MV{AR} = 'ar';
    $MV{CC} = 'cc';
    $MV{CXX} = 'c++';
    $MV{CPP} = '\$(CC) -E';
    $MV{AS} = 'as';
    $MV{FC} = 'f77';
    $MV{LEX} = 'lex';
    $MV{YACC} = 'yacc';
    $MV{CFLAGS} = '';
    $MV{CXXFLAGS} = '';
    $MV{CPPFLAGS} = '';
    $MV{LDFLAGS} = '';
    $MV{LDLIBS} = '';
    $MV{'COMPILE.c'} = '$(CC) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c';
    $MV{'COMPILE.cc'} = '$(CXX) $(CXXFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c';
    $MV{'LINK.o'} = '$(CC) $(LDFLAGS) $(TARGET_ARCH)';
    $MV{'OUTPUT_OPTION'} = '-o $@';

    # Set directory variables (PWD and CURDIR should be the same)
    use Cwd 'getcwd';
    $MV{PWD} = getcwd();
    $MV{CURDIR} = getcwd();

    open(my $fh, '<', $makefile) or die "Cannot open $makefile: $!";

    # Track file mtime and size for cache validation
    use Cwd 'abs_path';
    my $abs_makefile = abs_path($makefile) || $makefile;
    my @st = stat($makefile);
    $parsed_file_mtimes{$abs_makefile} = [$st[9], $st[7]];  # [mtime, size]

    my @current_targets;  # Array to handle multiple targets (e.g., "target1 target2:")
    my $current_rule = '';
    my $current_type;  # 'fixed', 'pattern', or 'pseudo'
    my @current_deps;  # Track current dependencies for multi-output detection
    my @current_suffix_targets;  # Track suffix rule targets separately

    my $save_current_rule = sub {
        # Save suffix rules first
        for my $suffix_target (@current_suffix_targets) {
            if ($suffix_target =~ /^(\.[^.]+)(\.[^.]+)$/) {
                my ($source_suffix, $target_suffix) = ($1, $2);
                my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                $suffix_rule{$suffix_key} = $current_rule;
                if ($ENV{SMAK_DEBUG}) {
                    my $preview = $current_rule;
                    $preview =~ s/\n/\\n/g;  # Show newlines
                    $preview = substr($preview, 0, 100);
                    warn "DEBUG: Saved suffix rule $suffix_target: '$preview' (length=" . length($current_rule) . ")\n";
                }
            }
        }

        return unless @current_targets;

        # Detect multi-output pattern rules
        # If we have multiple pattern targets with the same prerequisites and command,
        # they form a multi-output group (e.g., parse%cc parse%h: parse%y)
        my @pattern_targets = grep { classify_target($_) eq 'pattern' } @current_targets;
        if (@pattern_targets > 1) {
            # Get current prerequisites
            # We'll create a group key based on the makefile and prerequisites
            my $prereqs_key = join(',', @current_deps);
            my $group_key = "$makefile\t$prereqs_key\t$current_rule";

            # Store all targets in this group
            $multi_output_groups{$group_key} = [@pattern_targets];

            # Create reverse mapping: each target -> all siblings
            for my $target (@pattern_targets) {
                my $target_key = "$makefile\t$target";
                $multi_output_siblings{$target_key} = [@pattern_targets];
            }

            warn "DEBUG: Multi-output pattern rule: @pattern_targets\n" if $ENV{SMAK_DEBUG};
        }

        # Save rule for all targets in the current rule
        for my $target (@current_targets) {
            my $key = "$makefile\t$target";
            my $type = classify_target($target);

            # Skip source control pattern rules if those systems are inactive
            if ($type eq 'pattern') {
                # Check if this is a source control rule that should be discarded
                if (is_inactive_pattern($target)) {
                    warn "DEBUG: Discarding inactive pattern rule: $target\n" if $ENV{SMAK_DEBUG};
                    next;  # Skip this rule entirely
                }
                if (has_source_control_recursion($target)) {
                    warn "DEBUG: Discarding recursive pattern rule: $target\n" if $ENV{SMAK_DEBUG};
                    next;  # Skip this rule entirely
                }
            }

            if ($type eq 'fixed') {
                # Only overwrite if no rule exists or existing rule is empty (GNU make: first rule with commands wins)
                if (!exists $fixed_rule{$key} || !defined $fixed_rule{$key} || $fixed_rule{$key} !~ /\S/) {
                    $fixed_rule{$key} = $current_rule;
                }
            } elsif ($type eq 'pattern') {
                # Pattern rules can have multiple variants (e.g., %.o from %.c, %.cc, %.cpp)
                # Store each variant as a separate entry in the arrays
                # Only add if the rule has commands
                if ($current_rule && $current_rule =~ /\S/) {
                    # Initialize arrays if this is the first pattern rule for this target
                    $pattern_rule{$key} = [] unless exists $pattern_rule{$key};
                    # Append this rule variant
                    push @{$pattern_rule{$key}}, $current_rule;
                    warn "DEBUG: Added pattern rule variant for $key (now have " . scalar(@{$pattern_rule{$key}}) . " variants)\n" if $ENV{SMAK_DEBUG};
                }
            } elsif ($type eq 'pseudo') {
                if (!exists $pseudo_rule{$key} || !defined $pseudo_rule{$key} || $pseudo_rule{$key} !~ /\S/) {
                    $pseudo_rule{$key} = $current_rule;
                }
            }
        }

        @current_targets = ();
        @current_deps = ();
        $current_rule = '';
        $current_type = undef;
    };

    # Conditional stack: each entry is {active => 0/1, seen_else => 0/1}
    # active=1 means we're processing lines in this branch
    # seen_else=1 means we've seen the else for this if
    my @cond_stack = ({active => 1, seen_else => 0});  # Start with active top level

    while (my $line = <$fh>) {
        chomp $line;

        # Handle line continuations
        while ($line =~ /\\$/) {
            $line =~ s/\\$//;
            my $next = <$fh>;
            last unless defined $next;
            chomp $next;
            $line .= $next;
        }

        # Handle conditional directives (ifeq, ifdef, ifndef, ifneq, else, endif)
        # These must be processed even when skipping lines
        if ($line =~ /^\s*ifeq\s+(.+)$/) {
            my $args = $1;
            my $result = 0;

            # Parse ifeq: ifeq (arg1,arg2) or ifeq "arg1" "arg2"
            if ($args =~ /^\s*\(([^,]*),([^)]*)\)\s*$/ || $args =~ /^\s*"([^"]*)"\s+"([^"]*)"$/ || $args =~ /^\s*'([^']*)'\s+'([^']*)'$/) {
                my ($arg1, $arg2) = ($1, $2);
                # Expand variables in arguments
                $arg1 = transform_make_vars($arg1);
                $arg2 = transform_make_vars($arg2);
                while ($arg1 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg1 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                while ($arg2 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg2 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                # Trim whitespace
                $arg1 =~ s/^\s+|\s+$//g;
                $arg2 =~ s/^\s+|\s+$//g;
                $result = ($arg1 eq $arg2);
                warn "DEBUG: ifeq('$arg1', '$arg2') = $result\n" if $ENV{SMAK_DEBUG};
            }

            # Push new conditional state
            # Active if parent is active AND condition is true
            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*ifneq\s+(.+)$/) {
            my $args = $1;
            my $result = 0;

            # Parse ifneq: ifneq (arg1,arg2) or ifneq "arg1" "arg2"
            if ($args =~ /^\s*\(([^,]*),([^)]*)\)\s*$/ || $args =~ /^\s*"([^"]*)"\s+"([^"]*)"$/ || $args =~ /^\s*'([^']*)'\s+'([^']*)'$/) {
                my ($arg1, $arg2) = ($1, $2);
                # Expand variables in arguments
                $arg1 = transform_make_vars($arg1);
                $arg2 = transform_make_vars($arg2);
                while ($arg1 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg1 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                while ($arg2 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg2 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                # Trim whitespace
                $arg1 =~ s/^\s+|\s+$//g;
                $arg2 =~ s/^\s+|\s+$//g;
                $result = ($arg1 ne $arg2);  # ifneq is true when NOT equal
                warn "DEBUG: ifneq('$arg1', '$arg2') = $result\n" if $ENV{SMAK_DEBUG};
            }

            # Push new conditional state
            # Active if parent is active AND condition is true
            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*ifdef\s+(\S+)$/) {
            my $var = $1;
            my $result = exists $MV{$var} && defined $MV{$var} && $MV{$var} ne '';
            warn "DEBUG: ifdef $var => defined=" . (exists $MV{$var} ? "yes" : "no") . ", result=$result\n" if $ENV{SMAK_DEBUG};

            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*ifndef\s+(\S+)$/) {
            my $var = $1;
            my $result = exists $MV{$var} && defined $MV{$var} && $MV{$var} ne '';
            $result = !$result;  # invert for ifndef
            warn "DEBUG: ifndef $var => defined=" . (exists $MV{$var} ? "yes" : "no") . ", result=$result\n" if $ENV{SMAK_DEBUG};

            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*else\s*$/) {
            if (@cond_stack <= 1) {
                warn "Warning: else without matching if in $makefile\n";
                next;
            }
            my $cond = $cond_stack[-1];
            if ($cond->{seen_else}) {
                warn "Warning: duplicate else in $makefile\n";
                next;
            }
            $cond->{seen_else} = 1;
            # Toggle active state if parent is active
            my $parent_active = $cond_stack[-2]{active};
            $cond->{active} = $parent_active && !$cond->{active};
            warn "DEBUG: else => active now " . $cond->{active} . "\n" if $ENV{SMAK_DEBUG};
            next;
        }
        elsif ($line =~ /^\s*endif\s*$/) {
            if (@cond_stack <= 1) {
                warn "Warning: endif without matching if in $makefile\n";
                next;
            }
            pop @cond_stack;
            warn "DEBUG: endif => stack depth now " . scalar(@cond_stack) . "\n" if $ENV{SMAK_DEBUG};
            next;
        }

        # Skip lines if we're in an inactive conditional branch
        unless ($cond_stack[-1]{active}) {
            # Still need to track current targets to properly handle rule continuations
            if ($line =~ /^\t/ && !@current_targets) {
                # Recipe line but no target - skip
            } elsif ($line =~ /^(\S[^:]*?):\s*(.*)$/) {
                # New target definition while skipping - SAVE current rule first, then clear
                # This prevents losing rules defined before the inactive conditional
                $save_current_rule->() if @current_targets;
                @current_targets = ();
                @current_suffix_targets = ();
                $current_rule = '';
            }
            next;
        }

        # Skip comments and empty lines
        # Comments can appear between target line and commands, so skip them always
        if ($line =~ /^\s*#/ || $line =~ /^\s*$/) {
            next;
        }

        # Handle vpath directives
        if ($line =~ /^vpath\s+(\S+)\s+(.+)$/) {
            my ($pattern, $directories) = ($1, $2);
            # Expand variables in directories
            $directories = transform_make_vars($directories);
            while ($directories =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $directories =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            # Split directories by whitespace or colon
            my @dirs = split /[\s:]+/, $directories;
            # Append to existing directories for this pattern (make accumulates vpath entries)
            if (exists $vpath{$pattern}) {
                push @{$vpath{$pattern}}, @dirs;
            } else {
                $vpath{$pattern} = \@dirs;
            }
            print STDERR "DEBUG: vpath $pattern += " . join(", ", @dirs) . " (total: " . join(", ", @{$vpath{$pattern}}) . ")\n" if $ENV{SMAK_DEBUG};
            next;
        }

        # Handle include directives
        if ($line =~ /^-?include\s+(.+?)(?:\s*#.*)?$/) {
            $save_current_rule->();
            my $include_files = $1;
            # Expand variables and functions in the include filename
            $include_files = expand_vars($include_files);

            # Handle multiple includes on one line
            for my $include_file (split /\s+/, $include_files) {
                # Skip empty entries
                next if $include_file eq '';
		
		if (defined $missing_inc{$include_file}) {
		    die "Already missing: $include_file !!!\n";
		}
			
                # Determine include path
                my $include_path = $include_file;

                # If not absolute path, try to find the file
                unless ($include_path =~ m{^/}) {
                    use File::Basename;
                    use File::Spec;

                    # First try relative to current working directory
                    if (-f $include_file) {
                        $include_path = $include_file;
                    } else {
                        # Try relative to current Makefile's directory
                        my $makefile_dir = dirname($makefile);
                        my $relative_path = File::Spec->catfile($makefile_dir, $include_file);
                        if (-f $relative_path) {
                            $include_path = $relative_path;
                        } else {
                            # Use the relative path for error reporting even if not found
                            $include_path = $relative_path;
                        }
                    }
                }

                # Parse the included file (ignore if it doesn't exist and line starts with -)
                if (-f $include_path) {
                    print STDERR "DEBUG: including '$include_path'\n" if $ENV{SMAK_DEBUG};
                    # Save current makefile name
                    my $saved_makefile = $makefile;

                    # Parse included file in-place (variables go into same %MV)
                    parse_included_makefile($include_path);

                    # Restore current makefile name
                    $makefile = $saved_makefile;
                } elsif ($line !~ /^-include/) {
                    warn "Warning: included file not found: $include_path [$include_file]\n";
		    $missing_inc{$include_file} = 1;
                } elsif ($ENV{SMAK_DEBUG}) {
                    print STDERR "DEBUG: optional include not found (ignored): $include_path\n";
                }
            }
            next;
        }

        # Variable assignment
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*([:?+]?=)\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $op, $value) = ($1, $2, $3);
            # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
            $value = transform_make_vars($value);

            # Handle different assignment operators
            if ($op eq '+=') {
                # Append to existing value (with space separator)
                if (exists $MV{$var} && $MV{$var} ne '') {
                    $MV{$var} .= " $value";
                } else {
                    $MV{$var} = $value;
                }
            } elsif ($op eq ':=') {
                # := is immediate assignment - expand variables before storing
                # Convert $MV{...} back to $(...)  for full expansion
                my $make_syntax = format_output($value);
                # Expand all variables and functions
                my $expanded = expand_vars($make_syntax);
                # Transform back to internal format
                $expanded = transform_make_vars($expanded);
                $MV{$var} = $expanded;
            } elsif ($op eq '?=') {
                # ?= is conditional assignment - only set if not already defined
                unless (exists $MV{$var} && defined $MV{$var} && $MV{$var} ne '') {
                    $MV{$var} = $value;
                }
            } else {
                # = operator is simple/lazy assignment (no expansion)
                $MV{$var} = $value;
            }

            # Handle VPATH variable specially
            # VPATH is equivalent to "vpath % <directories>"
            if ($var eq 'VPATH') {
                # Split directories by whitespace or colon
                my @dirs = split /[\s:]+/, $value;
                @dirs = grep { $_ ne '' } @dirs;
                # VPATH applies to all files (% pattern)
                if (exists $vpath{'%'}) {
                    push @{$vpath{'%'}}, @dirs;
                } else {
                    $vpath{'%'} = \@dirs;
                }
                warn "DEBUG: VPATH set to " . join(", ", @dirs) . " (vpath % pattern)\n" if $ENV{SMAK_DEBUG};
            }

            next;
        }

        # Rule definition (target: dependencies)
        # Must not start with whitespace (tabs are recipe lines, spaces might be command output)
        # Note: We can't use a simple regex split on ':' because Make allows colons
        # inside variable references for substitution syntax: $(var:pattern=replacement)
        # So we need to find the rule-separator colon that's NOT inside parentheses
        if ($line =~ /^(\S)/ && $line =~ /:/) {
            # Find the first colon that's outside of $() or ${}
            my $colon_pos = -1;
            my $paren_depth = 0;
            my $brace_depth = 0;
            my $len = length($line);
            for (my $i = 0; $i < $len; $i++) {
                my $char = substr($line, $i, 1);
                if ($char eq '$' && $i + 1 < $len) {
                    my $next = substr($line, $i + 1, 1);
                    if ($next eq '(') {
                        $paren_depth++;
                        $i++;  # Skip the '('
                    } elsif ($next eq '{') {
                        $brace_depth++;
                        $i++;  # Skip the '{'
                    }
                } elsif ($char eq '(' && $paren_depth > 0) {
                    $paren_depth++;
                } elsif ($char eq ')' && $paren_depth > 0) {
                    $paren_depth--;
                } elsif ($char eq '{' && $brace_depth > 0) {
                    $brace_depth++;
                } elsif ($char eq '}' && $brace_depth > 0) {
                    $brace_depth--;
                } elsif ($char eq ':' && $paren_depth == 0 && $brace_depth == 0) {
                    # Found the rule-separator colon
                    $colon_pos = $i;
                    last;
                }
            }

            # Only proceed if we found a valid colon separator
            if ($colon_pos > 0) {
            $save_current_rule->();

            my $targets_str = substr($line, 0, $colon_pos);
            my $deps_str = substr($line, $colon_pos + 1);

            # Trim whitespace
            $targets_str =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;

            # Transform $(VAR) and $X to $MV{VAR} and $MV{X} in both targets and dependencies
            $targets_str = transform_make_vars($targets_str);
            $deps_str = transform_make_vars($deps_str);

            # Expand variables in target names immediately so rules are stored under expanded names
            # This ensures lookups work correctly (e.g., bin/nvc$(EXEEXT) -> bin/nvc when EXEEXT is empty)
            while ($targets_str =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $targets_str =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            # Fully expand any remaining function calls like $(shell ...)
            # This is needed for targets like $(copts_conf) which depend on $(shell ...)
            if ($targets_str =~ /\$\(/) {
                $targets_str = expand_vars($targets_str);
            }

            # Handle order-only prerequisites (after |)
            # Syntax: target: normal-prereqs | order-only-prereqs
            my @deps;
            my @order_only_deps;
            if ($deps_str =~ /^(.*?)\s*\|\s*(.*)$/) {
                # Has order-only prerequisites
                my $normal_deps_str = $1;
                my $order_only_str = $2;
                @deps = split /\s+/, $normal_deps_str;
                @order_only_deps = split /\s+/, $order_only_str;
                print STDERR "DEBUG parse: Found order-only deps for '$targets_str': " . join(", ", @order_only_deps) . "\n" if $ENV{SMAK_DEBUG};
            } else {
                # No order-only prerequisites
                @deps = split /\s+/, $deps_str;
            }
            @deps = grep { $_ ne '' } @deps;
            @order_only_deps = grep { $_ ne '' } @order_only_deps;

            # Handle multiple targets (e.g., "target1 target2: deps")
            # Make creates the same rule for each target
            my @targets = split /\s+/, $targets_str;
            @targets = grep { $_ ne '' } @targets;

            # Handle .SUFFIXES: directive
            if ($targets_str eq '.SUFFIXES') {
                # Replace suffix list with the specified suffixes
                @suffixes = @deps;
                # Remove $MV{} wrappers from suffixes since they're literal strings
                @suffixes = map {
                    my $s = $_;
                    $s =~ s/\$MV\{([^}]+)\}/$1/g;  # Strip $MV{} wrapper
                    $s;
                } @suffixes;
                warn "DEBUG: .SUFFIXES set to: " . join(' ', @suffixes) . "\n" if $ENV{SMAK_DEBUG};
                # Continue processing to store in pseudo_deps as normal
            }

            # Check for suffix rules and handle them specially
            # A suffix rule looks like .source.target: (e.g., .c.o:)
            # Store it separately to avoid pattern rule collision
            my @suffix_targets = ();
            my @non_suffix_targets = ();
            for my $target (@targets) {
                if ($target =~ /^(\.[^.]+)(\.[^.]+)$/) {
                    my ($source_suffix, $target_suffix) = ($1, $2);
                    # Check if both suffixes are in the suffix list
                    my $has_source = grep { $_ eq $source_suffix } @suffixes;
                    my $has_target = grep { $_ eq $target_suffix } @suffixes;
                    if (@suffixes && $has_source && $has_target) {
                        # This is a suffix rule
                        push @suffix_targets, $target;
                        my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                        # Store dependencies (usually empty for suffix rules)
                        $suffix_deps{$suffix_key} = [@deps];
                        warn "DEBUG: Found suffix rule $target ($source_suffix -> $target_suffix)\n" if $ENV{SMAK_DEBUG};
                    } else {
                        push @non_suffix_targets, $target;
                    }
                } else {
                    push @non_suffix_targets, $target;
                }
            }

            # Store all targets for rule accumulation
            @current_targets = @non_suffix_targets;  # Only non-suffix targets go to normal processing
            @current_suffix_targets = @suffix_targets;  # Track suffix targets separately
            @current_deps = @deps;  # Store dependencies for multi-output detection
            $current_type = classify_target($current_targets[0]) if @current_targets;
            $current_rule = '';

            # For pattern rules, check if ALL dependencies would be filtered
            # If so, discard the entire rule by clearing @current_targets
            if ($current_type && $current_type eq 'pattern' && @deps) {
                my $all_deps_filtered = 1;
                for my $dep (@deps) {
                    if (!should_filter_dependency($dep)) {
                        $all_deps_filtered = 0;
                        last;
                    }
                }

                if ($all_deps_filtered) {
                    warn "DEBUG: Discarding pattern rule with all filtered dependencies: @targets\n" if $ENV{SMAK_DEBUG};
                    @current_targets = ();  # Clear to prevent rule from being saved
                    next;  # Skip dependency storage
                }
            }

            # Store dependencies for all targets
            for my $target (@targets) {
                my $key = "$makefile\t$target";
                my $type = classify_target($target);

                # Skip storing dependencies for inactive pattern rules
                if ($type eq 'pattern') {
                    if (is_inactive_pattern($target)) {
                        warn "DEBUG: Skipping dependencies for inactive pattern: $target\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                    if (has_source_control_recursion($target)) {
                        warn "DEBUG: Skipping dependencies for recursive pattern: $target\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                }

                if ($type eq 'fixed') {
                    # Append dependencies if target already exists (like gmake)
                    if (exists $fixed_deps{$key}) {
                        push @{$fixed_deps{$key}}, @deps;
                    } else {
                        $fixed_deps{$key} = \@deps;
                    }
                    # Store order-only prerequisites
                    if (@order_only_deps) {
                        if (exists $fixed_order_only{$key}) {
                            push @{$fixed_order_only{$key}}, @order_only_deps;
                        } else {
                            $fixed_order_only{$key} = \@order_only_deps;
                        }
                        print STDERR "DEBUG parse: Stored fixed order-only for '$key': " . join(", ", @{$fixed_order_only{$key}}) . "\n" if $ENV{SMAK_DEBUG};
                    }
                } elsif ($type eq 'pattern') {
                    # Pattern rules can have multiple variants with different dependencies
                    # Store each variant's dependencies as a separate arrayref
                    # Initialize arrays if this is the first pattern rule for this target
                    $pattern_deps{$key} = [] unless exists $pattern_deps{$key};
                    $pattern_order_only{$key} = [] unless exists $pattern_order_only{$key};
                    # Append this variant's dependencies
                    push @{$pattern_deps{$key}}, \@deps;
                    push @{$pattern_order_only{$key}}, \@order_only_deps;
                    warn "DEBUG: Added pattern deps variant for $key (now have " . scalar(@{$pattern_deps{$key}}) . " variants)\n" if $ENV{SMAK_DEBUG};
                } elsif ($type eq 'pseudo') {
                    # Append dependencies if target already exists (like gmake)
                    if (exists $pseudo_deps{$key}) {
                        push @{$pseudo_deps{$key}}, @deps;
                    } else {
                        $pseudo_deps{$key} = \@deps;
                    }
                    # Store order-only prerequisites
                    if (@order_only_deps) {
                        if (exists $pseudo_order_only{$key}) {
                            push @{$pseudo_order_only{$key}}, @order_only_deps;
                        } else {
                            $pseudo_order_only{$key} = \@order_only_deps;
                        }
                    }
                }

                # Set default target to first non-pseudo, non-pattern target (like gmake)
                # Also exclude targets with unexpanded variables and special targets
                if (!defined $default_target && $type ne 'pseudo' && $type ne 'pattern') {
                    # Skip targets with unexpanded variables like $(VERBOSE).SILENT
                    if ($target =~ /\$/) {
                        warn "DEBUG: Skipping target with variable: '$target'\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                    # Skip special targets like .SILENT, .PHONY, etc.
                    if ($target =~ /^\./) {
                        warn "DEBUG: Skipping special target: '$target'\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                    # Skip targets declared in .PHONY
                    my $phony_key = "$makefile\t.PHONY";
                    if (exists $pseudo_deps{$phony_key}) {
                        my @phony_targets = @{$pseudo_deps{$phony_key} || []};
                        if (grep { $_ eq $target } @phony_targets) {
                            warn "DEBUG: Skipping .PHONY target: '$target'\n" if $ENV{SMAK_DEBUG};
                            next;
                        }
                    }

                    $default_target = $target;
                    warn "DEBUG: Setting default target to: '$target'\n" if $ENV{SMAK_DEBUG};
                }
            }

            next;
            }  # end if ($colon_pos > 0)
        }

        # Rule command (starts with tab)
        if ($line =~ /^\t(.*)$/ && (@current_targets || @current_suffix_targets)) {
            my $cmd = $1;

            # Handle line continuations for command lines
            while ($cmd =~ /\\$/) {
                $cmd =~ s/\\$/ /;  # Replace backslash with space
                my $next = <$fh>;
                last unless defined $next;
                chomp $next;
                $next =~ s/^\s+//;  # Remove leading whitespace from continuation line
                $cmd .= $next;
            }

            # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
            $cmd = transform_make_vars($cmd);
            $current_rule .= "$cmd\n";
            next;
        }

        # If we get here with a current target, save it
        $save_current_rule->() if @current_targets;
    }

    # Save the last rule if any
    $save_current_rule->();

    # Add built-in pattern rules for compilation if not already defined (like GNU make)
    # Multiple rules can now be defined for the same target pattern
    {
        my $target_pattern = "%.o";
        my $key = "$makefile\t$target_pattern";

        # Define built-in rules in priority order (C first, then C++)
        my @builtin_variants = (
            {dep => "%.c",   command => "\$(CC) \$(CFLAGS) \$(CPPFLAGS) \$(TARGET_ARCH) -c -o \$@ \$<"},
            {dep => "%.cc",  command => "\$(CXX) \$(CXXFLAGS) \$(CPPFLAGS) \$(TARGET_ARCH) -c -o \$@ \$<"},
            {dep => "%.cpp", command => "\$(CXX) \$(CXXFLAGS) \$(CPPFLAGS) \$(TARGET_ARCH) -c -o \$@ \$<"},
            {dep => "%.C",   command => "\$(CXX) \$(CXXFLAGS) \$(CPPFLAGS) \$(TARGET_ARCH) -c -o \$@ \$<"},
        );

        # Only add built-in rules if no user-defined rules exist for this pattern
        unless (exists $pattern_rule{$key}) {
            $pattern_rule{$key} = [];
            $pattern_deps{$key} = [];
            $pattern_order_only{$key} = [];

            for my $variant (@builtin_variants) {
                my $command = transform_make_vars($variant->{command});
                push @{$pattern_rule{$key}}, $command;
                push @{$pattern_deps{$key}}, [$variant->{dep}];
                push @{$pattern_order_only{$key}}, [];
                warn "DEBUG: Added built-in pattern rule: $target_pattern: $variant->{dep}\n" if $ENV{SMAK_DEBUG};
            }
        }
    }

    close($fh);

    # Save state to cache after successful parse
    save_state_cache($makefile_path);
}

sub parse_included_makefile {
    my ($include_path) = @_;

    # Parse an included Makefile without resetting global state
    # Variables and rules are added to the existing %MV, %fixed_deps, etc.

    open(my $fh, '<', $include_path) or do {
        warn "Warning: Cannot open included file $include_path: $!\n";
        return;
    };

    # Temporarily update $makefile for proper key generation
    my $saved_makefile = $makefile;
    $makefile = $include_path;

    my @current_targets;  # Array to handle multiple targets
    my $current_rule = '';
    my $current_type;
    my @current_deps;  # Track current dependencies for multi-output detection
    my @current_suffix_targets;  # Track suffix rule targets separately

    my $save_current_rule = sub {
        # Save suffix rules first
        for my $suffix_target (@current_suffix_targets) {
            if ($suffix_target =~ /^(\.[^.]+)(\.[^.]+)$/) {
                my ($source_suffix, $target_suffix) = ($1, $2);
                my $suffix_key = "$saved_makefile\t$source_suffix\t$target_suffix";
                $suffix_rule{$suffix_key} = $current_rule;
                warn "DEBUG: Saved suffix rule $suffix_target (from include): " . substr($current_rule, 0, 50) . "...\n" if $ENV{SMAK_DEBUG};
            }
        }

        return unless @current_targets;

        # Detect multi-output pattern rules (same as in main parse_makefile)
        my @pattern_targets = grep { classify_target($_) eq 'pattern' } @current_targets;
        if (@pattern_targets > 1) {
            my $prereqs_key = join(',', @current_deps);
            my $group_key = "$saved_makefile\t$prereqs_key\t$current_rule";

            $multi_output_groups{$group_key} = [@pattern_targets];

            for my $target (@pattern_targets) {
                my $target_key = "$saved_makefile\t$target";
                $multi_output_siblings{$target_key} = [@pattern_targets];
            }

            warn "DEBUG: Multi-output pattern rule in included file: @pattern_targets\n" if $ENV{SMAK_DEBUG};
        }

        # Save rule for all targets in the current rule
        for my $target (@current_targets) {
            my $key = "$saved_makefile\t$target";  # Use original makefile for keys
            my $type = classify_target($target);

            if ($type eq 'fixed') {
                # Only overwrite if no rule exists or existing rule is empty (GNU make: first rule with commands wins)
                if (!exists $fixed_rule{$key} || !defined $fixed_rule{$key} || $fixed_rule{$key} !~ /\S/) {
                    $fixed_rule{$key} = $current_rule;
                }
            } elsif ($type eq 'pattern') {
                # Pattern rules can have multiple variants (e.g., %.o from %.c, %.cc, %.cpp)
                # Only add if the rule has commands
                if ($current_rule && $current_rule =~ /\S/) {
                    # Initialize arrays if this is the first pattern rule for this target
                    $pattern_rule{$key} = [] unless exists $pattern_rule{$key};
                    # Append this rule variant
                    push @{$pattern_rule{$key}}, $current_rule;
                    warn "DEBUG: Added pattern rule variant for $key in included file (now have " . scalar(@{$pattern_rule{$key}}) . " variants)\n" if $ENV{SMAK_DEBUG};
                }
            } elsif ($type eq 'pseudo') {
                if (!exists $pseudo_rule{$key} || !defined $pseudo_rule{$key} || $pseudo_rule{$key} !~ /\S/) {
                    $pseudo_rule{$key} = $current_rule;
                }
            }
        }

        @current_targets = ();
        @current_deps = ();
        $current_rule = '';
        $current_type = undef;
    };

    # Conditional stack for included files
    my @cond_stack = ({active => 1, seen_else => 0});

    while (my $line = <$fh>) {
        chomp $line;

        # Handle line continuations
        while ($line =~ /\\$/) {
            $line =~ s/\\$//;
            my $next = <$fh>;
            last unless defined $next;
            chomp $next;
            $line .= $next;
        }

        # Handle conditional directives (same as in parse_makefile)
        if ($line =~ /^\s*ifeq\s+(.+)$/ || $line =~ /^\s*ifneq\s+(.+)$/) {
            my $args = $1;  # Capture $1 BEFORE doing another regex match
            my $is_ifeq = ($line =~ /ifeq/);
            my $result = 0;

            if ($args =~ /^\s*\(([^,]*),([^)]*)\)\s*$/ || $args =~ /^\s*"([^"]*)"\s+"([^"]*)"$/ || $args =~ /^\s*'([^']*)'\s+'([^']*)'$/) {
                my ($arg1, $arg2) = ($1, $2);
                $arg1 = transform_make_vars($arg1);
                $arg2 = transform_make_vars($arg2);
                while ($arg1 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg1 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                while ($arg2 =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $arg2 =~ s/\$MV\{\Q$var\E\}/$val/;
                }
                $arg1 =~ s/^\s+|\s+$//g;
                $arg2 =~ s/^\s+|\s+$//g;
                $result = ($arg1 eq $arg2);
                $result = !$result if !$is_ifeq;
                warn "DEBUG(include): $line => $is_ifeq('$arg1', '$arg2') = $result\n" if $ENV{SMAK_DEBUG};
            }

            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*ifdef\s+(\S+)$/ || $line =~ /^\s*ifndef\s+(\S+)$/) {
            my $var = $1;  # Capture $1 BEFORE doing another regex match
            my $is_ifdef = ($line =~ /ifdef/);
            my $result = exists $MV{$var} && defined $MV{$var} && $MV{$var} ne '';
            $result = !$result if !$is_ifdef;
            warn "DEBUG(include): $line => $var defined=" . (exists $MV{$var} ? "yes" : "no") . ", result=$result\n" if $ENV{SMAK_DEBUG};

            my $parent_active = $cond_stack[-1]{active};
            push @cond_stack, {active => ($parent_active && $result), seen_else => 0};
            next;
        }
        elsif ($line =~ /^\s*else\s*$/) {
            if (@cond_stack <= 1) {
                warn "Warning: else without matching if in $include_path\n";
                next;
            }
            my $cond = $cond_stack[-1];
            if ($cond->{seen_else}) {
                warn "Warning: duplicate else in $include_path\n";
                next;
            }
            $cond->{seen_else} = 1;
            my $parent_active = $cond_stack[-2]{active};
            $cond->{active} = $parent_active && !$cond->{active};
            warn "DEBUG(include): else => active now " . $cond->{active} . "\n" if $ENV{SMAK_DEBUG};
            next;
        }
        elsif ($line =~ /^\s*endif\s*$/) {
            if (@cond_stack <= 1) {
                warn "Warning: endif without matching if in $include_path\n";
                next;
            }
            pop @cond_stack;
            warn "DEBUG(include): endif => stack depth now " . scalar(@cond_stack) . "\n" if $ENV{SMAK_DEBUG};
            next;
        }

        # Skip lines if in inactive conditional branch
        unless ($cond_stack[-1]{active}) {
            if ($line =~ /^\t/ && !@current_targets) {
                # Recipe line but no target - skip
            } elsif ($line =~ /^(\S[^:]*?):\s*(.*)$/) {
                # New rule while skipping - clear current targets
                @current_targets = ();
                @current_suffix_targets = ();
                $current_rule = '';
            }
            next;
        }

        # Skip comments and empty lines
        if (!@current_targets && ($line =~ /^\s*#/ || $line =~ /^\s*$/)) {
            next;
        }

        # Handle include directives (nested includes)
        if ($line =~ /^-?include\s+(.+?)(?:\s*#.*)?$/) {
            $save_current_rule->();
            my $include_files = $1;
            # Expand variables and functions in the include filename
            $include_files = expand_vars($include_files);

            # Handle multiple includes on one line
            for my $include_file (split /\s+/, $include_files) {
                # Skip empty entries
                next if $include_file eq '';

                # Determine include path
                my $nested_include_path = $include_file;

                # If not absolute path, try to find the file
                unless ($nested_include_path =~ m{^/}) {
                    use File::Basename;
                    use File::Spec;

                    # First try relative to current working directory
                    if (-f $include_file) {
                        $nested_include_path = $include_file;
                    } else {
                        # Try relative to current Makefile's directory
                        my $makefile_dir = dirname($makefile);
                        my $relative_path = File::Spec->catfile($makefile_dir, $include_file);
                        if (-f $relative_path) {
                            $nested_include_path = $relative_path;
                        } else {
                            # Use the relative path for error reporting even if not found
                            $nested_include_path = $relative_path;
                        }
                    }
                }

                # Parse the included file (ignore if it doesn't exist and line starts with -)
                if (-f $nested_include_path) {
                    print STDERR "DEBUG: including '$nested_include_path' (nested)\n" if $ENV{SMAK_DEBUG};
                    # Recursively parse the nested included file
                    parse_included_makefile($nested_include_path);
                } elsif ($line !~ /^-include/) {
                    warn "Warning: included file not found: $nested_include_path\n";
                } elsif ($ENV{SMAK_DEBUG}) {
                    print STDERR "DEBUG: optional include not found (ignored): $nested_include_path\n";
                }
            }
            next;
        }

        # Variable assignment (most important for included files like flags.make)
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*([:?+]?=)\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $op, $value) = ($1, $2, $3);
            $value = transform_make_vars($value);

            # Handle different assignment operators
            if ($op eq '+=') {
                # Append to existing value (with space separator)
                if (exists $MV{$var} && $MV{$var} ne '') {
                    $MV{$var} .= " $value";
                } else {
                    $MV{$var} = $value;
                }
            } elsif ($op eq ':=') {
                # := is immediate assignment - expand variables before storing
                # Convert $MV{...} back to $(...)  for full expansion
                my $make_syntax = format_output($value);
                # Expand all variables and functions
                my $expanded = expand_vars($make_syntax);
                # Transform back to internal format
                $expanded = transform_make_vars($expanded);
                $MV{$var} = $expanded;
            } elsif ($op eq '?=') {
                # ?= is conditional assignment - only set if not already defined
                unless (exists $MV{$var} && defined $MV{$var} && $MV{$var} ne '') {
                    $MV{$var} = $value;
                }
            } else {
                # = operator is simple/lazy assignment (no expansion)
                $MV{$var} = $value;
            }
            next;
        }

        # Rule definition (included files might have rules too)
        # Must not start with whitespace (tabs are recipe lines)
        # Note: We can't use a simple regex split on ':' because Make allows colons
        # inside variable references for substitution syntax: $(var:pattern=replacement)
        # So we need to find the rule-separator colon that's NOT inside parentheses
        if ($line =~ /^(\S)/ && $line =~ /:/) {
            # Find the first colon that's outside of $() or ${}
            my $colon_pos = -1;
            my $paren_depth = 0;
            my $brace_depth = 0;
            my $len = length($line);
            for (my $i = 0; $i < $len; $i++) {
                my $char = substr($line, $i, 1);
                if ($char eq '$' && $i + 1 < $len) {
                    my $next = substr($line, $i + 1, 1);
                    if ($next eq '(') {
                        $paren_depth++;
                        $i++;  # Skip the '('
                    } elsif ($next eq '{') {
                        $brace_depth++;
                        $i++;  # Skip the '{'
                    }
                } elsif ($char eq '(' && $paren_depth > 0) {
                    $paren_depth++;
                } elsif ($char eq ')' && $paren_depth > 0) {
                    $paren_depth--;
                } elsif ($char eq '{' && $brace_depth > 0) {
                    $brace_depth++;
                } elsif ($char eq '}' && $brace_depth > 0) {
                    $brace_depth--;
                } elsif ($char eq ':' && $paren_depth == 0 && $brace_depth == 0) {
                    # Found the rule-separator colon
                    $colon_pos = $i;
                    last;
                }
            }

            # Only proceed if we found a valid colon separator
            if ($colon_pos > 0) {
            $save_current_rule->();

            my $targets_str = substr($line, 0, $colon_pos);
            my $deps_str = substr($line, $colon_pos + 1);

            $targets_str =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;

            # Transform $(VAR) and $X to $MV{VAR} and $MV{X} in both targets and dependencies
            $targets_str = transform_make_vars($targets_str);
            $deps_str = transform_make_vars($deps_str);

            # Expand variables in target names immediately so rules are stored under expanded names
            while ($targets_str =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $targets_str =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            # Fully expand any remaining function calls like $(shell ...)
            # This is needed for targets like $(copts_conf) which depend on $(shell ...)
            if ($targets_str =~ /\$\(/) {
                $targets_str = expand_vars($targets_str);
            }

            # Handle order-only prerequisites (after |)
            my @deps;
            my @order_only_deps;
            if ($deps_str =~ /^(.*?)\s*\|\s*(.*)$/) {
                # Has order-only prerequisites
                my $normal_deps_str = $1;
                my $order_only_str = $2;
                @deps = split /\s+/, $normal_deps_str;
                @order_only_deps = split /\s+/, $order_only_str;
                print STDERR "DEBUG parse(include): Found order-only deps for '$targets_str': " . join(", ", @order_only_deps) . "\n" if $ENV{SMAK_DEBUG};
            } else {
                # No order-only prerequisites
                @deps = split /\s+/, $deps_str;
            }
            @deps = grep { $_ ne '' } @deps;
            @order_only_deps = grep { $_ ne '' } @order_only_deps;

            # Handle multiple targets
            my @targets = split /\s+/, $targets_str;
            @targets = grep { $_ ne '' } @targets;

            # Handle .SUFFIXES: directive in included files
            if ($targets_str eq '.SUFFIXES') {
                @suffixes = @deps;
                # Remove $MV{} wrappers from suffixes since they're literal strings
                @suffixes = map {
                    my $s = $_;
                    $s =~ s/\$MV\{([^}]+)\}/$1/g;
                    $s;
                } @suffixes;
                warn "DEBUG: .SUFFIXES set to (in include): " . join(' ', @suffixes) . "\n" if $ENV{SMAK_DEBUG};
            }

            # Check for suffix rules in included files
            my @suffix_targets = ();
            my @non_suffix_targets = ();
            for my $target (@targets) {
                if ($target =~ /^(\.[^.]+)(\.[^.]+)$/) {
                    my ($source_suffix, $target_suffix) = ($1, $2);
                    my $has_source = grep { $_ eq $source_suffix } @suffixes;
                    my $has_target = grep { $_ eq $target_suffix } @suffixes;
                    if (@suffixes && $has_source && $has_target) {
                        push @suffix_targets, $target;
                        my $suffix_key = "$saved_makefile\t$source_suffix\t$target_suffix";
                        $suffix_deps{$suffix_key} = [@deps];
                        warn "DEBUG: Found suffix rule $target (in include) ($source_suffix -> $target_suffix)\n" if $ENV{SMAK_DEBUG};
                    } else {
                        push @non_suffix_targets, $target;
                    }
                } else {
                    push @non_suffix_targets, $target;
                }
            }

            @current_targets = @non_suffix_targets;
            @current_suffix_targets = @suffix_targets;
            @current_deps = @deps;  # Store dependencies for multi-output detection
            $current_type = classify_target($current_targets[0]) if @current_targets;
            $current_rule = '';

            # Store dependencies for all non-suffix targets
            for my $target (@non_suffix_targets) {
                my $key = "$saved_makefile\t$target";
                my $type = classify_target($target);

                if ($type eq 'fixed') {
                    if (exists $fixed_deps{$key}) {
                        push @{$fixed_deps{$key}}, @deps;
                    } else {
                        $fixed_deps{$key} = \@deps;
                    }
                    # Store order-only prerequisites
                    if (@order_only_deps) {
                        if (exists $fixed_order_only{$key}) {
                            push @{$fixed_order_only{$key}}, @order_only_deps;
                        } else {
                            $fixed_order_only{$key} = \@order_only_deps;
                        }
                    }
                } elsif ($type eq 'pattern') {
                    # Pattern rules can have multiple variants with different dependencies
                    # Store each variant's dependencies as a separate arrayref
                    # Initialize arrays if this is the first pattern rule for this target
                    $pattern_deps{$key} = [] unless exists $pattern_deps{$key};
                    $pattern_order_only{$key} = [] unless exists $pattern_order_only{$key};
                    # Append this variant's dependencies
                    push @{$pattern_deps{$key}}, \@deps;
                    push @{$pattern_order_only{$key}}, \@order_only_deps;
                    warn "DEBUG: Added pattern deps variant for $key in included file (now have " . scalar(@{$pattern_deps{$key}}) . " variants)\n" if $ENV{SMAK_DEBUG};
                } elsif ($type eq 'pseudo') {
                    if (exists $pseudo_deps{$key}) {
                        push @{$pseudo_deps{$key}}, @deps;
                    } else {
                        $pseudo_deps{$key} = \@deps;
                    }
                    # Store order-only prerequisites
                    if (@order_only_deps) {
                        if (exists $pseudo_order_only{$key}) {
                            push @{$pseudo_order_only{$key}}, @order_only_deps;
                        } else {
                            $pseudo_order_only{$key} = \@order_only_deps;
                        }
                    }
                }
            }

            next;
            }  # end if ($colon_pos > 0)
        }

        # Rule command
        if ($line =~ /^\t(.*)$/ && (@current_targets || @current_suffix_targets)) {
            my $cmd = $1;

            # Handle line continuations for command lines
            while ($cmd =~ /\\$/) {
                $cmd =~ s/\\$/ /;  # Replace backslash with space
                my $next = <$fh>;
                last unless defined $next;
                chomp $next;
                $next =~ s/^\s+//;  # Remove leading whitespace from continuation line
                $cmd .= $next;
            }

            $cmd = transform_make_vars($cmd);
            $current_rule .= "$cmd\n";
            next;
        }

        # If we get here with a current target, save it
        $save_current_rule->() if @current_targets;
    }

    # Save the last rule if any
    $save_current_rule->();

    close($fh);
    $makefile = $saved_makefile;

    # Always do this
    init_ignore_dirs();

    # Initialize optimizations once (first time any makefile is parsed)
    warn "DEBUG: Checking if init needed - inactive_patterns has " . scalar(keys %inactive_patterns) . " entries\n" if $ENV{SMAK_DEBUG};
    if (!%inactive_patterns) {
        warn "DEBUG: Initializing ignore dirs and inactive patterns\n" if $ENV{SMAK_DEBUG};
        detect_inactive_patterns();
    } else {
        warn "DEBUG: Skipping pattern detection - inactive_patterns already populated\n" if $ENV{SMAK_DEBUG};
    }

    # Don't save state here - let the main parse_makefile save it after everything is parsed
    # Saving here causes incomplete cache if recursive make runs before main Makefile finishes
}

sub get_default_target {
    return $default_target;
}

# Initialize ignored directories from SMAK_IGNORE_DIRS environment variable
# Format: colon-separated list like "/usr/include:/usr/local/include"
sub init_ignore_dirs {
    warn "DEBUG: init_ignore_dirs() called, \@ignore_dirs has " . scalar(@ignore_dirs) . " entries\n" if $ENV{SMAK_DEBUG};
    warn "DEBUG: SMAK_IGNORE_DIRS = '" . ($ENV{SMAK_IGNORE_DIRS} || "(not set)") . "'\n" if $ENV{SMAK_DEBUG};

    return if @ignore_dirs;  # Already initialized

    if ($ENV{SMAK_IGNORE_DIRS}) {
        @ignore_dirs = split(':', $ENV{SMAK_IGNORE_DIRS});
        warn "DEBUG: Split into " . scalar(@ignore_dirs) . " directories\n" if $ENV{SMAK_DEBUG};

        # Cache directory mtimes for efficient checking
        for my $dir (@ignore_dirs) {
            if (-d $dir) {
                $ignore_dir_mtimes{$dir} = (stat($dir))[9];
                warn "DEBUG: Ignoring directory '$dir' (mtime=" . $ignore_dir_mtimes{$dir} . ")\n" if $ENV{SMAK_DEBUG};
            } else {
                warn "WARNING: SMAK_IGNORE_DIRS contains non-existent directory: $dir\n";
            }
        }
    }
}

# Check if a file is under an ignored directory
# Returns the ignored directory path if found, undef otherwise
sub is_ignored_dir {
    my ($file) = @_;

    for my $dir (@ignore_dirs) {
        # Check if file is under this directory
        if ($file =~ m{^\Q$dir\E(/|$)}) {
            return $dir;
        }
    }

    return undef;
}

# Detect which implicit rule patterns are inactive (don't exist in the project)
# This is called once at startup to optimize away unnecessary pattern checks
sub detect_inactive_patterns {
    warn "DEBUG: detect_inactive_patterns() called\n" if $ENV{SMAK_DEBUG};

    # Check for RCS version control files
    # Quick heuristic: if no RCS directory exists in common locations, mark as inactive
    my $has_rcs = 0;
    if (-d "RCS" || -d "src/RCS" || -d "../RCS") {
        $has_rcs = 1;
    } else {
        # Also check if any ,v files exist in current directory
        my @rcs_files = glob("*,v");  # Note: comma before v, not dot
        $has_rcs = 1 if @rcs_files;
    }

    if (!$has_rcs) {
        $inactive_patterns{'RCS'} = 1;
        warn "DEBUG: RCS patterns marked inactive (no RCS files detected)\n" if $ENV{SMAK_DEBUG};
    } else {
        warn "DEBUG: RCS files detected in project, keeping RCS patterns active\n" if $ENV{SMAK_DEBUG};
    }

    # Check for SCCS version control files
    my $has_sccs = 0;
    if (-d "SCCS" || -d "src/SCCS" || -d "../SCCS") {
        $has_sccs = 1;
    } else {
        # Also check if any s.* files exist in current directory
        my @sccs_files = glob("s.*");
        $has_sccs = 1 if @sccs_files;
    }

    if (!$has_sccs) {
        $inactive_patterns{'SCCS'} = 1;
        warn "DEBUG: SCCS patterns marked inactive (no SCCS files detected)\n" if $ENV{SMAK_DEBUG};
    } else {
        warn "DEBUG: SCCS files detected in project, keeping SCCS patterns active\n" if $ENV{SMAK_DEBUG};
    }

    # Debug: show final state
    if ($ENV{SMAK_DEBUG}) {
        warn "DEBUG: Inactive patterns after detection: " . join(", ", map { "$_=$inactive_patterns{$_}" } keys %inactive_patterns) . "\n";
    }
}

# Check if a file matches inactive implicit rule patterns
# Returns 1 if the file should be skipped (inactive pattern), 0 otherwise
sub is_inactive_pattern {
    my ($file) = @_;

    # Debug: show what we're checking and what patterns are inactive (level 2+)
    if (($ENV{SMAK_DEBUG} || 0) >= 2 && ($file =~ /RCS/ || $file =~ /SCCS/ || $file =~ /,v/ || $file =~ /^s\./)) {
        my $rcs_inactive = $inactive_patterns{'RCS'} || 0;
        my $sccs_inactive = $inactive_patterns{'SCCS'} || 0;
        warn "DEBUG is_inactive_pattern: checking '$file' (RCS=$rcs_inactive, SCCS=$sccs_inactive)\n";
    }

    # Check RCS patterns if inactive
    if ($inactive_patterns{'RCS'}) {
        return 1 if $file =~ m{(?:^|/)RCS/};  # RCS/ directory anywhere in path
        return 1 if $file =~ /,v+$/;           # ,v suffix (possibly repeated)
        return 1 if $file =~ /,v,/;            # Multiple ,v suffixes (recursive pattern)
    }

    # Check SCCS patterns if inactive
    if ($inactive_patterns{'SCCS'}) {
        return 1 if $file =~ m{(?:^|/)SCCS/};  # SCCS/ directory anywhere in path
        return 1 if $file =~ m{(?:^|/)s\.};    # s.* prefix (anywhere after /)
    }

    return 0;
}

# Get cache directory for current project
# Returns undef if caching is disabled
sub get_cache_dir {
    use Cwd 'abs_path';
    use File::Basename;

    # Determine cache directory
    # Caching is always enabled by default (rules don't change unless makefiles change)
    my $cdir = $ENV{SMAK_CACHE_DIR};
    if (defined $cdir) {
        # Disable caching for "off" or "0"
        return undef if ($cdir eq "off" || $cdir eq "0");
        # Use default location for "default" or "1"
        # (fall through to default calculation below)
        unless ($cdir eq "default" || $cdir eq "1") {
            # Use specified path
            return $cdir;
        }
    }

    # Default: /tmp/<user>/smak/<project>/
    my $user = $ENV{USER} || $ENV{USERNAME} || 'unknown';
    my $cwd = Cwd::getcwd();
    my $proj_name = basename($cwd);

    return "/tmp/$user/smak/$proj_name";
}

# Get directory for job-server port files
# Always returns a directory (used for all port files, not just when caching)
sub get_port_file_dir {
    my $user = $ENV{USER} || $ENV{USERNAME} || 'unknown';
    my $dir = "/tmp/$user/smak";

    # Create directory if it doesn't exist
    unless (-d $dir) {
        use File::Path qw(make_path);
        make_path($dir) or warn "WARNING: Cannot create port file directory '$dir': $!\n";
    }

    return $dir;
}

# Get path to cache file for given makefile
sub get_cache_file {
    my ($makefile_path) = @_;

    my $dir = get_cache_dir();
    return undef unless $dir;

    # Create cache directory if it doesn't exist
    unless (-d $dir) {
        use File::Path qw(make_path);
        make_path($dir) or do {
            warn "WARNING: Cannot create cache directory '$dir': $!\n";
            return undef;
        };
    }

    # Use makefile basename for cache file (simple approach)
    my $cache_file = "$dir/state.cache";
    return $cache_file;
}

# Save current state to cache file
sub save_state_cache {
    my ($makefile_path) = @_;

    my $cache_file = get_cache_file($makefile_path);
    return unless $cache_file;

    warn "DEBUG: Saving state to '$cache_file'\n" if $ENV{SMAK_DEBUG};

    open(my $fh, '>', $cache_file) or do {
        warn "WARNING: Cannot write cache file '$cache_file': $!\n";
        return;
    };

    # Write Perl code to restore state
    print $fh "# Smak state cache generated " . localtime() . "\n";
    print $fh "# DO NOT EDIT - automatically generated\n\n";

    # Save cache version for invalidation
    print $fh "# Cache version\n";
    print $fh "\$Smak::_cache_version = $CACHE_VERSION;\n\n";

    # Save file mtimes and sizes for validation
    print $fh "# File mtimes and sizes for cache validation\n";
    print $fh "\%Smak::parsed_file_mtimes = (\n";
    for my $file (sort keys %parsed_file_mtimes) {
        my $info = $parsed_file_mtimes{$file};
        my ($mtime, $size) = ref($info) eq 'ARRAY' ? @$info : ($info, 0);
        print $fh "    " . _quote_string($file) . " => [$mtime, $size],\n";
    }
    print $fh ");\n\n";

    # Save default target
    if (defined $default_target) {
        print $fh "\$Smak::default_target = " . _quote_string($default_target) . ";\n\n";
    }

    # Save MV hash
    print $fh "# Makefile variables\n";
    print $fh "\%Smak::MV = (\n";
    for my $var (sort keys %MV) {
        print $fh "    " . _quote_string($var) . " => " . _quote_string($MV{$var}) . ",\n";
    }
    print $fh ");\n\n";

    # Save rules and dependencies
    _save_hash($fh, "fixed_rule", \%fixed_rule);
    _save_hash($fh, "fixed_deps", \%fixed_deps);
    _save_hash($fh, "fixed_order_only", \%fixed_order_only);
    _save_hash($fh, "pattern_rule", \%pattern_rule);
    _save_hash($fh, "pattern_deps", \%pattern_deps);
    _save_hash($fh, "pattern_order_only", \%pattern_order_only);
    _save_hash($fh, "pseudo_rule", \%pseudo_rule);
    _save_hash($fh, "pseudo_deps", \%pseudo_deps);
    _save_hash($fh, "pseudo_order_only", \%pseudo_order_only);
    _save_hash($fh, "suffix_rule", \%suffix_rule);
    _save_hash($fh, "suffix_deps", \%suffix_deps);
    _save_hash($fh, "multi_output_siblings", \%multi_output_siblings);

    # Save suffixes list
    print $fh "# Suffixes\n";
    print $fh "\@Smak::suffixes = (" . join(", ", map { _quote_string($_) } @suffixes) . ");\n\n";

    # Save vpath
    print $fh "# VPATH directories\n";
    print $fh "\%Smak::vpath = (\n";
    for my $pattern (sort keys %vpath) {
        my @dirs = @{$vpath{$pattern}};
        print $fh "    " . _quote_string($pattern) . " => [" . join(", ", map { _quote_string($_) } @dirs) . "],\n";
    }
    print $fh ");\n\n";

    # Save inactive patterns
    print $fh "# Inactive patterns\n";
    print $fh "\%Smak::inactive_patterns = (\n";
    for my $pattern (sort keys %inactive_patterns) {
        print $fh "    " . _quote_string($pattern) . " => " . $inactive_patterns{$pattern} . ",\n";
    }
    print $fh ");\n\n";

    close($fh);
    warn "DEBUG: State saved successfully\n" if $ENV{SMAK_DEBUG};
}

# Load state from cache file if valid
# Returns 1 if loaded successfully, 0 otherwise
sub load_state_cache {
    my ($makefile_path) = @_;

    my $cache_file = get_cache_file($makefile_path);
    return 0 unless $cache_file;
    return 0 unless -f $cache_file;

    warn "DEBUG: Checking cache file '$cache_file'\n" if $ENV{SMAK_DEBUG};

    # Load the cache file
    my $result = do $cache_file;
    unless (defined $result) {
        if ($@) {
            warn "WARNING: Error loading cache: $@\n" if $ENV{SMAK_DEBUG};
        } elsif ($!) {
            warn "WARNING: Cannot read cache file: $!\n" if $ENV{SMAK_DEBUG};
        }
        return 0;
    }

    # Check cache version
    our $_cache_version;
    if (!defined $_cache_version || $_cache_version != $CACHE_VERSION) {
        warn "DEBUG: Cache invalid - version mismatch (cache=$_cache_version, current=$CACHE_VERSION)\n" if $ENV{SMAK_DEBUG};
        return 0;
    }

    # Check that the current Makefile is the one this cache was made for
    use Cwd 'abs_path';
    my $abs_makefile = abs_path($makefile_path) || $makefile_path;
    unless (exists $parsed_file_mtimes{$abs_makefile}) {
        warn "DEBUG: Cache invalid - current Makefile '$abs_makefile' not in cached files\n" if $ENV{SMAK_DEBUG};
        return 0;
    }

    # Validate cache - check if any makefile has changed (mtime or size)
    my $cache_mtime = (stat($cache_file))[9];
    for my $file (keys %parsed_file_mtimes) {
        if (-f $file) {
            my @st = stat($file);
            my ($file_mtime, $file_size) = ($st[9], $st[7]);
            my $cached = $parsed_file_mtimes{$file};
            my ($cached_mtime, $cached_size) = ref($cached) eq 'ARRAY' ? @$cached : ($cached, 0);
            if ($file_mtime != $cached_mtime || $file_size != $cached_size || $file_mtime > $cache_mtime) {
                warn "DEBUG: Cache invalid - '$file' has changed\n" if $ENV{SMAK_DEBUG};
                return 0;
            }
        } else {
            warn "DEBUG: Cache invalid - '$file' no longer exists\n" if $ENV{SMAK_DEBUG};
            return 0;
        }
    }

    warn "DEBUG: Cache loaded successfully\n" if $ENV{SMAK_DEBUG};
    return 1;
}

# Helper: save a hash to cache file
sub _save_hash {
    my ($fh, $name, $hashref) = @_;

    print $fh "# $name\n";
    print $fh "\%Smak::$name = (\n";
    for my $key (sort keys %$hashref) {
        my $val = $hashref->{$key};
        if (ref($val) eq 'ARRAY') {
            print $fh "    " . _quote_string($key) . " => [" . join(", ", map { _serialize_value($_) } @$val) . "],\n";
        } else {
            print $fh "    " . _quote_string($key) . " => " . _quote_string($val) . ",\n";
        }
    }
    print $fh ");\n\n";
}

# Helper: serialize a value (handles nested arrays)
sub _serialize_value {
    my ($val) = @_;
    if (ref($val) eq 'ARRAY') {
        return "[" . join(", ", map { _serialize_value($_) } @$val) . "]";
    } else {
        return _quote_string($val);
    }
}

# Helper: quote a string for Perl code
sub _quote_string {
    my ($str) = @_;
    return 'undef' unless defined $str;
    $str =~ s/\\/\\\\/g;  # Escape backslashes
    $str =~ s/'/\\'/g;    # Escape single quotes
    return "'$str'";
}

# Cache for vpath resolutions to avoid repeated lookups
our %vpath_cache;

# Resolve a file through vpath directories
sub resolve_vpath {
    my ($file, $dir) = @_;

    # Check cache first - key includes both file and dir for correctness
    my $cache_key = "$dir\t$file";
    if (exists $vpath_cache{$cache_key}) {
        return $vpath_cache{$cache_key};
    }

    # Skip inactive implicit rule patterns (e.g., RCS/SCCS if not present in project)
    # This avoids unnecessary vpath resolution and debug spam for patterns that don't exist
    if (is_inactive_pattern($file)) {
        warn "DEBUG vpath: Skipping inactive pattern file '$file'\n" if ($ENV{SMAK_DEBUG} || 0) >= 2;
        $vpath_cache{$cache_key} = $file;
        return $file;  # Return as-is without vpath resolution
    }

    # Skip files in ignored directories (e.g., /usr/include, /usr/local/include)
    # These are system directories that won't change, so no need for vpath resolution
    if (is_ignored_dir($file)) {
        $vpath_cache{$cache_key} = $file;
        return $file;  # Return as-is, system files don't need vpath resolution
    }

    # Early exit if no vpath patterns are defined - no point in checking
    unless (keys %vpath) {
        $vpath_cache{$cache_key} = $file;
        return $file;  # No vpath to search, return original
    }

    # Check if file exists in current directory first
    my $file_path = $file =~ m{^/} ? $file : "$dir/$file";
    if (-e $file_path) {
        # File found in current directory (common case, no debug needed)
        $vpath_cache{$cache_key} = $file;
        return $file;
    }

    print STDERR "DEBUG vpath: '$file' not in current dir, checking vpath patterns\n" if $ENV{SMAK_DEBUG};

    # Debug: show available vpath patterns
    if ($ENV{SMAK_DEBUG} && keys %vpath) {
        print STDERR "DEBUG vpath: Available patterns:\n";
        for my $p (keys %vpath) {
            print STDERR "DEBUG vpath:   '$p' => [" . join(", ", @{$vpath{$p}}) . "]\n";
        }
    } elsif ($ENV{SMAK_DEBUG}) {
        print STDERR "DEBUG vpath: No vpath patterns defined!\n";
    }

    # Try vpath patterns
    for my $pattern (keys %vpath) {
        # Convert pattern to regex (% matches anything)
        my $pattern_re = $pattern;
        $pattern_re =~ s/%/.*?/g;

        if ($file =~ /^$pattern_re$/) {
            print STDERR "DEBUG vpath: '$file' matches pattern '$pattern'\n" if $ENV{SMAK_DEBUG};
            # File matches this vpath pattern, search directories
            for my $vpath_dir (@{$vpath{$pattern}}) {
                my $candidate = "$vpath_dir/$file";
                # Make path relative to working directory
                $candidate = $candidate =~ m{^/} ? $candidate : "$dir/$candidate";
                print STDERR "DEBUG vpath:   trying '$candidate'\n" if $ENV{SMAK_DEBUG};
                if (-e $candidate) {
                    # Return relative path from $dir
                    $candidate =~ s{^\Q$dir\E/}{};
                    print STDERR "DEBUG vpath: ✓ resolved '$file' → '$candidate' via vpath\n" if $ENV{SMAK_DEBUG};
                    $vpath_cache{$cache_key} = $candidate;
                    return $candidate;
                }
            }
        }
    }

    # Not found via vpath, return original (and cache the negative result)
    print STDERR "DEBUG vpath: '$file' not found via vpath, returning as-is\n" if $ENV{SMAK_DEBUG};
    $vpath_cache{$cache_key} = $file;
    return $file;
}

sub get_rules {
    return {
        fixed_rule => \%fixed_rule,
        fixed_deps => \%fixed_deps,
        pattern_rule => \%pattern_rule,
        pattern_deps => \%pattern_deps,
        pseudo_rule => \%pseudo_rule,
        pseudo_deps => \%pseudo_deps,
        variables => \%MV,
    };
}

sub parse_ninja {
    my ($ninja_file) = @_;

    $makefile = $ninja_file;
    undef $default_target;

    # Reset state
    %fixed_rule = ();
    %fixed_deps = ();
    %pattern_rule = ();
    %pattern_deps = ();
    %pseudo_rule = ();
    %pseudo_deps = ();
    %MV = ();
    %phony_targets = ();

    # Ninja-specific: track rules and their properties
    my %ninja_rules;  # rule_name => {command, description, deps, depfile, ...}
    my %ninja_vars;   # global ninja variables

    open(my $fh, '<', $ninja_file) or die "Cannot open $ninja_file: $!";

    my $current_section = '';  # 'rule', 'build', or ''
    my $current_rule_name = '';
    my $current_build_output = '';
    my %current_build_vars;

    while (my $line = <$fh>) {
        chomp $line;

        # Skip comments and empty lines
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

        # Global variable assignment
        if ($line =~ /^(\w+)\s*=\s*(.*)$/ && $current_section eq '') {
            my ($var, $value) = ($1, $2);
            $ninja_vars{$var} = $value;
            $MV{$var} = $value;
            next;
        }

        # Rule definition
        if ($line =~ /^rule\s+(\S+)/) {
            $current_section = 'rule';
            $current_rule_name = $1;
            $ninja_rules{$current_rule_name} = {};
            next;
        }

        # Rule properties (indented lines after 'rule')
        if ($current_section eq 'rule' && $line =~ /^\s+(\w+)\s*=\s*(.*)$/) {
            my ($prop, $value) = ($1, $2);
            $ninja_rules{$current_rule_name}{$prop} = $value;
            next;
        }

        # Build statement
        if ($line =~ /^build\s+(.+?)\s*:\s*(\S+)(?:\s+(.*))?$/) {
            # End previous build if any
            if ($current_build_output) {
                _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
            }

            $current_section = 'build';
            $current_build_output = $1;
            my $rule_name = $2;
            my $inputs = $3 || '';

            # Parse outputs (can be multiple with |)
            my @outputs = split /\s*\|\s*/, $current_build_output;
            my $output = $outputs[0];  # Use first output as main target

            # Parse inputs (can have implicit deps with |)
            my @input_parts = split /\s*\|\s*/, $inputs;
            my @deps = $input_parts[0] ? (split /\s+/, $input_parts[0]) : ();
            @deps = grep { $_ ne '' } @deps;

            %current_build_vars = (
                rule => $rule_name,
                inputs => \@deps,
                output => $output,
            );
            next;
        }

        # Build variables (indented lines after 'build')
        if ($current_section eq 'build' && $line =~ /^\s+(\w+)\s*=\s*(.*)$/) {
            my ($var, $value) = ($1, $2);
            $current_build_vars{$var} = $value;
            next;
        }

        # Non-indented line ends current section
        if ($line !~ /^\s/ && $current_section ne '') {
            if ($current_section eq 'build' && $current_build_output) {
                _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
                $current_build_output = '';
                %current_build_vars = ();
            }
            $current_section = '';
        }
    }

    # Save last build if any
    if ($current_build_output) {
        _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
    }

    close($fh);
}

sub _save_ninja_build {
    my ($ninja_rules, $build_output, $build_vars) = @_;

    my $output = $build_vars->{output};
    my $rule_name = $build_vars->{rule};
    my @inputs = @{$build_vars->{inputs} || []};

    return unless $output && $rule_name;

    # Get rule template
    my $rule = $ninja_rules->{$rule_name} || {};
    my $command = $rule->{command} || '';

    # Expand variables in command
    # Replace ninja variables like $in, $out, $ARGS, etc.
    my %var_map = (
        'in' => join(' ', @inputs),
        'out' => $output,
    );

    # Add build-specific variables
    for my $var (keys %$build_vars) {
        next if $var eq 'rule' || $var eq 'inputs' || $var eq 'output';
        $var_map{$var} = $build_vars->{$var};
    }

    # Expand variables in command
    # First pass: expand known variables
    for my $var (keys %var_map) {
        my $value = $var_map{$var};
        $command =~ s/\$$var\b/$value/g;
        $command =~ s/\$\{$var\}/$value/g;
    }

    # Second pass: expand any remaining $VAR to empty string (undefined variables)
    $command =~ s/\$\{?([A-Z_][A-Z0-9_]*)\}?//g;

    # Extract compiler commands and convert to variables
    # This makes it easier to change compilers in the generated Makefile
    if ($command =~ /^\s*(\S*\/)?(\S+?)\s+/) {
        my $compiler_path = $1 || '';
        my $compiler = $2;

        # Detect C++ compilers
        if ($compiler =~ /^(c\+\+|g\+\+|clang\+\+|icpc|CC)$/) {
            # Store the full compiler command if not already set
            unless (exists $MV{CXX} && $MV{CXX} ne '') {
                $MV{CXX} = $compiler_path . $compiler;
            }
            # Replace compiler in command with $(CXX)
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{CXX}/;
        }
        # Detect C compilers
        elsif ($compiler =~ /^(cc|gcc|clang|icc)$/) {
            # Store the full compiler command if not already set
            unless (exists $MV{CC} && $MV{CC} ne '') {
                $MV{CC} = $compiler_path . $compiler;
            }
            # Replace compiler in command with $(CC)
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{CC}/;
        }
        # Detect linker/archiver commands
        elsif ($compiler =~ /^(ar|ld|ranlib)$/) {
            my $var = uc($compiler);
            unless (exists $MV{$var} && $MV{$var} ne '') {
                $MV{$var} = $compiler_path . $compiler;
            }
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{$var}/;
        }
    }

    # Handle DEPFILE tracking
    my $depfile = $build_vars->{DEPFILE} || $build_vars->{depfile};
    if ($depfile) {
        # Expand depfile path
        for my $var (keys %var_map) {
            my $value = $var_map{$var};
            $depfile =~ s/\$$var\b/$value/g;
            $depfile =~ s/\$\{$var\}/$value/g;
        }

        # If depfile exists, parse it for additional dependencies
        if (-f $depfile) {
            my @dep_deps = _parse_depfile($depfile);
            push @inputs, @dep_deps;
        }
    }

    # Check if this is a phony target
    if ($rule_name =~ /^phony$/i) {
        $phony_targets{$output} = 1;
    }

    # Store in smak format
    my $key = "$makefile\t$output";
    $fixed_deps{$key} = \@inputs;
    $fixed_rule{$key} = $command;

    # Set default target (skip targets with variables or special targets)
    if (!defined $default_target) {
        # Skip targets with unexpanded variables
        if ($output =~ /\$/) {
            warn "DEBUG: add_rule skipping target with variable: '$output'\n" if $ENV{SMAK_DEBUG};
        }
        # Skip special targets
        elsif ($output =~ /^\./) {
            warn "DEBUG: add_rule skipping special target: '$output'\n" if $ENV{SMAK_DEBUG};
        }
        # Skip phony targets
        elsif (exists $phony_targets{$output}) {
            warn "DEBUG: add_rule skipping phony target: '$output'\n" if $ENV{SMAK_DEBUG};
        }
        else {
            $default_target = $output;
            warn "DEBUG: add_rule setting default target to: '$output'\n" if $ENV{SMAK_DEBUG};
        }
    }
}

sub _parse_depfile {
    my ($depfile) = @_;

    open(my $fh, '<', $depfile) or return ();

    my @deps;
    my $content = do { local $/; <$fh> };
    close($fh);

    # Dependency files are in Makefile format: target: dep1 dep2 dep3
    # Can span multiple lines with backslash continuation
    $content =~ s/\\\n/ /g;  # Join continuation lines

    if ($content =~ /^[^:]+:\s*(.*)$/m) {
        my $deps_str = $1;
        @deps = split /\s+/, $deps_str;
        @deps = grep { $_ ne '' && -f $_ } @deps;  # Filter to existing files
    }

    return @deps;
}

sub write_makefile {
    my ($output_file) = @_;
    $output_file ||= 'Makefile.generated';

    open(my $fh, '>', $output_file) or die "Cannot write $output_file: $!";

    # Write header
    print $fh "# Generated Makefile from $makefile\n";
    print $fh "# Generated by smak-ninja\n\n";

    # Write command-line variable overrides first (if any)
    my @cmd_var_names = sort keys %cmd_vars;
    if (@cmd_var_names) {
        print $fh "# Command-line variable overrides\n";
        for my $var (@cmd_var_names) {
            my $value = $cmd_vars{$var};
            my $original = $MV{$var} // '';
            if ($original ne '' && $original ne $value) {
                print $fh "$var = $value  # was: $original\n";
            } else {
                print $fh "$var = $value\n";
            }
        }
        print $fh "\n";
    }

    # Write compiler variables first (these are most commonly modified)
    print $fh "# Compiler settings (modify these to change build mode)\n";
    my @compiler_vars = qw(CC CXX AR LD RANLIB);
    my $found_compiler = 0;
    for my $var (@compiler_vars) {
        next if exists $cmd_vars{$var};  # Skip if overridden on command line
        if (exists $MV{$var} && $MV{$var} ne '') {
            print $fh "$var = $MV{$var}\n";
            $found_compiler = 1;
        }
    }
    print $fh "\n" if $found_compiler;

    # Write other variables
    print $fh "# Other variables\n";
    for my $var (sort keys %MV) {
        next if $var eq 'ninja_required_version';  # Skip ninja-specific vars
        next if grep { $_ eq $var } @compiler_vars;  # Skip compiler vars (already written)
        next if exists $cmd_vars{$var};  # Skip command-line overrides (already written)
        my $value = $MV{$var};
        print $fh "$var = $value\n";
    }
    print $fh "\n";

    # Collect all targets (skip PHONY)
    my %all_targets;
    for my $key (keys %fixed_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';  # Skip PHONY target
        $all_targets{$target} = $key;
    }
    for my $key (keys %pattern_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        $all_targets{$target} = $key;
    }
    for my $key (keys %pseudo_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        $all_targets{$target} = $key;
    }

    # Find or create 'all' target
    my $has_all = exists $all_targets{'all'};

    # Write default target
    print $fh "# Default target\n";
    if ($has_all) {
        print $fh ".DEFAULT_GOAL := all\n\n";
    } else {
        # Create 'all' target if it doesn't exist
        print $fh ".DEFAULT_GOAL := all\n\n";
        print $fh "# Default all target\n";
        print $fh "all:\n";
        print $fh "\t\@echo 'Build complete'\n\n";
    }

    # Write .PHONY declarations
    my @phony = sort keys %phony_targets;
    if (@phony) {
        print $fh "# Phony targets (always rebuild)\n";
        print $fh ".PHONY: " . join(' ', @phony) . "\n\n";
    }

    # Write rules
    print $fh "# Build rules\n";
    for my $target (sort keys %all_targets) {
        my $key = $all_targets{$target};

        # Get dependencies and rule
        my $deps_ref = $fixed_deps{$key} || $pattern_deps{$key} || $pseudo_deps{$key};
        my $rule = $fixed_rule{$key} || $pattern_rule{$key} || $pseudo_rule{$key};

        next unless $deps_ref;

        my @deps = @$deps_ref;

        # Convert $MV{VAR} back to $(VAR)
        my $deps_str = join(' ', @deps);
        $deps_str = format_output($deps_str);

        # Write target line
        print $fh "$target: $deps_str\n";

        # Write rule commands
        if ($rule && $rule =~ /\S/) {
            my $formatted_rule = format_output($rule);
            for my $cmd (split /\n/, $formatted_rule) {
                next unless $cmd =~ /\S/;
                print $fh "\t$cmd\n";
            }
        }

        print $fh "\n";
    }

    close($fh);
    print "Makefile written to: $output_file\n";
}

sub looks_phony {
    my ($target) = @_;
    # Skip special/meta targets
    return 1 if $target eq 'PHONY';
    return 1 if $target eq 'all';
    return 1 if $target =~ /^\.DEFAULT_GOAL/;
    # Skip targets that look like variables or directives
    return 1 if $target =~ /^\$/;
    # Skip targets with spaces (multi-file targets from meson)
    return 1 if $target =~ /\s/;
    # Skip paths that point outside the build directory
    return 1 if $target =~ /^\.\./;
    # Skip the ninja file itself and meson internals
    return 1 if $target =~ /\.ninja$/;
    if ($target =~ /^meson-/) {
	return 1 if (! $target =~ /.dat$/);
    }
    
    return 0;
}

sub get_all_ninja_outputs {
    # Collect all output files from parsed ninja file
    my @outputs;
    my %seen;

    # Collect from fixed_deps (most common for ninja builds)
    for my $key (keys %fixed_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if looks_phony($target);
        # Add if not seen before
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pattern_deps (rare for ninja, but check anyway)
    for my $key (keys %pattern_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if looks_phony($target);
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pseudo_deps
    for my $key (keys %pseudo_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if looks_phony($target);
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    return @outputs;
}

# Helper function to parse make/smak command line
sub parse_make_command {
    my ($cmd) = @_;

    # Check for shell operators that indicate a compound command
    # BUT skip operators inside quotes or backticks
    my $check_cmd = $cmd;
    # Remove single-quoted strings
    $check_cmd =~ s/'[^']*'//g;
    # Remove double-quoted strings (including those with backticks inside)
    $check_cmd =~ s/"[^"]*"//g;
    # Remove backtick strings
    $check_cmd =~ s/`[^`]*`//g;

    if ($check_cmd =~ /\s+(&&|\|\||;|\|)\s+/) {
        warn "DEBUG: Compound command detected with operator '$1', cannot parse as simple make\n" if $ENV{SMAK_DEBUG};
        # Return empty to signal this should be executed externally or handled specially
        return ('', '', ());
    }

    my $makefile = '';
    my $directory = '';
    my @targets;
    my %var_assignments;

    # Tokenize command line respecting quotes
    my @parts;
    my $pos = 0;
    my $len = length($cmd);
    while ($pos < $len) {
        # Skip whitespace
        if (substr($cmd, $pos, 1) =~ /\s/) {
            $pos++;
            next;
        }

        my $start = $pos;
        my $in_quote = '';

        # Parse a token
        while ($pos < $len) {
            my $char = substr($cmd, $pos, 1);

            if ($in_quote) {
                if ($char eq $in_quote) {
                    $in_quote = '';
                }
                $pos++;
            } elsif ($char eq '"' || $char eq "'" || $char eq '`') {
                $in_quote = $char;
                $pos++;
            } elsif ($char =~ /\s/) {
                last;
            } else {
                $pos++;
            }
        }

        push @parts, substr($cmd, $start, $pos - $start) if $pos > $start;
    }

    # Skip the command itself (make/smak/path)
    shift @parts;

    # Parse arguments
    for (my $i = 0; $i < @parts; $i++) {
        if ($parts[$i] eq '-f' && $i + 1 < @parts) {
            $makefile = $parts[$i + 1];
            $i++;  # Skip next arg
        } elsif ($parts[$i] eq '-C' && $i + 1 < @parts) {
            $directory = $parts[$i + 1];
            $i++;  # Skip next arg
        } elsif ($parts[$i] =~ /^-/) {
            # Skip other options
            # Handle options that take arguments
            if ($parts[$i] =~ /^-(I|j|l|o|W)$/ && $i + 1 < @parts) {
                $i++;  # Skip option argument
            }
        } elsif ($parts[$i] =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) {
            # Variable assignment (VAR=value)
            # Store for the caller to set in %MV
            my ($var, $val) = ($1, $2);
            # Remove surrounding quotes from value if present
            if ($val =~ /^"(.*)"$/ || $val =~ /^'(.*)'$/) {
                $val = $1;
            }
            $var_assignments{$var} = $val;
            next;
        } else {
            # It's a target
            push @targets, $parts[$i];
        }
    }

    return ($makefile, $directory, \%var_assignments, @targets);
}

# Helper function to get first target from a makefile
sub get_first_target {
    my ($mf) = @_;

    # Look for first non-special target in this makefile
    for my $key (keys %fixed_deps) {
        if ($key =~ /^\Q$mf\E\t(.+)$/) {
            my $tgt = $1;
            # Skip special targets that start with .
            next if $tgt =~ /^\./;
            return $tgt;
        }
    }

    # Try pseudo targets
    for my $key (keys %pseudo_deps) {
        if ($key =~ /^\Q$mf\E\t(.+)$/) {
            my $tgt = $1;
            next if $tgt =~ /^\./;
            return $tgt;
        }
    }

    return undef;
}

# Check if a target needs rebuilding based on timestamp comparison
# Returns 1 if target needs rebuilding, 0 if up-to-date
sub needs_rebuild {
    my ($target, $visited) = @_;
    $visited ||= {};

    # Prevent infinite recursion on circular dependencies
    return 0 if $visited->{$target};
    $visited->{$target} = 1;

    # If target doesn't exist, it needs to be built
    return 1 unless -e $target;

    # Check if target or any dependency is manually marked dirty
    if (exists $Smak::dirty_files{$target}) {
        warn "DEBUG: Target '$target' is marked dirty, needs rebuild\n" if $ENV{SMAK_DEBUG};
        return 1;
    }

    # Get target's modification time
    my $target_mtime = (stat($target))[9];
    return 1 unless defined $target_mtime;

    # Find target's dependencies
    my $key = "$makefile\t$target";
    my @deps;

    if (exists $fixed_deps{$key}) {
        @deps = @{$fixed_deps{$key} || []};
    } elsif (exists $pattern_deps{$key}) {
        @deps = @{$pattern_deps{$key} || []};
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
    }

    # Expand variables in dependencies
    @deps = map {
        my $dep = $_;
        # Expand $MV{VAR} references
        while ($dep =~ /\$MV\{([^}]+)\}/) {
            my $var = $1;
            my $val = $MV{$var} // '';
            $dep =~ s/\$MV\{\Q$var\E\}/$val/;
        }
        # If expansion resulted in multiple space-separated values, split them
        if ($dep =~ /\s/) {
            split /\s+/, $dep;
        } else {
            $dep;
        }
    } @deps;
    # Flatten and filter empty strings
    @deps = grep { $_ ne '' } @deps;

    # Apply vpath resolution to dependencies (same as build_target does)
    use Cwd 'getcwd';
    my $cwd = getcwd();
    @deps = map { resolve_vpath($_, $cwd) } @deps;

    # Check if any dependency is newer than target or marked dirty
    for my $dep (@deps) {
        # Skip .PHONY and other special targets
        next if $dep =~ /^\.PHONY$/;

        # If dependency is a phony target, always rebuild (like "force")
        # Check if $dep appears in .PHONY dependencies
        my $phony_key = "$makefile\t.PHONY";
        if (exists $pseudo_deps{$phony_key}) {
            my @phony_targets_list = @{$pseudo_deps{$phony_key} || []};
            if (grep { $_ eq $dep } @phony_targets_list) {
                warn "DEBUG: Dependency '$dep' is phony, forcing rebuild of '$target'\n" if $ENV{SMAK_DEBUG};
                return 1;
            }
        }

        # Skip ignored files
        if (exists $Smak::ignored_files{$dep}) {
            warn "DEBUG: Dependency '$dep' is ignored, skipping timestamp check\n" if $ENV{SMAK_DEBUG};
            next;
        }

        # Check if dependency is marked dirty
        if (exists $Smak::dirty_files{$dep}) {
            warn "DEBUG: Dependency '$dep' of '$target' is marked dirty, needs rebuild\n" if $ENV{SMAK_DEBUG};
            return 1;
        }

        # If dependency doesn't exist, target needs rebuild
        return 1 unless -e $dep;

        # Recursively check if dependency itself needs rebuilding
        # This handles transitive dirty dependencies (e.g., A depends on B, B depends on dirty C)
        if (needs_rebuild($dep, $visited)) {
            warn "DEBUG: Dependency '$dep' of '$target' needs rebuild (recursive check), so '$target' needs rebuild too\n" if $ENV{SMAK_DEBUG};
            return 1;
        }

        # Compare modification times
        my $dep_mtime = (stat($dep))[9];
        return 1 if $dep_mtime > $target_mtime;
    }

    # Target is up-to-date
    return 0;
}

sub can_build_from_suffix_rule {
    my ($target, $makefile, $visited) = @_;
    $visited ||= {};

    # Avoid infinite recursion
    return 0 if $visited->{$target};
    $visited->{$target} = 1;

    # Extract base and target suffix
    if ($target =~ /^(.+)(\.[^.\/]+)$/) {
        my $base = $1;
        my $target_suffix = $2;

        # Try each source suffix to see if we can build this target
        for my $source_suffix (@suffixes) {
            next if $source_suffix eq $target_suffix;

            my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
            if (exists $suffix_rule{$suffix_key}) {
                my $source = "$base$source_suffix";

                # Check if source exists via VPATH
                use Cwd 'getcwd';
                my $cwd = getcwd();
                my $resolved = resolve_vpath($source, $cwd);
                use File::Basename;
                my $makefile_dir = dirname($makefile);
                my $source_path = "$makefile_dir/$resolved";

                if (-f $source_path) {
                    # Source file exists, we can build target
                    return 1;
                }

                # Recursively check if source can be built via suffix rules
                if (can_build_from_suffix_rule($source, $makefile, $visited)) {
                    # Source can be built, so target can be built
                    return 1;
                }
            }
        }
    }

    return 0;
}

sub preprocess_automake_suffix_rule {
    my ($rule, $target) = @_;

    warn "DEBUG[preprocess]: Input rule:\n$rule\n" if $ENV{SMAK_DEBUG};

    # Calculate depbase: target (e.g. src/sem.o) -> src/.deps/sem
    # This mimics: depbase=`echo $@ | sed 's|[^/]*$|$(DEPDIR)/&|;s|\.o$||'`
    # where DEPDIR=.deps
    my $depbase = $target;
    $depbase =~ s|([^/]*)$|.deps/$1|;  # Add .deps/ before filename
    $depbase =~ s|\.o$||;               # Remove .o extension

    warn "DEBUG[preprocess]: Calculated depbase='$depbase'\n" if $ENV{SMAK_DEBUG};

    # Replace all $depbase references with the calculated value (both $ and $$ forms)
    $rule =~ s/\$\$depbase/$depbase/g;  # Replace $$depbase
    $rule =~ s/\$depbase/$depbase/g;     # Replace $depbase

    # Remove the depbase assignment line (we've calculated it in Perl)
    $rule =~ s/depbase=`[^`]+`;\s*//g;

    # Split compound commands at && to handle separately
    # This allows us to exec gcc directly and handle mv as built-in
    # Mark mv commands for built-in handling
    $rule =~ s/\bmv\s+-f\s+/BUILTIN_MV -f /g;

    # Split && into separate lines so each command executes independently
    $rule =~ s/\s*&&\s*/\n/g;

    warn "DEBUG[preprocess]: Output rule:\n$rule\n" if $ENV{SMAK_DEBUG};

    return $rule;
}

sub builtin_mv {
    my ($source, $dest) = @_;

    warn "DEBUG[builtin_mv]: Moving '$source' to '$dest'\n" if $ENV{SMAK_DEBUG};

    # In dry-run mode, skip the actual move but return success
    if ($dry_run_mode) {
        warn "DEBUG[builtin_mv]: Dry-run mode - skipping actual move\n" if $ENV{SMAK_DEBUG};
        return 1;
    }

    # Perform the move operation
    use File::Copy;
    unless (move($source, $dest)) {
        warn "smak: mv: cannot move '$source' to '$dest': $!\n";
        return 0;
    }

    # If this is a .Tpo -> .Po move, we could parse the .Po file here
    # to discover additional dependencies (future enhancement)
    if ($dest =~ /\.Po$/) {
        warn "DEBUG[builtin_mv]: Dependency file created: $dest\n" if $ENV{SMAK_DEBUG};
        # TODO: Parse .Po file and update dependency tracking
    }

    return 1;
}

sub builtin_rm {
    my (@files_and_opts) = @_;

    warn "DEBUG[builtin_rm]: rm @files_and_opts\n" if $ENV{SMAK_DEBUG};

    # In dry-run mode, skip the actual removal but return success
    if ($dry_run_mode) {
        warn "DEBUG[builtin_rm]: Dry-run mode - skipping actual removal\n" if $ENV{SMAK_DEBUG};
        return 1;
    }

    # Parse options
    my $force = 0;
    my $recursive = 0;
    my @files;

    for my $arg (@files_and_opts) {
        if ($arg eq '-f') {
            $force = 1;
        } elsif ($arg eq '-r' || $arg eq '-R') {
            $recursive = 1;
        } elsif ($arg eq '-rf' || $arg eq '-fr' || $arg eq '-Rf' || $arg eq '-fR') {
            $force = 1;
            $recursive = 1;
        } elsif ($arg !~ /^-/) {
            # Expand glob patterns
            my @expanded = glob($arg);
            if (@expanded) {
                push @files, @expanded;
            } elsif (!$force) {
                # If glob didn't match and not forced, treat as literal filename
                push @files, $arg;
            }
        }
    }

    # Remove files
    for my $file (@files) {
        if (-e $file) {
            if (-d $file) {
                if ($recursive) {
                    use File::Path 'remove_tree';
                    remove_tree($file, {error => \my $err});
                    if (@$err && !$force) {
                        warn "smak: rm: cannot remove '$file': $!\n";
                        return 0 unless $force;
                    }
                } elsif (!$force) {
                    warn "smak: rm: cannot remove '$file': Is a directory\n";
                    return 0;
                }
            } else {
                unless (unlink($file)) {
                    if (!$force) {
                        warn "smak: rm: cannot remove '$file': $!\n";
                        return 0;
                    }
                }
            }
        } elsif (!$force && -e $file) {
            warn "smak: rm: cannot remove '$file': No such file or directory\n";
            return 0;
        }
    }

    return 1;
}

sub build_target {
    my ($target, $visited, $depth) = @_;
    $visited ||= {};
    $depth ||= 0;

    # FIRST: Skip source control files entirely (prevents infinite recursion)
    # Check for ,v suffix (RCS) or other source control patterns
    for my $ext (keys %source_control_extensions) {
        if ($target =~ /\Q$ext\E/) {
            warn "DEBUG: Skipping source control file '$target' (contains $ext)\n" if $ENV{SMAK_DEBUG};
            return;
        }
    }

    # Check for source control directory recursion (RCS/RCS/, SCCS/SCCS/, s.s., etc.)
    if (has_source_control_recursion($target)) {
        warn "DEBUG: Skipping recursive source control path '$target'\n" if $ENV{SMAK_DEBUG};
        return;
    }

    # Skip inactive implicit rule patterns (e.g., RCS/SCCS if not present in project)
    # This prevents infinite loops and wasted processing for patterns that don't exist
    if (is_inactive_pattern($target)) {
        return;
    }

    # Prevent infinite recursion
    if ($depth > 100) {
        warn "Warning: Maximum recursion depth (100) reached building '$target' in $makefile\n";
        warn "         This may indicate a circular dependency or overly deep dependency chain.\n";
        return;
    }

    # Track visited targets per makefile AND directory to handle same target names in different directories
    # Using cwd in the key ensures that "Makefile\tall" in the root is different from "Makefile\tall" in subdirs
    use Cwd 'getcwd';
    my $cwd_for_visit = getcwd();
    my $visit_key = "$cwd_for_visit\t$makefile\t$target";
    return if $visited->{$visit_key};
    $visited->{$visit_key} = 1;

    # Early exit for files in ignored directories (e.g., /usr/include, /usr/local/include)
    # Check entire directories instead of individual files for efficiency
    if (my $ignored_dir = is_ignored_dir($target)) {
        warn "DEBUG[" . __LINE__ . "]:   File '$target' is in ignored directory '$ignored_dir'\n" if ($ENV{SMAK_DEBUG} || 0) >= 2;
        # Check if the directory itself has been modified
        if (exists $ignore_dir_mtimes{$ignored_dir}) {
            my $current_mtime = (stat($ignored_dir))[9];
            if (defined $current_mtime && $current_mtime == $ignore_dir_mtimes{$ignored_dir}) {
                # Directory unchanged, skip this file entirely
                warn "DEBUG[" . __LINE__ . "]:   Skipping - directory unchanged (mtime=$current_mtime)\n" if ($ENV{SMAK_DEBUG} || 0) >= 2;
                return;
            } else {
                # Directory changed - update cache and continue processing
                warn "WARNING: Ignored directory '$ignored_dir' has changed (rebuilding dependencies)\n";
                $ignore_dir_mtimes{$ignored_dir} = $current_mtime if defined $current_mtime;
            }
        } else {
            # Directory not in cache - skip file anyway (system directory)
            warn "DEBUG[" . __LINE__ . "]:   Skipping - directory not cached (assuming system directory)\n" if ($ENV{SMAK_DEBUG} || 0) >= 2;
            return;
        }
    }

    # Early exit for system headers and external dependencies
    # If a file exists on disk, is an absolute path (system header), and has no explicit rule,
    # skip all the expensive processing (pattern matching, variable expansion, etc.)
    my $key = "$makefile\t$target";
    if ($target =~ m{^/} && -e $target &&
        !exists $fixed_deps{$key} && !exists $pattern_deps{$key} && !exists $pseudo_deps{$key}) {
        warn "DEBUG[" . __LINE__ . "]: Skipping system dependency '$target' (exists, no rule)\n" if $ENV{SMAK_DEBUG};
        return;
    }

    # Debug: show what we're building
    warn "DEBUG[" . __LINE__ . "]: Building target '$target' (depth=$depth, makefile=$makefile)\n" if $ENV{SMAK_DEBUG};

    my @deps;
    my $rule = '';
    my $stem = '';  # Track stem for $* automatic variable
    my $suffix_source = '';  # Track source file for suffix rules ($< in .c.o:)

    # Helper function to find a rule key by trying variable expansion
    # Needed because rules are stored with unexpanded variables like $(EXEEXT)
    my $find_rule_key = sub {
        my ($hash_ref, $target_key) = @_;

        # Try exact match first
        return $target_key if exists $hash_ref->{$target_key};

        # Try expanding variables in stored keys
        for my $stored_key (keys %$hash_ref) {
            # Only check keys from the same makefile
            next unless $stored_key =~ /^\Q$makefile\E\t(.+)$/;
            my $stored_target = $1;

            # Expand variables in the stored target name
            # First convert $(VAR) to $MV{VAR}, then expand $MV{VAR} references
            my $expanded = $stored_target;
            $expanded = transform_make_vars($expanded);
            # Expand $MV{VAR} references recursively
            while ($expanded =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $expanded =~ s/\$MV\{\Q$var\E\}/$val/;
            }

            # If expanded form matches the target, return the original stored key
            if ($expanded eq $target) {
                warn "DEBUG[" . __LINE__ . "]: Matched rule key '$stored_key' (expands to '$expanded') for target '$target'\n" if $ENV{SMAK_DEBUG};
                return $stored_key;
            }
        }

        return undef;
    };

    # Find target in fixed, pattern, or pseudo rules
    my $matched_key = $find_rule_key->(\%fixed_deps, $key);
    my @order_only_prereqs;  # Order-only prerequisites (checked for existence but not timestamps)
    if ($matched_key) {
        @deps = @{$fixed_deps{$matched_key} || []};
        @order_only_prereqs = @{$fixed_order_only{$matched_key} || []};
        $rule = $fixed_rule{$matched_key} || '';
        warn "DEBUG[" . __LINE__ . "]: Matched fixed rule key='$matched_key' for target='$target'\n" if $ENV{SMAK_DEBUG};

        # If fixed rule has no command, try to find suffix rule or pattern rule
        # Try suffix rules FIRST so that Makefile suffix rules take precedence over built-in pattern rules
        if (!$rule || $rule !~ /\S/) {
            # Try suffix rules first
            # This is needed when .deps/*.Po files define dependencies but no rule
            # and ensures Makefile suffix rules override built-in pattern rules
            warn "DEBUG[" . __LINE__ . "]: No rule found in fixed_rule, trying suffix rules for '$target'\n" if $ENV{SMAK_DEBUG};
            if ($target =~ /^(.+)(\.[^.\/]+)$/) {
                my $base = $1;
                my $target_suffix = $2;
                warn "DEBUG[" . __LINE__ . "]:   base='$base', target_suffix='$target_suffix'\n" if $ENV{SMAK_DEBUG};
                warn "DEBUG[" . __LINE__ . "]:   suffixes: @suffixes\n" if $ENV{SMAK_DEBUG};

                for my $source_suffix (@suffixes) {
                    next if $source_suffix eq $target_suffix;

                    my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                    warn "DEBUG[" . __LINE__ . "]:   trying suffix_key='$suffix_key'\n" if $ENV{SMAK_DEBUG};
                    if (exists $suffix_rule{$suffix_key}) {
                        warn "DEBUG[" . __LINE__ . "]:     suffix rule exists!\n" if $ENV{SMAK_DEBUG};
                        my $source = "$base$source_suffix";
                        use Cwd 'getcwd';
                        my $cwd = getcwd();
                        my $resolved_source = resolve_vpath($source, $cwd);
                        warn "DEBUG[" . __LINE__ . "]:     source='$source', resolved='$resolved_source'\n" if $ENV{SMAK_DEBUG};

                        # Check if source file exists
                        # resolve_vpath already returns a path relative to cwd, so check it directly
                        warn "DEBUG[" . __LINE__ . "]:     checking existence of '$resolved_source'\n" if $ENV{SMAK_DEBUG};

                        # Source file can be used if it exists OR can be built via another suffix rule
                        my $source_exists = -f $resolved_source;
                        my $source_can_build = !$source_exists && can_build_from_suffix_rule($source, $makefile);

                        if ($source_exists || $source_can_build) {
                            $stem = $base;
                            $suffix_source = $source;  # Save source for $< expansion
                            warn "DEBUG[" . __LINE__ . "]:   Set suffix_source='$suffix_source' for suffix rule\n" if $ENV{SMAK_DEBUG};
                            # Keep existing deps from .deps/*.Po, add source if not present
                            push @deps, $source unless grep { $_ eq $source } @deps;
                            $rule = $suffix_rule{$suffix_key};
                            my $suffix_deps_ref = $suffix_deps{$suffix_key};
                            if ($suffix_deps_ref && @$suffix_deps_ref) {
                                my @suffix_deps_expanded = map {
                                    my $d = $_;
                                    $d =~ s/%/$stem/g;
                                    $d;
                                } @$suffix_deps_ref;
                                push @deps, @suffix_deps_expanded;
                            }
                            if ($source_can_build) {
                                warn "DEBUG: Using suffix rule $source_suffix$target_suffix for $target (source can be built from suffix rule)\n" if $ENV{SMAK_DEBUG};
                            } else {
                                warn "DEBUG: Using suffix rule $source_suffix$target_suffix for $target (with fixed deps)\n" if $ENV{SMAK_DEBUG};
                            }
                            last;
                        }
                    }
                }
            }

            # If still no rule found, try pattern rules
            # This ensures built-in pattern rules are only used as a fallback
            if (!$rule || $rule !~ /\S/) {
                PATTERN_SEARCH: for my $pkey (keys %pattern_rule) {
                    if ($pkey =~ /^[^\t]+\t(.+)$/) {
                        my $pattern = $1;
                        my $pattern_re = $pattern;
                        $pattern_re =~ s/%/(.+)/g;
                        if ($target =~ /^$pattern_re$/) {
                            $stem = $1;  # Save stem for $* expansion

                            # Pattern rules can now have multiple variants
                            # Try each variant and use the first one whose prerequisites exist
                            my $rules_ref = $pattern_rule{$pkey};
                            my $deps_ref = $pattern_deps{$pkey};

                            warn "DEBUG: Trying pattern $pkey, rules_ref type=" . ref($rules_ref) . "\n" if $ENV{SMAK_DEBUG};

                            # Handle both old single-rule format and new array format
                            my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
                            my @deps_list = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

                            warn "DEBUG: Have " . scalar(@rules) . " rule variants to try\n" if $ENV{SMAK_DEBUG};

                            # Try to find a variant whose source file exists
                            # If none exist, fall back to first variant (like GNU make)
                            my $best_variant = 0;  # Default to first variant

                            for (my $i = 0; $i < @rules; $i++) {
                                my @variant_deps = @{$deps_list[$i] || []};

                                # Expand % in dependencies with the stem
                                my @expanded_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;

                                # Resolve dependencies through vpath
                                use Cwd 'getcwd';
                                my $cwd = getcwd();
                                @expanded_deps = map { resolve_vpath($_, $cwd) } @expanded_deps;

                                warn "DEBUG: Variant $i deps: @expanded_deps\n" if $ENV{SMAK_DEBUG};

                                # Check if all prerequisites exist
                                my $all_prereqs_ok = 1;
                                for my $prereq (@expanded_deps) {
                                    my $prereq_path = $prereq =~ m{^/} ? $prereq : "$cwd/$prereq";
                                    warn "DEBUG:   Checking prereq $prereq_path: " . (-e $prereq_path ? "exists" : "missing") . "\n" if $ENV{SMAK_DEBUG};
                                    unless (-e $prereq_path) {
                                        $all_prereqs_ok = 0;
                                        last;
                                    }
                                }

                                if ($all_prereqs_ok) {
                                    # Found a variant whose prerequisites all exist - use it
                                    $best_variant = $i;
                                    warn "DEBUG: Found existing prerequisites for variant $i\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }

                            # Use the best variant (either one with existing prereqs, or the first one)
                            my @variant_deps = @{$deps_list[$best_variant] || []};
                            my @expanded_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;
                            use Cwd 'getcwd';
                            my $cwd = getcwd();
                            @expanded_deps = map { resolve_vpath($_, $cwd) } @expanded_deps;

                            $rule = $rules[$best_variant];
                            push @deps, @expanded_deps;
                            warn "DEBUG: Using pattern rule variant $best_variant for $target (deps: @expanded_deps)\n" if $ENV{SMAK_DEBUG};
                            last PATTERN_SEARCH;
                        }
                    }
                }
            }
        }

        # For explicit rules, compute $* from target name if not already set by pattern/suffix rule
        if (!$stem && $target =~ /^(.+)\.([^.\/]+)$/) {
            $stem = $1;  # Target name without suffix (e.g., "main" from "main.o")
        }
    } elsif (exists $pattern_deps{$key}) {
        # Exact pattern match - check all variants and use the one whose source exists
        my $rules_ref = $pattern_rule{$key};
        my $deps_ref = $pattern_deps{$key};

        # Handle both old single-rule format and new array format
        my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
        my @deps_list = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

        # Try to find a variant whose source files exist
        my $best_variant = 0;  # Default to first variant

        for (my $i = 0; $i < @rules; $i++) {
            my @variant_deps = @{$deps_list[$i] || []};

            # Check if all prerequisites exist
            my $all_exist = 1;
            for my $dep (@variant_deps) {
                # Note: dependencies might have %, need to expand if this is a pattern
                my $dep_to_check = $dep;
                if ($dep =~ /%/ && $target =~ /^(.+)\.([^.]+)$/) {
                    # Extract stem from target and expand dependency
                    my $stem = $1;
                    $dep_to_check =~ s/%/$stem/g;
                }

                use Cwd 'getcwd';
                my $cwd = getcwd();
                my $dep_path = $dep_to_check =~ m{^/} ? $dep_to_check : "$cwd/$dep_to_check";

                unless (-e $dep_path) {
                    $all_exist = 0;
                    last;
                }
            }

            if ($all_exist && @variant_deps > 0) {
                $best_variant = $i;
                warn "DEBUG: Found existing source for variant $i of $target\n" if $ENV{SMAK_DEBUG};
                last;
            }
        }

        # Use best variant
        @deps = @{$deps_list[$best_variant] || []};
        $rule = $rules[$best_variant] || '';
        warn "DEBUG: Using variant $best_variant for exact pattern match $target\n" if $ENV{SMAK_DEBUG};
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try suffix rules FIRST (before pattern rules)
        # This ensures Makefile suffix rules take precedence over built-in pattern rules
        if ($target =~ /^(.+)(\.[^.\/]+)$/) {
            my $base = $1;
            my $target_suffix = $2;

            # Try each possible source suffix in order
            for my $source_suffix (@suffixes) {
                # Skip if this is the target suffix itself
                next if $source_suffix eq $target_suffix;

                # Check if a suffix rule exists for this source->target combination
                my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                if (exists $suffix_rule{$suffix_key}) {
                    # Check if source file exists
                    my $source = "$base$source_suffix";
                    # Resolve source through vpath
                    use Cwd 'getcwd';
                    my $cwd = getcwd();
                    my $resolved_source = resolve_vpath($source, $cwd);

                    if (-f $resolved_source) {
                        # Found matching suffix rule and source file
                        $stem = $base;
                        @deps = ($source);  # Store unresolved path, will be resolved later
                        $rule = $suffix_rule{$suffix_key};
                        my $suffix_deps_ref = $suffix_deps{$suffix_key};
                        if ($suffix_deps_ref && @$suffix_deps_ref) {
                            # Expand % in suffix rule dependencies (rare but possible)
                            my @suffix_deps_expanded = map {
                                my $d = $_;
                                $d =~ s/%/$stem/g;
                                $d;
                            } @$suffix_deps_ref;
                            push @deps, @suffix_deps_expanded;
                        }
                        warn "DEBUG: Using suffix rule $source_suffix$target_suffix for $target from $source\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }

        # If still no rule found, try to find pattern rule match
        if (!$rule || $rule !~ /\S/) {
            PATTERN_MATCH_FALLBACK: for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    $stem = $1;  # Save stem for $* expansion

                    # Pattern rules can have multiple variants
                    my $rules_ref = $pattern_rule{$pkey};
                    my $deps_ref = $pattern_deps{$pkey};

                    # Handle both old single-rule format and new array format
                    my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
                    my @deps_list = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

                    # Try to find a variant whose source file exists
                    # If none exist, fall back to first variant (like GNU make)
                    my $best_variant = 0;  # Default to first variant

                    for (my $i = 0; $i < @rules; $i++) {
                        my @variant_deps = @{$deps_list[$i] || []};

                        # Expand % in dependencies with the stem
                        my @expanded_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;

                        # Resolve dependencies through vpath
                        use Cwd 'getcwd';
                        my $cwd = getcwd();
                        @expanded_deps = map { resolve_vpath($_, $cwd) } @expanded_deps;

                        # Check if all prerequisites exist
                        my $all_prereqs_ok = 1;
                        for my $prereq (@expanded_deps) {
                            my $prereq_path = $prereq =~ m{^/} ? $prereq : "$cwd/$prereq";
                            unless (-e $prereq_path) {
                                $all_prereqs_ok = 0;
                                last;
                            }
                        }

                        if ($all_prereqs_ok) {
                            # Found a variant whose prerequisites all exist - use it
                            $best_variant = $i;
                            last;
                        }
                    }

                    # Use the best variant (either one with existing prereqs, or the first one)
                    my @variant_deps = @{$deps_list[$best_variant] || []};
                    @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;
                    $rule = $rules[$best_variant] || '';

                    # Resolve dependencies through vpath
                    use Cwd 'getcwd';
                    my $cwd = getcwd();
                    @deps = map { resolve_vpath($_, $cwd) } @deps;
                    last PATTERN_MATCH_FALLBACK;
                }
            }
        }
        }

        # If still no rule found, try built-in implicit rules (like Make's built-in rules)
        if (!$rule || $rule !~ /\S/) {
            # Check for object file (.o) targets
            if ($target =~ /^(.+)\.o$/) {
                my $base = $1;
                # Try different source file extensions in order (C first, then C++)
                my @source_exts = ('c', 'cc', 'cpp', 'C', 'cxx', 'c++');
                for my $ext (@source_exts) {
                    my $source = "$base.$ext";
                    # Check if source file exists
                    if (-f $source) {
                        $stem = $base;
                        @deps = ($source);
                        # Use appropriate compilation rule based on extension
                        if ($ext eq 'c') {
                            $rule = "\t\$(COMPILE.c) \$(OUTPUT_OPTION) \$<\n";
                        } else {
                            $rule = "\t\$(COMPILE.cc) \$(OUTPUT_OPTION) \$<\n";
                        }
                        warn "DEBUG: Using built-in implicit rule for $target from $source\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }
    }

    # Expand variables in dependencies (which are in $MV{VAR} format)
    # Note: Variables like $O can expand to multiple space-separated values
    @deps = map {
        my $dep = $_;
        # First convert $MV{VAR} back to $(VAR) format
        $dep = format_output($dep);
        # Then do full variable expansion (handles $(shell ...) and other functions)
        $dep = expand_vars($dep);
        # If expansion resulted in multiple space-separated values, split them
        if ($dep =~ /\s/) {
            split /\s+/, $dep;
        } else {
            $dep;
        }
    } @deps;
    # Flatten and filter empty strings
    @deps = grep { $_ ne '' } @deps;

    # Process order-only prerequisites the same way as normal dependencies
    @order_only_prereqs = map {
        my $dep = $_;
        # First convert $MV{VAR} back to $(VAR) format
        $dep = format_output($dep);
        # Then do full variable expansion (handles $(shell ...) and other functions)
        $dep = expand_vars($dep);
        # If expansion resulted in multiple space-separated values, split them
        if ($dep =~ /\s/) {
            split /\s+/, $dep;
        } else {
            $dep;
        }
    } @order_only_prereqs;
    @order_only_prereqs = grep { $_ ne '' } @order_only_prereqs;

    # Apply vpath resolution to all dependencies
    use Cwd 'getcwd';
    my $cwd = getcwd();
    @deps = map { resolve_vpath($_, $cwd) } @deps;
    @order_only_prereqs = map { resolve_vpath($_, $cwd) } @order_only_prereqs;

    # Filter out dependencies in ignored directories
    # Keep them separate for sanity checks and reporting
    my @ignored_deps;
    my @active_deps;
    for my $dep (@deps) {
        if (is_ignored_dir($dep)) {
            push @ignored_deps, $dep;
        } else {
            push @active_deps, $dep;
        }
    }
    @deps = @active_deps;

    # Debug: show dependencies and rule status
    if ($ENV{SMAK_DEBUG}) {
        if (@deps) {
            warn "DEBUG[" . __LINE__ . "]:   Dependencies: " . join(', ', @deps) . "\n";
        }
        if (@ignored_deps && ($ENV{SMAK_DEBUG} || 0) >= 2) {
            warn "DEBUG[" . __LINE__ . "]:   Ignored dependencies (" . scalar(@ignored_deps) . "): " . join(', ', @ignored_deps[0..9]) . (@ignored_deps > 10 ? "... (" . (@ignored_deps - 10) . " more)" : "") . "\n";
        }
        if ($rule && $rule =~ /\S/) {
            warn "DEBUG[" . __LINE__ . "]:   Has rule: yes\n";
            my $rule_preview = substr($rule, 0, 100);
            $rule_preview =~ s/\n/\\n/g;
            warn "DEBUG[" . __LINE__ . "]:   Rule preview: '$rule_preview" . (length($rule) > 100 ? "...' (truncated)" : "'") . "\n";
        } else {
            warn "DEBUG[" . __LINE__ . "]:   Has rule: no\n";
        }
    }

    # Check if target is .PHONY
    # A target is phony if it appears as a dependency of .PHONY
    # Note: .PHONY is classified as a pseudo target (starts with .)
    my $is_phony = 0;
    my $phony_key = "$makefile\t.PHONY";
    if (exists $pseudo_deps{$phony_key}) {
        my @phony_targets = @{$pseudo_deps{$phony_key} || []};
        warn "DEBUG[" . __LINE__ . "]:   Found .PHONY with deps: " . join(', ', @phony_targets) . "\n" if $ENV{SMAK_DEBUG};
        # Expand variables in .PHONY dependencies
        @phony_targets = map {
            my $t = $_;
            while ($t =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $t =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            $t;
        } @phony_targets;
        warn "DEBUG[" . __LINE__ . "]:   After expansion: " . join(', ', @phony_targets) . "\n" if $ENV{SMAK_DEBUG};
        $is_phony = 1 if grep { $_ eq $target } @phony_targets;
    } else {
        warn "DEBUG[" . __LINE__ . "]:   No .PHONY target found in pseudo_deps\n" if $ENV{SMAK_DEBUG};
    }

    # Auto-detect common phony target names even without .PHONY declaration
    # This is a pragmatic extension to standard Make behavior
    if (!$is_phony && $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/) {
        warn "DEBUG[" . __LINE__ . "]:   Auto-detecting '$target' as phony (common target name)\n" if $ENV{SMAK_DEBUG};
        $is_phony = 1;
    }

    warn "DEBUG[" . __LINE__ . "]:   is_phony=$is_phony\n" if $ENV{SMAK_DEBUG};

    # Warn if phony target exists as a file
    if ($is_phony && -e $target) {
        warn "smak: Warning: phony target '$target' exists as a file and will be ignored\n";
    }

    # If not .PHONY and target is up-to-date, handle based on rebuild_missing_intermediates setting
    unless ($is_phony) {
        warn "DEBUG[" . __LINE__ . "]:   Checking if target exists and is up-to-date...\n" if $ENV{SMAK_DEBUG};
        if (-e $target && !needs_rebuild($target)) {
            warn "DEBUG:   Target '$target' is up-to-date, skipping\n" if $ENV{SMAK_DEBUG};

            # Check for missing intermediate dependencies
            if ($rebuild_missing_intermediates) {
                # Default behavior (match make): rebuild missing intermediates even if target is up-to-date
                for my $dep (@deps) {
                    next if $dep =~ /^\.PHONY$/;
                    next if $dep !~ /\S/;

                    # Check if dependency file exists (relative to current working directory)
                    if (!-e $dep) {
                        # Check if dependency has a rule (is an intermediate, not a source file)
                        my $dep_key = "$makefile\t$dep";
                        my $has_rule = exists $fixed_rule{$dep_key} || exists $pattern_rule{$dep_key};

                        if ($has_rule) {
                            warn "smak: Rebuilding missing intermediate '$dep' (even though '$target' is up-to-date)\n";
                            build_target($dep, $visited, $depth + 1);
                        }
                    }
                }
            } else {
                # Optimized behavior: notify about missing intermediates but don't rebuild
                for my $dep (@deps) {
                    next if $dep =~ /^\.PHONY$/;
                    next if $dep !~ /\S/;

                    if (!-e $dep) {
                        my $dep_key = "$makefile\t$dep";
                        my $has_rule = exists $fixed_rule{$dep_key} || exists $pattern_rule{$dep_key};

                        if ($has_rule) {
                            warn "smak: Note: intermediate '$dep' is missing but not rebuilt (target '$target' up-to-date, sources unchanged)\n";
                        }
                    }
                }
            }

            # Remove from stale cache if it was there
            delete $stale_targets_cache{$target};
            return;
        }
        warn "DEBUG[" . __LINE__ . "]:   Target needs rebuilding\n" if $ENV{SMAK_DEBUG};
        # Track this target as stale (needs rebuilding)
        $stale_targets_cache{$target} = time();
    }

    # Recursively build order-only prerequisites first (they must exist before normal prerequisites)
    # Order-only prerequisites don't affect timestamp checking, but must be built before the target
    unless ($job_server_socket) {
        if (@order_only_prereqs) {
            warn "DEBUG[" . __LINE__ . "]:   Building " . scalar(@order_only_prereqs) . " order-only prerequisites...\n" if $ENV{SMAK_DEBUG};
            for my $prereq (@order_only_prereqs) {
                warn "DEBUG[" . __LINE__ . "]:     Building order-only prerequisite: $prereq\n" if $ENV{SMAK_DEBUG};
                build_target($prereq, $visited, $depth + 1);
            }
        }
    }

    # Recursively build dependencies
    # In parallel mode (non-dry-run), skip this - let job-master handle dependency expansion
    # In dry-run mode, always expand locally to print all commands
    warn "DEBUG[" . __LINE__ . "]:   Checking job_server_socket: " . (defined $job_server_socket ? "SET (fd=" . fileno($job_server_socket) . ")" : "NOT SET") . "\n" if $ENV{SMAK_DEBUG};
    if (!$job_server_socket || $dry_run_mode) {
        warn "DEBUG[" . __LINE__ . "]:   Building " . scalar(@deps) . " dependencies" . ($dry_run_mode ? " (dry-run mode)" : " sequentially (no job server)") . "...\n" if $ENV{SMAK_DEBUG};
        # In dry-run mode, temporarily disable job server for recursive builds
        # This ensures commands are printed locally, not submitted to job-server
        local $job_server_socket = $dry_run_mode ? undef : $job_server_socket;
        for my $dep (@deps) {
            warn "DEBUG[" . __LINE__ . "]:     Building dependency: $dep\n" if $ENV{SMAK_DEBUG};
            build_target($dep, $visited, $depth + 1);
        }
        warn "DEBUG[" . __LINE__ . "]:   Finished building dependencies\n" if $ENV{SMAK_DEBUG};
    } else {
        warn "DEBUG[" . __LINE__ . "]:   Skipping dependency expansion - job server will handle it\n" if $ENV{SMAK_DEBUG};
    }

    warn "DEBUG[" . __LINE__ . "]:   Checking if should execute rule: rule defined=" . (defined $rule ? "yes" : "no") . ", has content=" . (($rule && $rule =~ /\S/) ? "yes" : "no") . "\n" if $ENV{SMAK_DEBUG};
    if ($ENV{SMAK_DEBUG} && defined $rule) {
        my $rule_preview = substr($rule, 0, 100);
        $rule_preview =~ s/\n/\\n/g;
        warn "DEBUG[" . __LINE__ . "]:   Rule value: '$rule_preview" . (length($rule) > 100 ? "...' (truncated)" : "'") . "\n";
    }

    warn "DEBUG[" . __LINE__ . "]:   rule='$rule' (". (defined $rule ? "defined" : "undef") . ", " . ($rule ? "truthy" : "falsy") . "), deps=" . scalar(@deps) . ", job_server=" . (defined $job_server_socket ? "yes" : "no") . "\n" if $ENV{SMAK_DEBUG};

    # Execute rule if it exists (submit_job is blocking, so no need to wait)
    if ($rule && $rule =~ /\S/) {
        warn "DEBUG[" . __LINE__ . "]:   Executing rule for target '$target'\n" if $ENV{SMAK_DEBUG};
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        warn "DEBUG[" . __LINE__ . "]:   After format_output\n" if $ENV{SMAK_DEBUG};
        # Expand variables
        my $expanded = expand_vars($converted);
        warn "DEBUG[" . __LINE__ . "]:   After expand_vars\n" if $ENV{SMAK_DEBUG};

        # Detect automake-style suffix rule patterns
        # These contain: depbase=`echo $@ | sed ...`; ... -MF $depbase.Tpo ... && mv ... $depbase.Tpo $depbase.Po
        # Note: After variable expansion, $$depbase becomes $depbase (single $)
        # Use non-greedy matching to avoid catastrophic backtracking
        my $is_automake_suffix = ($expanded =~ /depbase=`[^`]+`.*?\$depbase\.Tpo.*?\$depbase\.Po/);

        # For suffix rules, $< should be the source file, not .dirstamp or other deps
        my $source_prereq = $deps[0] || '';
        if ($suffix_source) {
            # Use the source file we identified when matching the suffix rule
            $source_prereq = $suffix_source;
            warn "DEBUG[" . __LINE__ . "]:   Using suffix_source='$suffix_source' for \$<\n" if $ENV{SMAK_DEBUG};
        } elsif ($stem && @deps > 0) {
            # Fallback: in suffix rule context, find the actual source file (not .dirstamp)
            for my $dep (@deps) {
                next if $dep =~ /dirstamp$/;  # Skip .dirstamp files
                next if $dep =~ /\.deps\//;    # Skip .deps/ directory markers
                $source_prereq = $dep;
                last;
            }
        }

        # Resolve source prerequisite through VPATH only if $< is actually used in the command
        # This avoids expensive getcwd() and resolve_vpath() calls for rules that don't need it
        my $resolved_source_prereq = $source_prereq;
        if ($expanded =~ /\$</ && $source_prereq) {
            use Cwd 'getcwd';
            my $cwd = getcwd();
            $resolved_source_prereq = resolve_vpath($source_prereq, $cwd);
            warn "DEBUG[" . __LINE__ . "]:   source_prereq='$source_prereq', resolved='$resolved_source_prereq'\n" if $ENV{SMAK_DEBUG};
        }

        # Expand automatic variables
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$resolved_source_prereq/g;     # $< = VPATH-resolved source file
        $expanded =~ s/\$\^/join(' ', @deps)/ge;          # $^ = all prerequisites
        $expanded =~ s/\$\*/$stem/g;                      # $* = stem (part matching %)

        warn "DEBUG[" . __LINE__ . "]:   About to execute commands\n" if $ENV{SMAK_DEBUG};

        # If this is an automake suffix rule, preprocess it
        if ($is_automake_suffix) {
            warn "DEBUG[" . __LINE__ . "]:   Detected automake suffix rule, preprocessing...\n" if $ENV{SMAK_DEBUG};
            $expanded = preprocess_automake_suffix_rule($expanded, $target);
            warn "DEBUG[" . __LINE__ . "]:   After preprocessing:\n$expanded\n" if $ENV{SMAK_DEBUG};
        }

        # Execute each command line
        for my $cmd_line (split /\n/, $expanded) {
            warn "DEBUG[" . __LINE__ . "]:     Processing command line\n" if $ENV{SMAK_DEBUG};
            next unless $cmd_line =~ /\S/;  # Skip empty lines

            warn "DEBUG[" . __LINE__ . "]:     Command: $cmd_line\n" if $ENV{SMAK_DEBUG};

            # Strip command prefixes @ (silent) and - (ignore errors) for display/flags
            # Extract leading whitespace first
            my $leading_space = '';
            my $cmd_for_parsing = $cmd_line;
            if ($cmd_for_parsing =~ /^(\s+)/) {
                $leading_space = $1;
                $cmd_for_parsing =~ s/^\s+//;
            }
            my ($clean_cmd, $silent, $ignore_errors) = strip_command_prefixes($cmd_for_parsing);
            my $display_cmd = $leading_space . $clean_cmd;

            # Handle built-in commands (skip in dry-run mode - let dummy worker print them)
            if (!$dry_run_mode && $clean_cmd =~ /^BUILTIN_MV\s+(.+)$/) {
                my $mv_args = $1;
                warn "DEBUG[" . __LINE__ . "]:     Detected built-in mv command\n" if $ENV{SMAK_DEBUG};

                # Parse mv arguments: -f source dest
                if ($mv_args =~ /^-f\s+(\S+)\s+(\S+)/) {
                    my ($source, $dest) = ($1, $2);

                    # Execute the built-in mv
                    unless ($silent_mode || $silent) {
                        print "mv -f $source $dest\n";
                    }
                    builtin_mv($source, $dest);
                    next;
                }
            }

            # Translate "make" to "smak" for built-in handling
            # This allows smak to handle recursive $(MAKE) invocations
            # Use negative lookbehind to not match "make" when preceded by a dot (file extension like .make)
            # and lookahead to only match when followed by space or end of string
            my $normalized_cmd = $clean_cmd;
            $normalized_cmd =~ s/(?<!\.)make(?=\s|$)/smak/g;

            # Normalize "cd DIR && make/smak TARGET" to "make/smak -C DIR TARGET" for built-in handling
            if ($normalized_cmd =~ /cd\s+(\S+)\s+&&\s+(.*?(?:make|smak).*)$/) {
                my ($dir, $make_cmd) = ($1, $2);
                # Remove quotes from directory if present
                $dir =~ s/^['"]//;
                $dir =~ s/['"]$//;

                # Check if make_cmd already has -C option
                unless ($make_cmd =~ /\s-C\s/) {
                    # Add -C DIR to the make command
                    if ($make_cmd =~ /^(\S+)(\s+.*)$/) {
                        $normalized_cmd = "$1 -C $dir$2";
                    } elsif ($make_cmd =~ /^(\S+)$/) {
                        $normalized_cmd = "$1 -C $dir";
                    }
                    warn "DEBUG[" . __LINE__ . "]: Normalized 'cd && make' to: $normalized_cmd\n" if $ENV{SMAK_DEBUG};
                }
            }

            # Handle compound commands with multiple commands chained with &&
            # This MUST come before the simple rm check below, otherwise compound commands
            # starting with rm will be caught by the simple rm handler
            # Split and execute each as a built-in (rm, make/smak, etc.)
            # NOTE: Handle in-process when:
            # - There's NO job server (sequential mode), OR
            # - In dry-run mode (need to expand all commands for printing)
            # Otherwise let the job-server handle compound commands (parallel mode)
            if (($dry_run_mode || !$job_server_socket) && $clean_cmd =~ /&&/) {
                warn "DEBUG[" . __LINE__ . "]: Found compound command: $clean_cmd\n" if $ENV{SMAK_DEBUG};
                # Split on && and check if we can handle all parts as built-ins
                my @parts = split(/\s+&&\s+/, $clean_cmd);
                my $can_handle_all = 1;
                for my $part (@parts) {
                    my $check_part = $part;
                    # Unwrap (cmd || true) pattern
                    if ($check_part =~ /^\s*\((.+?)\s*\|\|\s*true\s*\)\s*$/) {
                        $check_part = $1;
                    }
                    # Unwrap (cmd) pattern
                    elsif ($check_part =~ /^\s*\((.+)\)\s*$/) {
                        $check_part = $1;
                    }
                    # Allow 'true' or 'false' as terminating commands
                    next if $check_part =~ /^\s*(true|false)\s*$/;
                    # Check if it's a built-in we can handle (rm, make/smak)
                    unless ($check_part =~ /^\s*rm\b/ || $check_part =~ /\b(make|smak)\s/ || $check_part =~ m{/smak(?:\s|$)}) {
                        warn "DEBUG[" . __LINE__ . "]: Cannot handle part: $part\n" if $ENV{SMAK_DEBUG};
                        $can_handle_all = 0;
                        last;
                    }
                }

                if ($can_handle_all) {
                    warn "DEBUG[" . __LINE__ . "]: Splitting compound command with built-ins\n" if $ENV{SMAK_DEBUG};

                    # Print the original command
                    unless ($silent_mode || $silent) {
                        print "$display_cmd\n";
                    }

                    # Execute each piece
                    for my $part (@parts) {
                        my $exec_part = $part;
                        # Unwrap (cmd || true) pattern
                        if ($exec_part =~ /^\s*\((.+?)\s*\|\|\s*true\s*\)\s*$/) {
                            $exec_part = $1;
                        }
                        # Unwrap (cmd) pattern
                        elsif ($exec_part =~ /^\s*\((.+)\)\s*$/) {
                            $exec_part = $1;
                        }
                        # Skip 'true' or 'false'
                        next if $exec_part =~ /^\s*(true|false)\s*$/;

                        # Check if it's an rm command
                        if ($exec_part =~ /^\s*rm\b/) {
                            # Execute as built-in rm
                            my @args = split(/\s+/, $exec_part);
                            shift @args;  # Remove 'rm'
                            builtin_rm(@args);
                            next;
                        }

                        # Parse and execute as recursive make
                        my ($sub_makefile, $sub_directory, $sub_vars_ref, @sub_targets) = parse_make_command($exec_part);

                        if ($sub_directory || $sub_makefile || @sub_targets) {
                            # Save state
                            use Cwd 'getcwd';
                            my $saved_cwd = $sub_directory ? getcwd() : undef;
                            my $saved_makefile = $makefile;

                            # In dry-run mode, temporarily disable job server for in-process recursive builds
                            # This ensures commands are printed locally, not skipped for job-master
                            # In normal build mode, keep job server enabled for parallelism
                            my $saved_job_server_socket = $job_server_socket;
                            local $job_server_socket = $dry_run_mode ? undef : $job_server_socket;

                            # Save and set command-line variable assignments
                            my %saved_vars;
                            if ($sub_vars_ref && %$sub_vars_ref) {
                                for my $var (keys %$sub_vars_ref) {
                                    $saved_vars{$var} = $MV{$var};
                                    $MV{$var} = $sub_vars_ref->{$var};
                                }
                            }

                            # Change directory if needed
                            if ($sub_directory) {
                                chdir($sub_directory) or do {
                                    warn "Warning: Could not chdir to '$sub_directory': $!\n";
                                    next;
                                };
                            }

                            # Set makefile to full path to avoid key collisions between directories
                            my $new_cwd = getcwd();
                            $makefile = $sub_makefile || 'Makefile';
                            my $full_makefile = "$new_cwd/$makefile";
                            $full_makefile =~ s{//+}{/}g;  # Clean up double slashes
                            $makefile = $full_makefile;

                            # Parse makefile if needed - use full path to avoid collisions
                            my $test_key = "$makefile\t" . ($sub_targets[0] || 'all');
                            unless (exists $fixed_deps{$test_key} || exists $pattern_deps{$test_key} || exists $pseudo_deps{$test_key}) {
                                eval { parse_makefile($makefile); };
                                if ($@) {
                                    warn "Warning: Could not parse '$makefile': $@\n";
                                    chdir($saved_cwd) if $saved_cwd;
                                    $makefile = $saved_makefile;
                                    next;
                                }
                            }

                            # Build targets
                            if (@sub_targets) {
                                for my $sub_target (@sub_targets) {
                                    build_target($sub_target, $visited, $depth + 1);
                                }
                            } else {
                                my $first_target = get_first_target($makefile);
                                build_target($first_target, $visited, $depth + 1) if $first_target;
                            }

                            # Restore state
                            chdir($saved_cwd) if $saved_cwd;
                            for my $var (keys %saved_vars) {
                                if (defined $saved_vars{$var}) {
                                    $MV{$var} = $saved_vars{$var};
                                } else {
                                    delete $MV{$var};
                                }
                            }
                            $makefile = $saved_makefile;
                        }
                    }

                    next;  # Skip normal execution
                }
            }

            # Handle rm commands as built-ins (both normal and dry-run mode)
            # This avoids job server overhead for simple file removal commands
            # This must come AFTER compound command handling above
            if ($clean_cmd =~ /^rm\s+(.+)$/) {
                my $rm_args = $1;
                warn "DEBUG[" . __LINE__ . "]:     Detected built-in rm command\n" if $ENV{SMAK_DEBUG};

                # Parse rm arguments
                my @args = split(/\s+/, $rm_args);

                # Print command before execution
                unless ($silent_mode || $silent) {
                    print "$display_cmd\n";
                }

                # Execute the built-in rm
                my $result = builtin_rm(@args);
                if (!$result && !$ignore_errors) {
                    die "smak: *** [$target] Error 1\n";
                }
                next;
            }

            # Check if this is a recursive make/smak invocation (both dry-run and normal mode)
            if ($normalized_cmd =~ /\b(make|smak)\s/ || $normalized_cmd =~ m{/smak(?:\s|$)}) {
                warn "DEBUG[" . __LINE__ . "]: Detected recursive make/smak: $normalized_cmd\n" if $ENV{SMAK_DEBUG};

                # Parse the make/smak command line to extract -f, -C directory, variables, and targets
                my ($sub_makefile, $sub_directory, $sub_vars_ref, @sub_targets) = parse_make_command($normalized_cmd);

                warn "DEBUG[" . __LINE__ . "]: Parsed makefile='$sub_makefile' directory='$sub_directory' targets=(" . join(',', @sub_targets) . ")\n" if $ENV{SMAK_DEBUG};

                # If parse returned nothing useful (e.g., compound command like "smak -C a && smak -C b"),
                # fall through to external command execution - let the shell handle it
                if (!$sub_makefile && !$sub_directory && !@sub_targets) {
                    warn "DEBUG[" . __LINE__ . "]: Parse returned nothing - falling through to external execution\n" if $ENV{SMAK_DEBUG};
                    goto EXECUTE_EXTERNAL_COMMAND;
                }

                # Handle -C directory option: fork to get fresh rule context
                my $saved_cwd;
                if ($sub_directory) {
                    use Cwd 'getcwd';
                    $saved_cwd = getcwd();

                    warn "DEBUG[" . __LINE__ . "]: Recursive make -C $sub_directory - forking for fresh context\n" if $ENV{SMAK_DEBUG};

                    my $pid = fork();
                    if (!defined $pid) {
                        warn "Warning: Could not fork for recursive make: $!\n";
                        goto EXECUTE_EXTERNAL_COMMAND;
                    }

                    if ($pid == 0) {
                        # Child process: discard parent's rules and job server
                        %fixed_rule = ();
                        %fixed_deps = ();
                        %pattern_rule = ();
                        %pattern_deps = ();
                        %pseudo_rule = ();
                        %pseudo_deps = ();
                        %suffix_rule = ();
                        %suffix_deps = ();
                        $job_server_socket = undef;  # Force sequential build
                        $jobs = 0;

                        chdir($sub_directory) or do {
                            warn "Warning: Could not chdir to '$sub_directory': $!\n";
                            exit(1);
                        };

                        # Parse the subdirectory Makefile fresh
                        $sub_makefile = 'Makefile' unless $sub_makefile;
                        eval { parse_makefile($sub_makefile); };
                        if ($@) {
                            warn "Warning: Could not parse '$sub_makefile' in '$sub_directory': $@\n";
                            exit(1);
                        }

                        # Build the targets
                        my $exit_code = 0;
                        eval {
                            if (@sub_targets) {
                                for my $sub_target (@sub_targets) {
                                    build_target($sub_target, {}, 0);
                                }
                            } else {
                                my $first_target = get_first_target($sub_makefile);
                                build_target($first_target, {}, 0) if $first_target;
                            }
                        };
                        if ($@) {
                            warn "Build failed: $@\n";
                            $exit_code = 1;
                        }
                        exit($exit_code);
                    }

                    # Parent: wait for child
                    waitpid($pid, 0);
                    my $child_exit = $? >> 8;
                    if ($child_exit != 0) {
                        die "Recursive make in '$sub_directory' failed (exit $child_exit)\n";
                    }
                    next;  # Continue with next command
                }

                if ($sub_makefile) {
                    # Check if any variable values contain backticks that need shell evaluation
                    # If so, fall back to external execution so the shell can handle them
                    if ($sub_vars_ref && %$sub_vars_ref) {
                        for my $var (keys %$sub_vars_ref) {
                            if ($sub_vars_ref->{$var} =~ /`/) {
                                warn "DEBUG[" . __LINE__ . "]: Variable $var contains backticks, falling back to external execution\n" if $ENV{SMAK_DEBUG};
                                if ($saved_cwd) {
                                    chdir($saved_cwd) or warn "Warning: Could not restore directory to '$saved_cwd': $!\n";
                                }
                                goto EXECUTE_EXTERNAL_COMMAND;
                            }
                        }
                    }

                    # Save current makefile state
                    my $saved_makefile = $makefile;

                    # Save and set command-line variable assignments
                    my %saved_vars;
                    if ($sub_vars_ref && %$sub_vars_ref) {
                        for my $var (keys %$sub_vars_ref) {
                            $saved_vars{$var} = $MV{$var};
                            $MV{$var} = $sub_vars_ref->{$var};
                            warn "DEBUG[" . __LINE__ . "]: Set variable $var='$sub_vars_ref->{$var}'\n" if $ENV{SMAK_DEBUG};
                        }
                    }

                    # Determine the makefile name (use default if not specified)
                    $sub_makefile = 'Makefile' unless $sub_makefile;

                    # Switch to sub-makefile
                    $makefile = $sub_makefile;

                    # Parse the sub-makefile if not already parsed
                    my $test_key = "$makefile\t" . ($sub_targets[0] || 'all');
                    unless (exists $fixed_deps{$test_key} || exists $pattern_deps{$test_key} || exists $pseudo_deps{$test_key}) {
                        eval {
                            parse_makefile($makefile);
                        };
                        if ($@) {
                            warn "Warning: Could not parse sub-makefile '$makefile': $@\n";
                            # Restore state and fall back to executing as external command
                            $makefile = $saved_makefile;
                            # Fall through to normal command execution
                            goto EXECUTE_EXTERNAL_COMMAND;
                        }
                    }

                    # Build sub-targets internally
                    unless ($silent_mode || $silent) {
                        print "$display_cmd\n";
                    }
                    if (@sub_targets) {
                        for my $sub_target (@sub_targets) {
                            build_target($sub_target, $visited, $depth + 1);
                        }
                    } else {
                        # No targets specified, build first target
                        my $first_target = get_first_target($makefile);
                        build_target($first_target, $visited, $depth + 1) if $first_target;
                    }

                    # Restore directory if changed
                    if ($saved_cwd) {
                        chdir($saved_cwd) or warn "Warning: Could not restore directory to '$saved_cwd': $!\n";
                    }

                    # Restore variable assignments
                    for my $var (keys %saved_vars) {
                        if (defined $saved_vars{$var}) {
                            $MV{$var} = $saved_vars{$var};
                        } else {
                            delete $MV{$var};
                        }
                    }

                    # Restore makefile state
                    $makefile = $saved_makefile;
                    next;
                } else {
                    # No -f or -C options, build targets in current makefile
                    # Print command before execution
                    unless ($silent_mode || $silent) {
                        print "$display_cmd\n";
                    }

                    if (@sub_targets) {
                        for my $sub_target (@sub_targets) {
                            build_target($sub_target, $visited, $depth + 1);
                        }
                    } else {
                        # No targets specified, build first target
                        my $first_target = get_first_target($makefile);
                        build_target($first_target, $visited, $depth + 1) if $first_target;
                    }

                    # Restore directory if changed
                    if ($saved_cwd) {
                        chdir($saved_cwd) or warn "Warning: Could not restore directory to '$saved_cwd': $!\n";
                    }
                    next;
                }
            }

            EXECUTE_EXTERNAL_COMMAND:
            # Execute command - use job system if available, otherwise sequential
            # Built-in commands (rm, mv, recursive smak -C) can be handled in-process,
            # BUT only if the target has no dependencies. Targets with dependencies
            # must go through the job server for proper dependency tracking.
            use Cwd 'getcwd';
            my $cwd = getcwd();
            my $use_builtin = is_builtin_command($cmd_line);
            # Submit to job server if: job server exists AND jobs > 0 AND
            # (command is not built-in OR target has dependencies that need tracking)
            if ($job_server_socket && 0 != $jobs && (!$use_builtin || @deps > 0)) {
                warn "DEBUG[" . __LINE__ . "]:     Using job server ($jobs)\n" if $ENV{SMAK_DEBUG};
                # Parallel mode - submit to job server (job master will echo the command)
                submit_job($target, $cmd_line, $cwd);
            } else {
                warn "DEBUG[" . __LINE__ . "]:     Sequential execution (job_server_socket=" . (defined $job_server_socket ? "defined" : "undef") . ", jobs=$jobs, dry_run=$dry_run_mode, builtin=$use_builtin)\n" if $ENV{SMAK_DEBUG};
                # Sequential mode or built-in command - echo command here, then execute directly
                # In dry-run mode without job server, we must print here since there's no dummy worker
                # In dry-run mode, always print (like make -n) - ignore @ prefix
                unless ($silent_mode || (!$dry_run_mode && $silent)) {
                    print "$display_cmd\n";
                }
                execute_command_sequential($target, $cmd_line, $cwd);
                warn "DEBUG[" . __LINE__ . "]:     Command completed\n" if $ENV{SMAK_DEBUG};
            }
        }
    } elsif ($job_server_socket && @deps > 0 && !$dry_run_mode) {
        # In parallel mode with no rule but has dependencies
        # Submit to job-master for dependency expansion
        # (Skip in dry-run mode - we already printed all commands recursively)
        use Cwd 'getcwd';
        my $cwd = getcwd();
        warn "DEBUG: Submitting composite target '$target' to job-master\n" if $ENV{SMAK_DEBUG};
        submit_job($target, "true", $cwd);
    }
}

sub dry_run_target {
    my ($target, $visited, $depth, $opts) = @_;
    $visited ||= {};
    $depth ||= 0;
    $opts ||= {};

    # Options:
    #   capture => \%hash   - capture target info to this hash
    #   no_commands => 1    - suppress printing commands (log targets only)
    #   prefix => 'dir'     - prefix for target paths (e.g., "vhdlpp" -> "vhdlpp/target")

    my $prefix = $opts->{prefix} || '';
    my $full_target = $prefix ? "$prefix/$target" : $target;

    # Skip RCS/SCCS implicit rule patterns (these create infinite loops)
    # Make's built-in rules try: RCS/file,v, SCCS/s.file, etc.
    if ($target =~ m{(?:^|/)(?:RCS|SCCS)/} ||
        $target =~ /^s\./ ||
        $target =~ /,v+$/) {
        return;
    }

    # Prevent infinite recursion
    if ($depth > 100) {
        warn "Warning: Maximum recursion depth (100) reached for target '$target' in $makefile\n";
        warn "         This may indicate a circular dependency or overly deep dependency chain.\n";
        return;
    }

    # Track visited targets per makefile to handle same target names in different makefiles
    my $visit_key = "$makefile\t$target";
    return if $visited->{$visit_key};
    $visited->{$visit_key} = 1;

    my $indent = "  " x $depth;
    print "${indent}Building: $target\n" unless $opts->{no_commands};

    my $key = "$makefile\t$target";
    my @deps;
    my $rule = '';
    my $stem = '';  # Track stem for $* automatic variable

    # Find target in fixed, pattern, or pseudo rules
    if (exists $fixed_deps{$key}) {
        @deps = @{$fixed_deps{$key} || []};
        $rule = $fixed_rule{$key} || '';

        # If fixed rule has no command, try to find pattern rule
        if (!$rule || $rule !~ /\S/) {
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        # Use pattern rule's command
                        my $rules_ref = $pattern_rule{$pkey};
                        my $deps_ref = $pattern_deps{$pkey} || [];
                        $stem = $1;  # Save stem for $* expansion

                        # Handle multi-variant format: find best variant whose source exists
                        my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
                        my @deps_lists = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

                        # Find first variant whose source files exist
                        my $best_variant = 0;
                        for (my $i = 0; $i < @rules; $i++) {
                            my @variant_deps = ref($deps_lists[$i]) eq 'ARRAY' ? @{$deps_lists[$i]} : ();
                            my $all_exist = 1;
                            for my $dep (@variant_deps) {
                                my $dep_expanded = $dep;
                                $dep_expanded =~ s/%/$stem/g;
                                unless (-e $dep_expanded) {
                                    $all_exist = 0;
                                    last;
                                }
                            }
                            if ($all_exist && @variant_deps > 0) {
                                $best_variant = $i;
                                last;
                            }
                        }

                        $rule = $rules[$best_variant] || '';
                        # Add pattern rule's dependencies to fixed dependencies
                        my @pattern_deps = ref($deps_lists[$best_variant]) eq 'ARRAY'
                            ? @{$deps_lists[$best_variant]} : ();
                        @pattern_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @pattern_deps;
                        # Resolve dependencies through vpath
                        use Cwd 'getcwd';
                        my $cwd = getcwd();
                        @pattern_deps = map { resolve_vpath($_, $cwd) } @pattern_deps;
                        push @deps, @pattern_deps;
                        last;
                    }
                }
            }
        }

        # For explicit rules, compute $* from target name if not already set by pattern rule
        if (!$stem && $target =~ /^(.+)\.([^.\/]+)$/) {
            $stem = $1;  # Target name without suffix (e.g., "main" from "main.o")
        }
    } elsif (exists $pattern_deps{$key}) {
        # Exact pattern match - check all variants and use the one whose source exists
        my $rules_ref = $pattern_rule{$key};
        my $deps_ref = $pattern_deps{$key};

        # Handle both old single-rule format and new array format
        my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
        my @deps_list = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

        # Try to find a variant whose source files exist
        my $best_variant = 0;  # Default to first variant

        for (my $i = 0; $i < @rules; $i++) {
            my @variant_deps = @{$deps_list[$i] || []};

            # Check if all prerequisites exist
            my $all_exist = 1;
            for my $dep (@variant_deps) {
                # Note: dependencies might have %, need to expand if this is a pattern
                my $dep_to_check = $dep;
                if ($dep =~ /%/ && $target =~ /^(.+)\.([^.]+)$/) {
                    # Extract stem from target and expand dependency
                    my $stem = $1;
                    $dep_to_check =~ s/%/$stem/g;
                }

                use Cwd 'getcwd';
                my $cwd = getcwd();
                my $dep_path = $dep_to_check =~ m{^/} ? $dep_to_check : "$cwd/$dep_to_check";

                unless (-e $dep_path) {
                    $all_exist = 0;
                    last;
                }
            }

            if ($all_exist && @variant_deps > 0) {
                $best_variant = $i;
                warn "DEBUG: Found existing source for variant $i of $target\n" if $ENV{SMAK_DEBUG};
                last;
            }
        }

        # Use best variant
        @deps = @{$deps_list[$best_variant] || []};
        $rule = $rules[$best_variant] || '';
        warn "DEBUG: Using variant $best_variant for exact pattern match $target\n" if $ENV{SMAK_DEBUG};
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try to find pattern rule match
        PATTERN_MATCH_FALLBACK: for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    $stem = $1;  # Save stem for $* expansion

                    # Pattern rules can have multiple variants
                    my $rules_ref = $pattern_rule{$pkey};
                    my $deps_ref = $pattern_deps{$pkey};

                    # Handle both old single-rule format and new array format
                    my @rules = ref($rules_ref) eq 'ARRAY' ? @$rules_ref : ($rules_ref);
                    my @deps_list = ref($deps_ref->[0]) eq 'ARRAY' ? @$deps_ref : ([$deps_ref]);

                    # Try to find a variant whose source file exists
                    # If none exist, fall back to first variant (like GNU make)
                    my $best_variant = 0;  # Default to first variant

                    for (my $i = 0; $i < @rules; $i++) {
                        my @variant_deps = @{$deps_list[$i] || []};

                        # Expand % in dependencies with the stem
                        my @expanded_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;

                        # Resolve dependencies through vpath
                        use Cwd 'getcwd';
                        my $cwd = getcwd();
                        @expanded_deps = map { resolve_vpath($_, $cwd) } @expanded_deps;

                        # Check if all prerequisites exist
                        my $all_prereqs_ok = 1;
                        for my $prereq (@expanded_deps) {
                            my $prereq_path = $prereq =~ m{^/} ? $prereq : "$cwd/$prereq";
                            unless (-e $prereq_path) {
                                $all_prereqs_ok = 0;
                                last;
                            }
                        }

                        if ($all_prereqs_ok) {
                            # Found a variant whose prerequisites all exist - use it
                            $best_variant = $i;
                            last;
                        }
                    }

                    # Check if any variant has existing prerequisites
                    use Cwd 'getcwd';
                    my $cwd = getcwd();
                    my $any_variant_ok = 0;
                    for (my $j = 0; $j < @rules; $j++) {
                        my @vdeps = @{$deps_list[$j] || []};
                        my @exdeps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @vdeps;
                        @exdeps = map { resolve_vpath($_, $cwd) } @exdeps;
                        my $all_ok = 1;
                        for my $prereq (@exdeps) {
                            my $pp = $prereq =~ m{^/} ? $prereq : "$cwd/$prereq";
                            $all_ok = 0 unless -e $pp;
                        }
                        if ($all_ok && @exdeps > 0) {
                            $any_variant_ok = 1;
                            $best_variant = $j;
                            last;
                        }
                    }

                    # If no variant has existing prereqs and target already exists, skip this pattern rule
                    # The target is a source file, not something to be built from this pattern
                    my $target_path = $target =~ m{^/} ? $target : "$cwd/$target";
                    if (!$any_variant_ok && -e $target_path) {
                        # Target exists, no applicable pattern rule - skip
                        next PATTERN_MATCH_FALLBACK;
                    }

                    # Use the best variant (either one with existing prereqs, or the first one if target doesn't exist)
                    my @variant_deps = @{$deps_list[$best_variant] || []};
                    @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;
                    $rule = $rules[$best_variant] || '';

                    # Resolve dependencies through vpath
                    @deps = map { resolve_vpath($_, $cwd) } @deps;
                    last PATTERN_MATCH_FALLBACK;
                }
            }
        }

        # If still no rule found, try suffix rules
        if (!$rule || $rule !~ /\S/) {
            # Extract target suffix (e.g., .o from foo.o)
            if ($target =~ /^(.+)(\.[^.\/]+)$/) {
                my $base = $1;
                my $target_suffix = $2;

                # Try each possible source suffix in order
                for my $source_suffix (@suffixes) {
                    # Skip if this is the target suffix itself
                    next if $source_suffix eq $target_suffix;

                    # Check if a suffix rule exists for this source->target combination
                    my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                    if (exists $suffix_rule{$suffix_key}) {
                        # Check if source file exists
                        my $source = "$base$source_suffix";
                        # Resolve source through vpath
                        use Cwd 'getcwd';
                        my $cwd = getcwd();
                        my $resolved_source = resolve_vpath($source, $cwd);

                        if (-f $resolved_source) {
                            # Found matching suffix rule and source file
                            $stem = $base;
                            @deps = ($source);  # Store unresolved path, will be resolved later
                            $rule = $suffix_rule{$suffix_key};
                            my $suffix_deps_ref = $suffix_deps{$suffix_key};
                            if ($suffix_deps_ref && @$suffix_deps_ref) {
                                # Expand % in suffix rule dependencies (rare but possible)
                                my @suffix_deps_expanded = map {
                                    my $d = $_;
                                    $d =~ s/%/$stem/g;
                                    $d;
                                } @$suffix_deps_ref;
                                push @deps, @suffix_deps_expanded;
                            }
                            warn "DEBUG: Using suffix rule $source_suffix$target_suffix for $target from $source\n" if $ENV{SMAK_DEBUG};
                            last;
                        }
                    }
                }
            }
        }

        # If still no rule found, try built-in implicit rules (like Make's built-in rules)
        if (!$rule || $rule !~ /\S/) {
            # Check for object file (.o) targets
            if ($target =~ /^(.+)\.o$/) {
                my $base = $1;
                # Try different source file extensions in order (C first, then C++)
                my @source_exts = ('c', 'cc', 'cpp', 'C', 'cxx', 'c++');
                for my $ext (@source_exts) {
                    my $source = "$base.$ext";
                    # Check if source file exists
                    if (-f $source) {
                        $stem = $base;
                        @deps = ($source);
                        # Use appropriate compilation rule based on extension
                        if ($ext eq 'c') {
                            $rule = "\t\$(COMPILE.c) \$(OUTPUT_OPTION) \$<\n";
                        } else {
                            $rule = "\t\$(COMPILE.cc) \$(OUTPUT_OPTION) \$<\n";
                        }
                        warn "DEBUG: Using built-in implicit rule for $target from $source\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }
    }

    # Expand variables in dependencies (which are in $MV{VAR} format)
    # Note: Variables like $O can expand to multiple space-separated values
    @deps = map {
        my $dep = $_;
        # Expand $MV{VAR} references
        while ($dep =~ /\$MV\{([^}]+)\}/) {
            my $var = $1;
            my $val = $MV{$var} // '';
            $dep =~ s/\$MV\{\Q$var\E\}/$val/;
        }
        # If expansion resulted in multiple space-separated values, split them
        if ($dep =~ /\s/) {
            split /\s+/, $dep;
        } else {
            $dep;
        }
    } @deps;
    # Flatten and filter empty strings
    @deps = grep { $_ ne '' } @deps;

    # Strip redundant ./ prefixes from dependencies ($(srcdir) = . produces ./file)
    @deps = map { s{^\.\/}{}; $_ } @deps;

    # Apply vpath resolution to all dependencies
    use Cwd 'getcwd';
    my $cwd = getcwd();
    @deps = map { resolve_vpath($_, $cwd) } @deps;

    # Print dependencies
    if (@deps) {
        print "${indent}  Dependencies: ", join(', ', @deps), "\n";
    }

    # Check for multi-output siblings (needed for both capture and regular dry-run)
    my @siblings;
    for my $pkey (keys %pattern_rule) {
        if ($pkey =~ /^[^\t]+\t(.+)$/) {
            my $pattern = $1;
            my $pattern_re = $pattern;
            $pattern_re =~ s/%/(.+)/g;
            if ($target =~ /^$pattern_re$/) {
                my $s = $1;
                my ($mf_part, $pattern_part) = split(/\t/, $pkey, 2);
                my $target_key = "$makefile\t$pattern_part";
                if (exists $multi_output_siblings{$target_key}) {
                    @siblings = map { my $t = $_; $t =~ s/%/$s/g; $t } @{$multi_output_siblings{$target_key}};
                }
                last;
            }
        }
    }

    # If this target has siblings (part of compound), mark ALL siblings as visited
    # This prevents the same rule from running multiple times
    if (@siblings > 1) {
        for my $sib (@siblings) {
            my $sib_key = "$makefile\t$sib";
            $visited->{$sib_key} = 1;
        }
    }

    # Capture target info if requested (for btree)
    if ($opts->{capture}) {
        # exec_dir is the prefix (subdirectory) or '.' for root
        my $exec_dir = $prefix || '.';

        # Apply prefix to deps for full paths
        my @full_deps = $prefix ? map { "$prefix/$_" } @deps : @deps;

        # Apply prefix to siblings for full paths
        my @full_siblings = $prefix ? map { "$prefix/$_" } @siblings : @siblings;

        # Store to capture hash using full_target
        my $compound_parent = '';
        if (@full_siblings > 1) {
            my $compound = join('&', sort @full_siblings);
            # If we're a sibling but not the "primary" (first alphabetically), point to compound
            if ($full_target ne (sort @full_siblings)[0]) {
                $compound_parent = $compound;
            }
            # Also store compound target
            $opts->{capture}{$compound} = {
                deps => [@full_deps],
                rule => $rule,
                exec_dir => $exec_dir,
                siblings => [@full_siblings],
            } unless exists $opts->{capture}{$compound};
        }

        $opts->{capture}{$full_target} = {
            deps => [@full_deps],
            rule => $rule,
            exec_dir => $exec_dir,
            siblings => \@full_siblings,
            compound_parent => $compound_parent,
        };
    }

    # Recursively dry-run dependencies
    for my $dep (@deps) {
        dry_run_target($dep, $visited, $depth + 1, $opts);
    }

    # Process rule if it exists
    # Even with no_commands mode, we need to process for capture (recursive make detection)
    if ($rule && $rule =~ /\S/ && (!$opts->{no_commands} || $opts->{capture})) {
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        # Expand variables
        my $expanded = expand_vars($converted);

        # Expand automatic variables
        my $first_prereq = @deps ? $deps[0] : '';
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$first_prereq/g;               # $< = first prerequisite
        $expanded =~ s/\$\^/join(' ', @deps)/ge;          # $^ = all prerequisites
        $expanded =~ s/\$\*/$stem/g if $stem;             # $* = stem from pattern rule

        # Strip redundant ./ prefixes from paths ($(srcdir) = . produces ./file instead of file)
        $expanded =~ s{(\s)\.\/}{$1}g;   # " ./" -> " "
        $expanded =~ s{^\.\/}{};          # Leading "./" -> ""

        # Strip command prefixes from each line for display
        # (@ means silent, - means ignore errors - both should be removed for dry-run output)
        my @lines = split(/\n/, $expanded);
        for my $line (@lines) {
            # Only strip prefixes from command lines (not empty lines)
            if ($line =~ /\S/) {
                # Extract leading whitespace
                my $leading_space = '';
                if ($line =~ /^(\s+)/) {
                    $leading_space = $1;
                    $line =~ s/^\s+//;  # Remove leading whitespace temporarily
                }
                my ($clean_line, $silent, $ignore_errors) = strip_command_prefixes($line);

                # Check if this line contains recursive smak/make -C calls
                # If so, recurse internally to capture targets for btree
                if ($clean_line =~ m{\b(?:smak|make)\s.*-C\s+\S+}) {
                    # Split on && to handle compound commands
                    my @parts = split(/\s+&&\s+/, $clean_line);
                    for my $part (@parts) {
                        $part =~ s/^\s+|\s+$//g;
                        next if $part eq 'true' || $part eq ':' || $part eq '';

                        if ($part =~ m{^(.*?\b(?:smak|make))\s+(.*-C\s+(\S+).*)$}) {
                            my $cmd = $1;
                            my $args = $2;
                            my $sub_directory = $3;

                            # Parse additional targets from args
                            my @sub_targets;
                            # Remove -C dir from args to find remaining targets
                            my $remaining = $args;
                            $remaining =~ s/-C\s+\S+\s*//g;
                            $remaining =~ s/-[nwkj]\s*//g;  # Remove common flags
                            $remaining =~ s/^\s+|\s+$//g;
                            @sub_targets = split(/\s+/, $remaining) if $remaining;

                            # If capturing, recurse internally for btree
                            if ($opts->{capture}) {
                                use Cwd 'getcwd';
                                my $saved_cwd = getcwd();
                                my $saved_makefile = $makefile;

                                # Compute the new prefix (accumulates for nested subdirs)
                                my $new_prefix = $prefix ? "$prefix/$sub_directory" : $sub_directory;

                                if (chdir($sub_directory)) {
                                    my $new_dir = getcwd();
                                    # Use full path for makefile to make keys unique per directory
                                    $makefile = "$new_dir/Makefile";

                                    # Parse the sub-makefile using parse_included_makefile to accumulate
                                    my $test_key = "$makefile\tall";
                                    unless (exists $fixed_deps{$test_key} || exists $pattern_deps{$test_key} || exists $pseudo_deps{$test_key}) {
                                        eval { parse_included_makefile($makefile); };
                                        if ($@) {
                                            warn "Warning: Could not parse '$makefile': $@\n";
                                            chdir($saved_cwd);
                                            $makefile = $saved_makefile;
                                            next;
                                        }
                                    }

                                    # Get targets to process
                                    @sub_targets = (get_first_target($makefile) || 'all') unless @sub_targets;

                                    # Create new opts with updated prefix
                                    my %sub_opts = %$opts;
                                    $sub_opts{prefix} = $new_prefix;

                                    for my $sub_target (@sub_targets) {
                                        # Recurse with capture and new prefix
                                        dry_run_target($sub_target, $visited, $depth + 1, \%sub_opts);
                                    }

                                    # Restore state
                                    chdir($saved_cwd);
                                    $makefile = $saved_makefile;
                                } else {
                                    warn "Warning: Could not chdir to '$sub_directory': $!\n";
                                }
                            } else {
                                # Not capturing, execute externally like before
                                $args = "-n $args" unless $args =~ /(?:^|\s)-n(?:\s|$)/;
                                my $full_cmd = "$cmd $args 2>&1";
                                warn "DEBUG: Recursive dry-run: $full_cmd\n" if $ENV{SMAK_DEBUG};
                                my $output = `$full_cmd`;
                                print $output if defined $output && !$opts->{no_commands};
                            }
                        } else {
                            # Not a recursive make, just print it
                            print $leading_space, $part, "\n" unless $opts->{no_commands};
                        }
                    }
                } else {
                    # Regular command, just print it
                    print $leading_space, $clean_line, "\n" unless $opts->{no_commands};
                }
            } else {
                print $line, "\n" unless $opts->{no_commands};
            }
        }
    }
}

# Run check mode: compare smak -n output with make -n
# Returns: (match_status, report_text)
#   match_status: 1 = match, 0 = differ, -1 = error
#
# Note: This is a simple comparison tool. Both smak and make dry-run outputs
# should already be fully expanded/normalized by their respective engines.
# Differences found here indicate bugs in smak's dry-run expansion logic.
sub run_check_mode {
    my ($target, $makefile_path) = @_;

    my @report;
    push @report, "=== smak -check: Comparing dry-run output ===";
    push @report, "Target: $target";
    push @report, "Makefile: $makefile_path";
    push @report, "";

    # Step 1: Run smak -n externally (uses same code path as normal builds)
    # This ensures we test the actual smak behavior, not a special code path
    use FindBin qw($RealBin);
    my $smak_cmd = "$RealBin/smak -n -f " . quotemeta($makefile_path) . " " . quotemeta($target) . " 2>&1";
    my $smak_output = `$smak_cmd`;
    my $smak_exit = $? >> 8;

    if ($smak_exit != 0 && $smak_output =~ /No rule to make target/) {
        return (-1, "Error: smak -n failed:\n$smak_output");
    }
    my @smak_commands = normalize_check_output($smak_output, 'smak');

    # Step 2: Run make -n and capture output
    my $make_cmd = "make -n -f " . quotemeta($makefile_path) . " " . quotemeta($target) . " 2>&1";
    my $make_output = `$make_cmd`;
    my $make_exit = $? >> 8;

    if ($make_exit != 0 && $make_output =~ /No rule to make target/) {
        return (-1, "Error: make -n failed:\n$make_output");
    }
    my @make_commands = normalize_check_output($make_output, 'make');

    # Step 3: Compare command sets
    my %smak_set = map { $_ => 1 } @smak_commands;
    my %make_set = map { $_ => 1 } @make_commands;

    my @smak_only = grep { !exists $make_set{$_} } @smak_commands;
    my @make_only = grep { !exists $smak_set{$_} } @make_commands;

    # Step 4: Generate report
    if (@smak_only) {
        push @report, "Commands only in smak (not in make -n):";
        push @report, "  + $_" for @smak_only;
        push @report, "";
    }

    if (@make_only) {
        push @report, "Commands only in make -n (not in smak):";
        push @report, "  - $_" for @make_only;
        push @report, "";
    }

    my $total_diff = @smak_only + @make_only;
    if ($total_diff == 0) {
        push @report, "Result: MATCH - smak and make agree on " . scalar(@smak_commands) . " command(s)";
    } else {
        push @report, "Result: MISMATCH - $total_diff difference(s) found";
        push @report, "  smak unique: " . scalar(@smak_only);
        push @report, "  make unique: " . scalar(@make_only);
    }

    my $match = ($total_diff == 0) ? 1 : 0;
    return ($match, join("\n", @report) . "\n");
}

# Normalize dry-run output for comparison
# Only does minimal formatting normalization - the actual command content
# should match between smak and make if smak's expansion is correct.
sub normalize_check_output {
    my ($output, $source) = @_;

    my @raw_lines = split(/\n/, $output);
    my @lines;

    # First pass: join continuation lines (ending with \)
    my $continued = '';
    for my $line (@raw_lines) {
        if ($line =~ s/\s*\\$//) {
            $continued .= $line . ' ';
        } else {
            if ($continued) {
                push @lines, $continued . $line;
                $continued = '';
            } else {
                push @lines, $line;
            }
        }
    }
    push @lines, $continued if $continued;

    my @commands;
    for my $line (@lines) {
        # Skip empty lines
        next if $line =~ /^\s*$/;

        # Skip smak-specific headers (not actual commands)
        next if $source eq 'smak' && $line =~ /^\s*Building:/;
        next if $source eq 'smak' && $line =~ /^\s*Dependencies:/;
        next if $source eq 'smak' && $line =~ /^\s*\(up-to-date\)/;

        # Skip make status messages (not actual commands)
        next if $line =~ /^make\[\d+\]: (Entering|Leaving) directory/;
        next if $line =~ /^make\[\d+\]: Nothing to be done/;
        next if $line =~ /^make: Nothing to be done/;

        # Normalize whitespace
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        $line =~ s/\s+/ /g;

        # Normalize ./ prefixes (make is inconsistent about these)
        $line =~ s{(\s)\.\/}{$1}g;   # " ./" -> " "
        $line =~ s{^\.\/}{};          # Leading "./" -> ""

        push @commands, $line if $line =~ /\S/;
    }

    return @commands;
}

sub add_rule {
    my ($target, $deps, $rule_text) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $rule_text = transform_make_vars($rule_text);
    $deps = transform_make_vars($deps);

    my @deps_array = split /\s+/, $deps;

    if ($type eq 'fixed') {
        $fixed_rule{$key} = $rule_text . "\n";
        $fixed_deps{$key} = \@deps_array;
    } elsif ($type eq 'pattern') {
        $pattern_rule{$key} = $rule_text . "\n";
        $pattern_deps{$key} = \@deps_array;
    } elsif ($type eq 'pseudo') {
        $pseudo_rule{$key} = $rule_text . "\n";
        $pseudo_deps{$key} = \@deps_array;
    }

    # Track modification
    my $escaped_rule = $rule_text;
    $escaped_rule =~ s/\n/\\n/g;
    $escaped_rule =~ s/\t/\\t/g;
    push @modifications, "add-rule $target : $deps : $escaped_rule\n";

    print "Added rule for '$target'\n";
}

sub modify_rule {
    my ($target, $rule_text) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $rule_text = transform_make_vars($rule_text);

    my $found = 0;
    if ($type eq 'fixed' && exists $fixed_rule{$key}) {
        $fixed_rule{$key} = $rule_text . "\n";
        $found = 1;
    } elsif ($type eq 'pattern' && exists $pattern_rule{$key}) {
        $pattern_rule{$key} = $rule_text . "\n";
        $found = 1;
    } elsif ($type eq 'pseudo' && exists $pseudo_rule{$key}) {
        $pseudo_rule{$key} = $rule_text . "\n";
        $found = 1;
    }

    if ($found) {
        # Track modification
        my $escaped_rule = $rule_text;
        $escaped_rule =~ s/\n/\\n/g;
        $escaped_rule =~ s/\t/\\t/g;
        push @modifications, "mod-rule $target : $escaped_rule\n";
        print "Modified rule for '$target'\n";
    } else {
        print "Rule '$target' not found\n";
    }
}

sub modify_deps {
    my ($target, $deps) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $deps = transform_make_vars($deps);

    my @deps_array = split /\s+/, $deps;

    my $found = 0;
    if ($type eq 'fixed' && exists $fixed_deps{$key}) {
        $fixed_deps{$key} = \@deps_array;
        $found = 1;
    } elsif ($type eq 'pattern' && exists $pattern_deps{$key}) {
        $pattern_deps{$key} = \@deps_array;
        $found = 1;
    } elsif ($type eq 'pseudo' && exists $pseudo_deps{$key}) {
        $pseudo_deps{$key} = \@deps_array;
        $found = 1;
    }

    if ($found) {
        # Track modification
        push @modifications, "mod-deps $target : $deps\n";
        print "Modified dependencies for '$target'\n";
    } else {
        print "Target '$target' not found\n";
    }
}

sub delete_rule {
    my ($target) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    my $found = 0;
    if ($type eq 'fixed') {
        delete $fixed_rule{$key} if exists $fixed_rule{$key};
        delete $fixed_deps{$key} if exists $fixed_deps{$key};
        $found = 1;
    } elsif ($type eq 'pattern') {
        delete $pattern_rule{$key} if exists $pattern_rule{$key};
        delete $pattern_deps{$key} if exists $pattern_deps{$key};
        $found = 1;
    } elsif ($type eq 'pseudo') {
        delete $pseudo_rule{$key} if exists $pseudo_rule{$key};
        delete $pseudo_deps{$key} if exists $pseudo_deps{$key};
        $found = 1;
    }

    if ($found) {
        # Track modification
        push @modifications, "del-rule $target\n";
        print "Deleted rule '$target'\n";
    } else {
        print "Rule '$target' not found\n";
    }
}

sub save_modifications {
    my ($output_file) = @_;

    open(my $out_fh, '>', $output_file) or die "Cannot open '$output_file' for writing: $!\n";

    for my $mod (@modifications) {
        print $out_fh $mod;
    }

    close($out_fh);
    print "Saved modifications to '$output_file'\n";
}

our $interactive = 0;
our $busy = 0; # more to do, not just waiting.
our $rp_pending = 0;

# Unified CLI - handles both standalone and attached modes
sub unified_cli {
    my %opts = @_;
    # Options:
    #   socket         => Job server socket (if attached)
    #   server_pid     => Job server PID (if we own it)
    #   mode           => 'standalone' | 'attached'
    #   jobs           => Number of parallel jobs
    #   makefile       => Makefile path
    #   own_server     => 1 if we started the server, 0 if attaching
    #   prompt         => CLI prompt string (optional)
    #   term           => Term::ReadLine object (optional)

    use IO::Select;
    use lib '.';

    my $mode = $opts{mode} || 'standalone';
    my $socket = $opts{socket};
    my $server_pid = $opts{server_pid};
    my $own_server = $opts{own_server} // ($mode eq 'standalone' ? 1 : 0);
    my $jobs = $opts{jobs} || 1;
    my $makefile = $opts{makefile} || 'Makefile';
    my $quiet = $opts{opts} || 1;

    my $prompt = $opts{prompt} || 'smak> ';
    my $ret = "detach";

    # Track state
    my $watch_enabled = 0;
    my $exit_requested = 0;
    my $detached = 0;
    my $watcher_pid;        # Auto-rescan watcher process ID
    my $watcher_socket;     # Socket for communication with watcher

    if (! $quiet) {
	print "Smak CLI - type 'help' for commands\n";
	print "Mode: $mode\n";
	print "Makefile: $makefile\n";
	print "Parallel jobs: $jobs\n" if $jobs > 1;
	print "\n";
    }

    # Claim CLI ownership
    $SmakCli::cli_owner = $$;
    $ENV{SMAK_CLI_PID} = $SmakCli::cli_owner;
    $ENV{SMAK_PID}     = $$;

    # Broadcast ownership to job server and all workers via SIGWINCH
    if ($socket && $server_pid) {
        # Send ownership info to job server
        print $socket "CLI_OWNER $$\n";
        $socket->flush() if $socket->can('flush');

        # Signal all processes to pick up the new CLI owner
        kill 'WINCH', $server_pid if $server_pid > 0;

        # Auto-enable watch mode if FUSE is detected
        if ($ENV{SMAK_FUSE_DETECTED}) {
            print $socket "WATCH_START\n";
            $socket->flush();
            my $response = <$socket>;
            if ($response) {
                chomp $response;
                if ($response eq 'WATCH_STARTED') {
                    $watch_enabled = 1;
                    print "Watch mode enabled (FUSE file change notifications active)\n";
                } elsif ($response =~ /^WATCH_UNAVAILABLE/) {
                    print STDERR "Warning: FUSE detected but watch mode unavailable\n" if $ENV{SMAK_DEBUG};
                }
            }
        }
    }

    # Helper: check for asynchronous notifications and job output
    my %recent_file_notifications;  # Track recent file notifications to avoid spam
    my $check_notifications = sub {
        # Handle cancel request from signal handler
        if ($SmakCli::cancel_requested) {
	    warn "DEBUG: cancel requested ($SmakCli::cancel_requested)\n" if $ENV{SMAK_DEBUG};
            if (defined $socket) {
                eval {
                    print $socket "KILL_WORKERS\n";
                    $socket->flush();
                    # Drain any pending responses
                    my $sel = IO::Select->new($socket);
                    while ($sel->can_read(0.3)) {
                        my $drain = <$socket>;
                        last unless defined $drain;
                        warn "DEBUG: drained after cancel: $drain" if $ENV{SMAK_DEBUG};
                    }
                };
            }
            # Don't clear cancel_requested here - let unified_cli handle it
            # so it knows to continue rather than exit
            print "\nCtrl-C - Cancelling ongoing builds...\n";
            STDOUT->flush();
            return -2;  # Had output, will trigger prompt redraw
        }

        my $had_output = 0;
        my $now = time();

        # Check auto-rescan watcher for file change events
        if ($watcher_socket) {
            $watcher_socket->blocking(0);
            while (my $event = <$watcher_socket>) {
                chomp $event;

                # Parse event: "OP:PID:PATH"
                if ($event =~ /^(\w+):\d+:(.+)$/) {
                    my ($op, $path) = ($1, $2);

                    if ($op eq 'DELETE' || $op eq 'MODIFY' || $op eq 'CREATE') {
                        # Mark target as stale
                        $stale_targets_cache{$path} = time();
                        # Deduplicate: only show each file change once per second
                        if (!exists $recent_file_notifications{$path} ||
                            $now - $recent_file_notifications{$path} >= 1) {
                            print "\r\033[K[auto-rescan] $path $op detected\n";
                            $recent_file_notifications{$path} = $now;
                            reprompt();
                            $had_output = 1;
                        }
                    }
                }
            }
        }

        return $had_output unless defined $socket;

        my $select = IO::Select->new($socket);

        while ($select->can_read(0)) {
            my $notif = <$socket>;
            unless (defined $notif) {
                # Socket closed - clean up
                warn "DEBUG: Socket closed in check_notifications\n" if $ENV{SMAK_DEBUG};
                $socket = undef;
                return 1;
            }
            chomp $notif;
            if ($notif =~ /^WATCH:(.+)$/) {
                my $file = $1;
                # Deduplicate: only show each file change once per second
                if (!exists $recent_file_notifications{$file} ||
                    $now - $recent_file_notifications{$file} >= 1) {
                    print "\r\033[K[File changed: $file]\n";
                    $recent_file_notifications{$file} = $now;
                    reprompt();
                    $had_output = 1;
                }
            } elsif ($notif =~ /^OUTPUT (.*)$/) {
                # Asynchronous job output
                print "\r\033[K$1\n";
                reprompt();
                $had_output = 1;
            } elsif ($notif =~ /^ERROR (.*)$/) {
                print "\r\033[KERROR: $1\n";
                reprompt();
                $had_output = 1;
            } elsif ($notif =~ /^WARN (.*)$/) {
                print "\r\033[KWARN: $1\n";
                reprompt();
                $had_output = 1;
            } elsif ($notif =~ /^JOB_COMPLETE (.+?) (\d+)$/) {
                # Asynchronous job completion notification
                my ($target, $exit_code) = ($1, $2);
                if ($exit_code == 0) {
                    print "\r\033[K[✓ Completed: $target]\n";
                } else {
                    print "\r\033[K[✗ Failed: $target (exit $exit_code)]\n";
                }
                reprompt();
                $had_output = 1;
            } elsif ($notif =~ /^WATCH_STARTED|^WATCH_/) {
                last;  # End of watch notification batch
            } elsif ($notif =~ /^STALE:|^STALE_END|^FILES_END|^TASKS_END|^PROGRESS_END/) {
                # End markers for various queries - don't display
                last;
            }
        }

        # Clean up old notification timestamps (older than 5 seconds)
        for my $file (keys %recent_file_notifications) {
            if ($now - $recent_file_notifications{$file} > 5) {
                delete $recent_file_notifications{$file};
            }
        }

        # Return whether we had output (SmakCli will redraw the line if needed)
        return $had_output;
    };

    # Create SmakCli handler with tab completion and async notification support
    my $cli = SmakCli->new(
        prompt => $prompt,
        get_prompt => sub { $busy ? "[busy]" : $prompt },
        is_busy => sub { $busy },
        socket => $socket,
        check_notifications => $check_notifications,
    );

    # Main command loop using character-by-character input with tab completion
    my $line;

    $interactive = 1;
    while (!$exit_requested && !$detached) {
        # Read line with SmakCli (handles tab completion, history, async notifications)
        $line = $cli->readline();
        unless (defined $line) {
            # EOF (Ctrl-D) or Ctrl-C
	    if ($SmakCli::cancel_requested) { # Ctrl-C
	        $SmakCli::cancel_requested = 0; # clear it
		next;  # Return to prompt, don't exit
	    }
            last;
        }

        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';

        # Handle comments (lines starting with #)
        next if $line =~ /^#/;

        # Handle shell command escape (!)
        if ($line =~ /^!(.+)$/) {
            my $shell_cmd = $1;
            $shell_cmd =~ s/^\s+//;  # Trim leading whitespace

            # Execute in sub-shell using pipe
            if (my $pid = open(my $cmd_fh, '-|', $shell_cmd . ' 2>&1')) {
                while (my $output = <$cmd_fh>) {
                    print $output;
                }
                close($cmd_fh);
                my $exit_code = $? >> 8;
                if ($exit_code != 0) {
                    print STDERR "Command exited with code $exit_code\n";
                }
            } else {
                print STDERR "Failed to execute command: $!\n";
            }
            next;
        }

        my @words = split(/\s+/, $line);
        my $cmd = shift @words;

        # Expand globs for file-oriented commands
        if ($cmd =~ /^(rm|touch|dirty|ignore)$/) {
            my @expanded;
            for my $word (@words) {
                my @matches = glob($word);
                if (@matches) {
                    push @expanded, @matches;
                } else {
                    # No matches - keep original (might be a literal filename)
                    push @expanded, $word;
                }
            }
            @words = @expanded;
        }

        # Dispatch commands
        dispatch_command($cmd, \@words, \%opts, {
            socket => \$socket,
            server_pid => \$server_pid,
            watch_enabled => \$watch_enabled,
            exit_requested => \$exit_requested,
            detached => \$detached,
            watcher_pid => \$watcher_pid,
            watcher_socket => \$watcher_socket,
        });

        # Check for async notifications that arrived during command execution
        $check_notifications->();

        # If reprompt was requested, show prompt before next readline
        # But suppress when busy (jobs running)
        if ($SmakCli::reprompt_requested) {
            $SmakCli::reprompt_requested = 0;
            unless ($busy) {
                print $prompt;
                STDOUT->flush();
            }
        }
    }

    $interactive = 0;

    # Cleanup: shutdown auto-rescan watcher if running
    if ($watcher_pid) {
        print $watcher_socket "SHUTDOWN\n" if $watcher_socket;
        waitpid($watcher_pid, 0);
        close($watcher_socket) if $watcher_socket;
    }

    # Cleanup on exit
    if ($detached) {
        # Detach was requested (explicit detach command only, not Ctrl-C)
        $SmakCli::cli_owner = -1;  # Mark CLI as unowned
        if ($own_server) {
            print "Detaching from CLI (job server $Smak::job_server_pid still running)...\n";
        } else {
            print "Detaching from job server...\n";
        }
    }
    elsif ($exit_requested) {
        # Always shut down the server when quitting (even when attached)
        if ($socket) {
            print "Shutting down job server...\n";
            print $socket "SHUTDOWN\n";
            my $ack = <$socket>;
        }
	$ret = "stop";
    }

    return $ret;
}

sub reprompt()
{
    # Send SIGWINCH to wake up readline and trigger redraw
    if ($busy) {
	$rp_pending++;
    } else {
	my $pid = $SmakCli::cli_owner;
	kill 'WINCH', $pid if ($pid >= 0);
    }
}

sub esc_expr {
    my ($x) = @_;

    if ($x =~ /\".*\"/) { # double quote for eval
	$x = "'$x'";
    }

    return $x;
}

# Command dispatcher
sub dispatch_command {
    my ($cmd, $words, $opts, $state) = @_;

    my $socket = ${$state->{socket}};
    my $server_pid = ${$state->{server_pid}};

    # Command dispatch table
    if ($cmd eq 'quit' || $cmd eq 'exit' || $cmd eq 'q') {
        ${$state->{exit_requested}} = 1;

    } elsif ($cmd eq 'detach') {
        ${$state->{detached}} = 1;

    } elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
        show_unified_help();

    } elsif ($cmd eq 'build' || $cmd eq 'b') {
        cmd_build($words, $socket, $opts, $state);

    } elsif ($cmd eq 'dry-run' || $cmd eq 'dry' || $cmd eq 'n') {
        cmd_dry_run($words, $socket);

    } elsif ($cmd eq 'rebuild') {
        cmd_rebuild($words, $socket, $opts);

    } elsif ($cmd eq 'watch' || $cmd eq 'w') {
        cmd_watch($socket, $state);

    } elsif ($cmd eq 'unwatch') {
        cmd_unwatch($socket, $state);

    } elsif ($cmd eq 'tasks' || $cmd eq 't') {
        cmd_tasks($socket);

    } elsif ($cmd eq 'status') {
        cmd_status($socket);

    } elsif ($cmd eq 'progress') {
        cmd_progress($words, $socket);

    } elsif ($cmd eq 'files' || $cmd eq 'f') {
        cmd_files($socket);

    } elsif ($cmd eq 'stale') {
        cmd_stale($socket);

    } elsif ($cmd eq 'dirty') {
        cmd_dirty($words, $socket);

    } elsif ($cmd eq 'touch') {
        cmd_touch($words, $socket);

    } elsif ($cmd eq 'rm') {
        cmd_rm($words, $socket);

    } elsif ($cmd eq 'ignore') {
        cmd_ignore($words, $socket);

    } elsif ($cmd eq 'needs') {
        cmd_needs($words, $socket);

    } elsif ($cmd eq 'list' || $cmd eq 'l') {
        cmd_list($words, $socket);

    } elsif ($cmd eq 'vars' || $cmd eq 'v') {
        cmd_vars($words, $socket);

    } elsif ($cmd eq 'deps' || $cmd eq 'd') {
        cmd_deps($words, $socket);

    } elsif ($cmd eq 'btree' || $cmd eq 'bt') {
        cmd_btree($words, $socket);

    } elsif ($cmd eq 'vpath') {
        cmd_vpath($words, $socket);

    } elsif ($cmd eq 'start') {
        cmd_start($words, $opts, $state);

    } elsif ($cmd eq 'stop') {
        cmd_stop($words, $opts, $state);

    } elsif ($cmd eq 'kill') {
        cmd_kill($socket);

    } elsif ($cmd eq 'restart') {
        cmd_restart($words, $socket, $opts);

    } elsif ($cmd eq 'auto-retry') {
        cmd_auto_retry($words, $opts, $state);

    } elsif ($cmd eq 'assume') {
        cmd_assume($words, $socket);

    } elsif ($cmd eq 'reset') {
        cmd_reset($words, $socket);

    } elsif ($cmd eq 'rescan') {
        cmd_rescan($words, $socket, $state);

    } elsif ($cmd eq 'expect') {
        cmd_expect($words);

    } elsif ($cmd eq 'eval') {
        # Evaluate Perl expression
        my $expr = "";
	my $punc = "";
	foreach my $x (@$words) {
	    $expr .= $punc.esc_expr($x); $punc=" ";
	}
        my $result = eval $expr;
        if ($@) {
            print "Error: $@\n";
        } else {
            print "$result\n" if defined $result;
        }

    } elsif ($cmd eq 'add-rule') {
        # Add a new rule to the Makefile
        if (@$words < 3) {
            print "Usage: add-rule <target> <deps> <rule>\n";
            print "  Add a new rule (rule text can use \\n and \\t)\n";
        } else {
            my ($target, $deps, $rule_text) = ($words->[0], $words->[1], join(' ', @$words[2..$#$words]));
            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;
            # Ensure each line starts with a tab (Makefile requirement)
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));
            add_rule($target, $deps, $rule_text);
            print "Added rule for '$target'\n";
        }

    } elsif ($cmd eq 'mod-rule' || $cmd eq 'modify-rule') {
        # Modify an existing rule
        if (@$words < 2) {
            print "Usage: mod-rule <target> <rule>\n";
            print "  Modify the rule for a target (rule text can use \\n and \\t)\n";
        } else {
            my ($target, $rule_text) = ($words->[0], join(' ', @$words[1..$#$words]));
            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;
            # Ensure each line starts with a tab
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));
            modify_rule($target, $rule_text);
            print "Modified rule for '$target'\n";
        }

    } elsif ($cmd eq 'mod-deps' || $cmd eq 'modify-deps') {
        # Modify dependencies for a target
        if (@$words < 2) {
            print "Usage: mod-deps <target> <deps>\n";
            print "  Modify the dependencies for a target\n";
        } else {
            my ($target, $deps) = ($words->[0], join(' ', @$words[1..$#$words]));
            modify_deps($target, $deps);
            print "Modified dependencies for '$target'\n";
        }

    } elsif ($cmd eq 'del-rule' || $cmd eq 'delete-rule') {
        # Delete a rule
        if (@$words < 1) {
            print "Usage: del-rule <target>\n";
            print "  Delete a rule for a target\n";
        } else {
            my $target = $words->[0];
            delete_rule($target);
            print "Deleted rule for '$target'\n";
        }

    } elsif ($cmd eq 'source') {
        # Execute commands from script file (nestable)
        if (@$words == 0) {
            print "Usage: source <file>\n";
            print "  Execute commands from a script file (supports nesting)\n";
        } else {
            my $script_file = $words->[0];
            # Call the execute_script_file function from main package
            # Note: This requires execute_script_file to be available
            eval {
                main::execute_script_file($script_file);
            };
            if ($@) {
                print "Error executing script: $@\n";
            }
        }

    } elsif ($cmd eq 'bench' || $cmd eq 'benchmark') {
        # Benchmark worker communication latency
        if (!$job_server_socket) {
            print "Not connected to job server. Use 'start' first.\n";
        } else {
            print $job_server_socket "BENCHMARK\n";
        }

    } else {
        print "Unknown command: $cmd (try 'help')\n";
    }

    return 0;
}

sub show_unified_help {
    print <<'HELP';
Available commands:
  build <target>      Build the specified target (or default if none given)
  dry-run <target>    Show what commands would be executed (aliases: dry, n)
  rebuild [-auto] <t> Rebuild only if stale (-auto rebuilds all matching pattern)
  watch, w            Monitor file changes from FUSE filesystem
  unwatch             Stop monitoring file changes
  tasks, t            List pending and active tasks
  status              Show job server status
  progress            Show detailed job progress
  files, f            List tracked file modifications (FUSE)
  stale               Show targets that need rebuilding (FUSE)
  rescan              Rescan timestamps and mark stale targets
  rescan -auto        Enable periodic auto-rescan (every 2s)
  rescan -noauto      Disable auto-rescan
  dirty <file>        Mark a file as out-of-date (dirty)
  touch <file>        Update file timestamp and mark dirty
  rm <file>           Remove file (saves to .{file}.prev) and mark dirty
  ignore <file>       Ignore a file for dependency checking
  ignore -none        Clear all ignored files
  ignore              List ignored files and directories
  expect <path>       Check if path exists (exit with error if not)
  needs <file>        Show which targets depend on a file
  list [pattern]      List all targets (optionally matching pattern)
  vars [pattern]      Show all variables (optionally matching pattern)
  deps <target>       Show dependencies for target
  btree [opts] [target] - Show layered build tree with status colors
                        -html[=file]    Generate HTML output (default: btree.html)
                        -launch[=browser] Open in browser (default: xdg-open)
                        Colors: green=ok, red=stale, blue=dirty
  vpath <file>        Test vpath resolution for a file
  add-rule <t> <d> <r> Add a new rule (rule text can use \n and \t)
  mod-rule <t> <r>    Modify the rule for a target
  mod-deps <t> <d>    Modify the dependencies for a target
  del-rule <t>        Delete a rule for a target
  start [N]           Start job server with N workers (if not running)
  kill                Kill all workers
  restart [N]         Restart workers (optionally specify count)
  bench, benchmark    Benchmark worker communication latency
  detach              Detach from CLI, leave job server running
  help, h, ?          Show this help
  quit, exit, q       Exit CLI (shuts down server if owned, else disconnects)
  ! <command>         Execute shell command in sub-shell
  eval <expr>         Evaluate Perl expression
  source <file>       Execute commands from file (nestable)

Keyboard shortcuts:
  Ctrl-C              Cancel ongoing builds and return to prompt
  Ctrl-D              EOF - exits CLI (same as 'quit')

Behavior notes:
  - 'quit' always shuts down the job server (even when attached)
  - 'detach' disconnects from CLI but leaves job server running
  - Ctrl-C cancels running builds without exiting the CLI
  - Lines starting with '#' are treated as comments and ignored

Examples:
  build all           Build the 'all' target
  build               Build the default target
  rebuild -auto *.o   Rebuild all stale .o files
  list task           List targets matching 'task'
  deps foo.o          Show dependencies for foo.o
  expect build/out    Check if build/out exists (error if not)
  watch               Enable file change monitoring
  restart 8           Restart workers with 8 workers
HELP
}

sub enable_cli {
    my ($yes) = @_;
    $SmakCli::enabled = $yes && ! $busy; 
}

# Command handlers - work in both standalone and attached modes

sub cmd_build {
    my ($words, $socket, $opts, $state) = @_;

    $busy = 1;

    my @targets = @$words;
    if (@targets == 0) {
        # Build default target
        my $default = get_default_target();
        if ($default) {
            @targets = ($default);
            print "Building default target: $default\n";
        } else {
            print "No default target found.\n";
            $busy = 0;
            return;
        }
    }

    if ($socket) {
        # Job server mode - submit jobs and wait for completion
        $job_server_socket = $socket unless $job_server_socket;

        use IO::Select;
        use Cwd 'getcwd';
        my $cwd = getcwd();

        for my $target (@targets) {
            my $build_start_time = time();

            # Submit the job to job server
            print $socket "SUBMIT_JOB\n";
            print $socket "$target\n";
            print $socket "$cwd\n";
            print $socket "true\n";  # Composite target placeholder
            $socket->flush();

            # Wait for job completion, processing output as it arrives
            my $select = IO::Select->new($socket);
            my $job_done = 0;
            my $cancelled = 0;
            my $exit_code = 0;
            my $timeout = 300;  # 5 minute timeout
            my $deadline = time() + $timeout;

            while (!$job_done && !$cancelled && time() < $deadline) {
                # Check for Ctrl-C cancel request
                if ($SmakCli::cancel_requested) {
                    print "\nCtrl-C - Cancelling build...\n";
                    print $socket "KILL_WORKERS\n";
                    $socket->flush();
                    $SmakCli::cancel_requested = 0;
                    $cancelled = 1;
                    # Drain socket to clear pending messages
                    while ($select->can_read(0.3)) {
                        my $drain = <$socket>;
                        last unless defined $drain;
                    }
                    last;
                }

                # Process messages from job server
                if ($select->can_read(0.1)) {
                    my $response = <$socket>;
                    unless (defined $response) {
                        print "Connection to job server lost\n";
                        last;
                    }
                    chomp $response;

                    if ($response =~ /^OUTPUT (.*)$/) {
                        print "$1\n";
                    } elsif ($response =~ /^ERROR (.*)$/) {
                        print STDERR "ERROR: $1\n";
                    } elsif ($response =~ /^WARN (.*)$/) {
                        print STDERR "WARN: $1\n";
                    } elsif ($response =~ /^JOB_COMPLETE\s+(\S+)\s+(\d+)$/) {
                        my ($completed_target, $code) = ($1, $2);
                        # Stop when we get completion for our requested target
                        # Use flexible matching: exact match, or target at end of path
                        if ($completed_target eq $target ||
                            $completed_target =~ /(?:^|\/)$target$/) {
                            $job_done = 1;
                            $exit_code = $code;
                        }
                    } elsif ($response =~ /^IDLE\s+(\d+)\s+([\d.]+)$/) {
                        # IDLE means all work is complete
                        my ($idle_exit, $idle_time) = ($1, $2);
                        # Only accept IDLE from after we started this build
                        if ($idle_time >= $build_start_time) {
                            $job_done = 1;
                            $exit_code = $idle_exit;
                        }
                    }
                }
            }

            # Handle timeout
            if (!$job_done && !$cancelled && time() >= $deadline) {
                print STDERR "Build timed out after ${timeout}s\n";
                $exit_code = 1;
            }

            my $elapsed = time() - $build_start_time;
            if ($cancelled) {
                print "Build cancelled\n";
                last;
            } elsif ($exit_code != 0) {
                printf "✗ Build failed: $target (%.2fs)\n", $elapsed;
                last;
            } else {
                printf "✓ Build succeeded: $target (%.2fs)\n", $elapsed;
            }
        }
    } else {
        # No job server - build sequentially
        print "(Building in sequential mode - use 'start' for parallel builds)\n";
        for my $target (@targets) {
            my $build_start_time = time();
            eval {
                build_target($target);
            };
            my $elapsed = time() - $build_start_time;
            if ($@) {
                printf "✗ Build failed: $target (%.2fs)\n", $elapsed;
                print STDERR $@;
                last;
            } else {
                printf "✓ Build succeeded: $target (%.2fs)\n", $elapsed;
            }
        }
    }

    $busy = 0;
}

sub cmd_dry_run {
    my ($words, $socket) = @_;

    my @targets = @$words;
    if (@targets == 0) {
        my $default = get_default_target();
        if ($default) {
            @targets = ($default);
            print "Dry-run for default target: $default\n";
        } else {
            print "No default target found.\n";
            print "Usage: dry-run <target>\n";
            return;
        }
    }

    # Fork a child process for dry-run so state changes are discarded
    # This prevents polluting the job-server's state
    my $pid = fork();
    if (!defined $pid) {
        print STDERR "Error: fork failed: $!\n";
        return;
    }

    if ($pid == 0) {
        # Child process - run dry-run and exit
        for my $target (@targets) {
            print "Commands that would be executed for: $target\n";
            print "-" x 60 . "\n";
            eval {
                dry_run_target($target);
            };
            if ($@) {
                print STDERR "Error: $@\n";
            }
            print "-" x 60 . "\n";
        }
        STDOUT->flush();
        exit(0);  # Exit child - state changes are discarded
    } else {
        # Parent process - wait for child to complete
        waitpid($pid, 0);
    }
}

sub cmd_rebuild {
    my ($words, $socket, $opts) = @_;

    if (!$socket) {
        print "Job server not running. Use 'start' to enable.\n";
        return;
    }

    # Check for -auto flag
    my $auto = 0;
    my @targets;
    for my $word (@$words) {
        if ($word eq '-auto') {
            $auto = 1;
        } else {
            push @targets, $word;
        }
    }

    if (@targets == 0) {
        print "Usage: rebuild [-auto] <target|pattern>\n";
        print "  -auto: Automatically rebuild stale targets matching pattern\n";
        return;
    }

    if ($auto) {
        # Auto mode: find and rebuild all stale targets matching the pattern
        my $pattern = $targets[0];

        # Expand glob pattern to find matching files
        my @matching_files = glob($pattern);

        if (@matching_files == 0) {
            print "No files match pattern '$pattern'\n";
            return;
        }

        # Check which ones are stale
        my @stale_targets;
        for my $file (@matching_files) {
            print $socket "IS_STALE:$file\n";
            my $response = <$socket>;
            if ($response && $response =~ /^STALE:yes/) {
                push @stale_targets, $file;
            }
        }

        if (@stale_targets == 0) {
            print "No stale targets found matching '$pattern'\n";
            return;
        }

        print "Found " . scalar(@stale_targets) . " stale target(s), rebuilding...\n";
        for my $target (@stale_targets) {
            print "Rebuilding $target...\n";
            cmd_build([$target], $socket, $opts, {exit_requested => \0});
        }
    } else {
        # Normal mode: rebuild single target
        my $target = $targets[0];
        print $socket "IS_STALE:$target\n";
        my $response = <$socket>;
        if ($response && $response =~ /^STALE:yes/) {
            print "Target '$target' is stale, rebuilding...\n";
            cmd_build([$target], $socket, $opts, {exit_requested => \0});
        } elsif ($response && $response =~ /^STALE:no/) {
            print "Target '$target' is up-to-date, skipping rebuild.\n";
        } else {
            print "Could not determine if target is stale.\n";
        }
    }
}

sub cmd_watch {
    my ($socket, $state) = @_;

    if (!$socket) {
        print "Job server not running. Use 'start' to enable.\n";
        return;
    }

    # Check if socket is still connected
    if (!$socket->connected()) {
        print "Connection to job server lost. Use 'start' to reconnect.\n";
        ${$state->{socket}} = undef;
        return;
    }

    print $socket "WATCH_START\n";
    $socket->flush();

    # Wait for response from job server
    my $response = <$socket>;
    if ($response) {
        chomp $response;
        if ($response eq 'WATCH_STARTED') {
            ${$state->{watch_enabled}} = 1;
            print "Watch mode enabled (FUSE file change notifications active)\n";
        } elsif ($response =~ /^WATCH_UNAVAILABLE/) {
            print "Watch mode unavailable: $response\n";
            print "FUSE filesystem monitoring is not available.\n";
            print "File changes will not be detected automatically.\n";
        } else {
            print "Unexpected response: $response\n";
        }
    } else {
        print "No response from job server (connection lost)\n";
        print "Use 'start' to reconnect or 'quit' to exit.\n";
        ${$state->{socket}} = undef;
    }
}

sub cmd_unwatch {
    my ($socket, $state) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    print $socket "WATCH_STOP\n";
    ${$state->{watch_enabled}} = 0;
    print "Watch mode disabled\n";
}

sub cmd_tasks {
    my ($socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    print $socket "LIST_TASKS\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'TASKS_END';
        print "$response\n";
    }
}

sub cmd_status {
    my ($socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    print $socket "STATUS\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'STATUS_END';
        next if $response eq 'STATUS_START';  # Skip start marker
        print "$response\n";
    }
}

sub cmd_progress {
    my ($words, $socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $op = join(' ', @$words);
    print $socket "IN_PROGRESS $op\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'PROGRESS_END';
        print "$response\n";
    }
}

sub cmd_files {
    my ($socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    print $socket "LIST_FILES\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'FILES_END';
        print "$response\n";
    }
}

sub cmd_stale {
    my ($socket) = @_;

    if ($socket) {
        # Job server running - use full FUSE-based stale detection
        print $socket "LIST_STALE\n";
        my $count = 0;
        while (my $response = <$socket>) {
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
            my $label = $count == 1 ? "target" : "targets";
            print "\n$count $label need rebuilding\n";
        }
    } else {
        # No job server - show targets from stale cache and dirty files
        my $found_stale = 0;

        if (keys %Smak::stale_targets_cache) {
            print "Stale targets (need rebuilding):\n";
            for my $target (sort keys %Smak::stale_targets_cache) {
                print "  $target\n";
            }
            print "\n" . (scalar keys %Smak::stale_targets_cache) . " stale target(s)\n";
            $found_stale = 1;
        }

        if (keys %Smak::dirty_files) {
            print "\nFiles marked dirty:\n";
            for my $file (sort keys %Smak::dirty_files) {
                print "  $file\n";
            }
            print "\n" . (scalar keys %Smak::dirty_files) . " file(s) marked dirty\n";
            $found_stale = 1;
        }

        if (!$found_stale) {
            print "No stale targets (nothing needs rebuilding)\n";
        }
        print "\n(Use 'start' to enable file change monitoring via FUSE)\n";
    }
}

sub cmd_dirty {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: dirty <file>\n";
        print "  Marks a file as out-of-date (dirty)\n";
        return;
    }

    my $file = $words->[0];

    if ($socket) {
        # Job server running - send command via socket
        print $socket "MARK_DIRTY:$file\n";
    } else {
        # No job server - modify global %dirty_files directly
        $Smak::dirty_files{$file} = 1;
    }

    print "Marked '$file' as dirty (out-of-date)\n";
}

sub cmd_touch {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: touch <file> [<file2> ...]\n";
        print "  Updates file timestamps and marks as dirty for rebuild\n";
        return;
    }

    for my $file (@$words) {
        # Touch the file (create if doesn't exist, update timestamp if it does)
        if (-e $file) {
            # Update timestamp
            my $now = time();
            utime($now, $now, $file) or warn "Failed to touch '$file': $!\n";
            print "Updated timestamp: $file\n";
        } else {
            # Create empty file
            if (open(my $fh, '>', $file)) {
                close($fh);
                print "Created: $file\n";
            } else {
                warn "Failed to create '$file': $!\n";
                next;
            }
        }

        # Mark as dirty so targets that depend on it will rebuild
        if ($socket) {
            print $socket "MARK_DIRTY:$file\n";
        } else {
            $Smak::dirty_files{$file} = 1;
        }
    }
}

sub cmd_rm {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: rm <file> [<file2> ...]\n";
        print "  Removes files (moves to .{file}.prev for comparison) and marks dirty\n";
        return;
    }

    for my $file (@$words) {
        unless (-e $file) {
            print "File not found: $file\n";
            next;
        }

        # Generate backup filename: .{basename}.prev in same directory
        my $backup = $file;
        $backup =~ s{([^/]+)$}{.$1.prev};

        # Move file to backup
        if (rename($file, $backup)) {
            print "Removed: $file (saved as $backup)\n";
        } else {
            warn "Failed to remove '$file': $!\n";
            next;
        }

        # Mark as dirty so targets that depend on it will rebuild
        if ($socket) {
            print $socket "MARK_DIRTY:$file\n";
        } else {
            $Smak::dirty_files{$file} = 1;
        }
    }
}

sub cmd_ignore {
    my ($words, $socket) = @_;

    # Special handling for -none to clear all ignored files
    if (@$words == 1 && $words->[0] eq '-none') {
        %Smak::ignored_files = ();
        print "Cleared all ignored files\n";
        return;
    }

    # List ignored files if no arguments
    if (@$words == 0) {
        # Show ignored directories from SMAK_IGNORE_DIRS
        if (@Smak::ignore_dirs) {
            print "Ignored directories (from SMAK_IGNORE_DIRS):\n";
            for my $dir (sort @Smak::ignore_dirs) {
                my $status = "";
                if (exists $Smak::ignore_dir_mtimes{$dir}) {
                    $status = " (mtime=" . $Smak::ignore_dir_mtimes{$dir} . ")";
                } else {
                    $status = " (not found)";
                }
                print "  $dir$status\n";
            }
            print "\n" . (scalar @Smak::ignore_dirs) . " director(ies) ignored\n\n";
        } else {
            print "No ignored directories (set SMAK_IGNORE_DIRS to ignore system directories)\n\n";
        }

        # Show ignored files
        if (keys %Smak::ignored_files) {
            print "Ignored files:\n";
            for my $file (sort keys %Smak::ignored_files) {
                print "  $file\n";
            }
            print "\n" . (scalar keys %Smak::ignored_files) . " file(s) ignored\n";
        } else {
            print "No files are currently ignored\n";
        }
        print "\nUsage: ignore <file>    - Ignore a file for dependency checking\n";
        print "       ignore -none     - Clear all ignored files\n";
        print "       Set SMAK_IGNORE_DIRS environment variable to ignore directories\n";
        return;
    }

    # Mark file as ignored
    my $file = $words->[0];
    $Smak::ignored_files{$file} = 1;
    print "Ignoring '$file' for dependency checking\n";
    print "Targets depending on this file will not be rebuilt based on its timestamp\n";
}

sub cmd_assume {
    my ($words, $socket) = @_;

    # List assumed targets if no arguments
    if (@$words == 0) {
        if (keys %Smak::assumed_targets) {
            print "Assumed targets (marked as already built):\n";
            for my $target (sort keys %Smak::assumed_targets) {
                print "  $target\n";
            }
            print "\n" . (scalar keys %Smak::assumed_targets) . " target(s) assumed\n";
        } else {
            print "No targets are currently assumed\n";
        }
        print "\nUsage: assume <target>  - Mark target as already built (skip building it)\n";
        print "       assume -clear    - Clear all assumed targets\n";
        return;
    }

    if ($words->[0] eq '-clear') {
        %Smak::assumed_targets = ();
        print "Cleared all assumed targets\n";
        return;
    }

    # Mark target as assumed (already built)
    my $target = $words->[0];
    $Smak::assumed_targets{$target} = 1;
    print "Assuming target '$target' is already built\n";
    print "This target will be treated as satisfied even if it doesn't exist\n";
}

sub cmd_reset {
    my ($words, $socket) = @_;

    if ($socket) {
        # Job server running - send reset command
        print "Resetting build state...\n";
        print $socket "RESET\n";
        my $response = <$socket>;
        chomp $response if $response;
        print "$response\n" if $response;
    } else {
        print "Job server not running. Build state cleared.\n";
    }
}

sub cmd_rescan {
    my ($words, $socket, $state) = @_;

    my $auto = 0;
    my $noauto = 0;
    if (@$words > 0 && $words->[0] eq '-auto') {
        $auto = 1;
    } elsif (@$words > 0 && $words->[0] eq '-noauto') {
        $noauto = 1;
    }

    if ($socket) {
        # Job server running - send rescan command
        print "Rescanning timestamps...\n" unless ($auto || $noauto);
        my $cmd = $auto ? "RESCAN_AUTO\n" : $noauto ? "RESCAN_NOAUTO\n" : "RESCAN\n";
        print $socket $cmd;
        my $response = <$socket>;
        chomp $response if $response;
        print "$response\n" if $response;
    } else {
        # Job server not running
        if ($auto) {
            # Enable auto-rescan with background watcher (no job server needed)
            my $watcher_pid_ref = $state->{watcher_pid} if $state;
            my $watcher_socket_ref = $state->{watcher_socket} if $state;

            if ($watcher_pid_ref && $watcher_socket_ref) {
                my $watcher_pid = $$watcher_pid_ref;
                if (!$watcher_pid) {
                    # Create socketpair for bidirectional communication
                    use Socket;
                    socketpair(my $parent_sock, my $child_sock, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
                        or die "socketpair failed: $!";

                    $parent_sock->autoflush(1);
                    $child_sock->autoflush(1);

                    $watcher_pid = fork();
                    die "fork failed: $!" unless defined $watcher_pid;

                    if ($watcher_pid == 0) {
                        # Child process - run watcher
                        close($parent_sock);
                        auto_rescan_watcher($child_sock, \$makefile);
                        exit 0;  # Should never reach here
                    } else {
                        # Parent process - keep parent socket
                        close($child_sock);
                        $$watcher_pid_ref = $watcher_pid;
                        $$watcher_socket_ref = $parent_sock;
                        print "Auto-rescan enabled (background watcher PID $watcher_pid)\n";
                    }
                } else {
                    print "Auto-rescan already enabled (PID $watcher_pid)\n";
                }
            } else {
                # No state tracking available - fall back to message
                if ($ENV{SMAK_FUSE_DETECTED}) {
                    print "Note: Auto-rescan is disabled on FUSE filesystems (use 'unwatch' then 'rescan -auto' if needed)\n";
                } else {
                    print "Auto-rescan enabled (will activate when job server starts)\n";
                }
            }
        } elsif ($noauto) {
            # Disable auto-rescan and shutdown watcher
            my $watcher_pid_ref = $state->{watcher_pid} if $state;
            my $watcher_socket_ref = $state->{watcher_socket} if $state;

            if ($watcher_pid_ref && $watcher_socket_ref) {
                my $watcher_pid = $$watcher_pid_ref;
                my $watcher_socket = $$watcher_socket_ref;
                if ($watcher_pid) {
                    print $watcher_socket "SHUTDOWN\n" if $watcher_socket;
                    waitpid($watcher_pid, 0);
                    close($watcher_socket) if $watcher_socket;
                    $$watcher_pid_ref = undef;
                    $$watcher_socket_ref = undef;
                    print "Auto-rescan disabled.\n";
                } else {
                    print "Auto-rescan not running.\n";
                }
            } else {
                print "Auto-rescan disabled\n";
            }
        } else {
            # Basic rescan - just note that job server is needed for full functionality
            print "Job server not running. Start with -j option for full rescan functionality.\n";
        }
    }
}

sub cmd_expect {
    my ($words) = @_;

    if (@$words == 0) {
        print "Usage: expect <path>\n";
        print "  Checks if path exists. Exits with error code 1 if not found.\n";
        return;
    }

    my $path = $words->[0];
    unless (-e $path) {
        print STDERR "ERROR: Expected path not found: $path\n";
        exit(1);
    }

    print "Path exists: $path\n";
}

sub cmd_needs {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: needs <file>\n";
        print "  Shows which targets depend on the specified file\n";
        return;
    }

    my $file = $words->[0];

    if ($socket) {
        # Job server running - use socket protocol
        print $socket "NEEDS:$file\n";
        $socket->flush() if $socket->can('flush');

        my $count = 0;
        my $got_end = 0;
        while (my $response = <$socket>) {
            chomp $response;
            if ($response eq 'NEEDS_END') {
                $got_end = 1;
                last;
            }
            if ($response =~ /^NEEDS:(.+)$/) {
                print "  $1\n";
                $count++;
            }
        }
        print "\n$count target(s) depend on '$file'\n" if $got_end;
    } else {
        # No job server - search dependencies directly
        use Cwd 'getcwd';
        use File::Basename;
        my $cwd = getcwd();

        my @reverse_deps;
        my $file_basename = basename($file);

        # Search through all dependency types
        for my $dep_hash (\%fixed_deps, \%pattern_deps, \%pseudo_deps) {
            for my $key (keys %$dep_hash) {
                # Key format: "Makefile\ttarget"
                next unless $key =~ /^[^\t]+\t(.+)$/;
                my $target = $1;

                my @deps = @{$dep_hash->{$key} || []};

                # Expand variables in dependencies
                @deps = map {
                    my $dep = $_;
                    while ($dep =~ /\$MV\{([^}]+)\}/) {
                        my $var = $1;
                        my $val = $MV{$var} // '';
                        $dep =~ s/\$MV\{\Q$var\E\}/$val/;
                    }
                    if ($dep =~ /\s/) {
                        split /\s+/, $dep;
                    } else {
                        $dep;
                    }
                } @deps;
                @deps = grep { $_ ne '' } @deps;

                # Apply vpath resolution
                @deps = map { resolve_vpath($_, $cwd) } @deps;

                # Check if file is in dependencies (match exact, basename, or suffix)
                for my $dep (@deps) {
                    # Try exact match, basename match, or suffix match
                    if ($dep eq $file ||
                        basename($dep) eq $file_basename ||
                        $dep =~ /\Q$file\E$/) {
                        push @reverse_deps, $target;
                        last;
                    }
                }
            }
        }

        # Also check targets by pattern (e.g., foo.C -> foo.C.o or foo.o)
        if ($file =~ /^(.+)\.(c|cc|cpp|C|cxx|c\+\+)$/) {
            my $base = $1;
            my $ext = $2;

            # Search all targets for those matching the source file pattern
            for my $dep_hash (\%fixed_deps, \%fixed_rule, \%pattern_deps, \%pattern_rule) {
                for my $key (keys %$dep_hash) {
                    next unless $key =~ /^[^\t]+\t(.+)$/;
                    my $target = $1;

                    # Check if target looks like it's built from this source
                    # Match patterns: foo.C.o, foo.o, */foo.C.o, */foo.o
                    if ($target =~ /\Q$file\E\.o$/ ||                        # foo.C.o
                        $target =~ /\Q$base\E\.o$/ ||                         # foo.o
                        basename($target) eq "$file.o" ||                     # basename/foo.C.o
                        basename($target) eq "$base.o") {                     # basename/foo.o
                        push @reverse_deps, $target unless grep { $_ eq $target } @reverse_deps;
                    }
                }
            }
        }

        if (@reverse_deps) {
            print "Targets that depend on '$file':\n";
            for my $target (sort @reverse_deps) {
                print "  $target\n";
            }
            print "\n" . (scalar @reverse_deps) . " target(s) depend on '$file'\n";
        } else {
            print "No targets depend on '$file'\n";
        }
    }
}

sub cmd_list {
    my ($words, $socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $pattern = @$words > 0 ? $words->[0] : '';
    print $socket "LIST_TARGETS $pattern\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'TARGETS_END';
        print "$response\n";
    }
}

sub cmd_vars {
    my ($words, $socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $pattern = @$words > 0 ? $words->[0] : '';
    print $socket "LIST_VARS $pattern\n";
    while (my $response = <$socket>) {
        chomp $response;
        last if $response eq 'VARS_END';
        print "$response\n";
    }
}

sub cmd_deps {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: deps <target>\n";
        return;
    }

    my $target = $words->[0];

    if ($socket) {
        # Job server running - use socket protocol
        print $socket "SHOW_DEPS $target\n";
        while (my $response = <$socket>) {
            chomp $response;
            last if $response eq 'DEPS_END';
            print "$response\n";
        }
    } else {
        # No job server - call show_dependencies directly
        show_dependencies($target);
    }
}

sub cmd_btree {
    my ($words, $socket) = @_;

    # Parse options: btree [-html[=file]] [-launch[=browser]] [target]
    my $html_file;
    my $launch_browser;
    my $target;

    for my $arg (@$words) {
        if ($arg =~ /^-html(?:=(.+))?$/) {
            $html_file = $1 // 'btree.html';
        } elsif ($arg =~ /^-launch(?:=(.+))?$/) {
            $launch_browser = $1 // 'xdg-open';
            $html_file //= 'btree.html';  # -launch implies -html
        } elsif (!defined $target) {
            $target = $arg;
        }
    }

    if (!defined $target) {
        $target = get_default_target();
        if (!defined $target) {
            print "No default target defined.\n";
            print "Usage: btree [-html[=file]] [-launch[=browser]] [target]\n";
            return;
        }
        print "Using default target: $target\n";
    }

    # First, invoke a dry-run to gather all build rules including subdirectory targets
    # This populates the rule tables with targets from recursive make -C calls
    my %captured_info;
    {
        # Use parent PID for temp file name so both processes use the same file
        my $parent_pid = $$;
        my $capture_file = "/tmp/btree_capture_${parent_pid}.dat";

        # Run dry-run in a fork to avoid side effects
        my $pid = fork();
        if (!defined $pid) {
            print "Cannot fork for dry-run: $!\n";
            return;
        }

        if ($pid == 0) {
            # Child process: run dry-run with capture
            # Redirect stdout to /dev/null to suppress command output
            open(my $old_stdout, '>&', \*STDOUT);
            open(STDOUT, '>', '/dev/null');

            eval {
                dry_run_target($target, {}, 0, { capture => \%captured_info, no_commands => 1 });
            };

            # Restore stdout
            open(STDOUT, '>&', $old_stdout);

            # Write captured info to temp file for parent to read
            use Storable;
            Storable::nstore(\%captured_info, $capture_file);
            exit(0);
        } else {
            # Parent: wait for child and read captured data
            waitpid($pid, 0);
            if (-f $capture_file) {
                use Storable;
                my $ref = Storable::retrieve($capture_file);
                %captured_info = %$ref if $ref;
                unlink($capture_file);
            }
        }
    }

    print "Captured " . scalar(keys %captured_info) . " targets from dry-run\n" if %captured_info;

    # Build dependency tree using cached rule tables
    # Rules are cached and only reparsed when makefiles change
    my %all_targets;   # target => [deps]
    my %target_info;   # target => { rule, exec_dir, siblings, compound_parent }
    my %visited;

    # Merge captured info from dry-run
    for my $tgt (keys %captured_info) {
        $all_targets{$tgt} = $captured_info{$tgt}{deps} || [];
        $target_info{$tgt} = {
            rule => $captured_info{$tgt}{rule} || '',
            exec_dir => $captured_info{$tgt}{exec_dir} || '.',
            siblings => $captured_info{$tgt}{siblings} || [],
            compound_parent => $captured_info{$tgt}{compound_parent} || '',
        };
        $visited{$tgt} = 1;
    }

    # Helper to get all dependencies for a target (uses cached rule tables)
    my $get_target_data;
    $get_target_data = sub {
        my ($tgt, $depth) = @_;
        $depth //= 0;
        return if $visited{$tgt}++ || $depth > 100;

        my $key = "$makefile\t$tgt";
        my @deps;
        my $rule = '';
        my $stem = '';
        my @siblings;

        # Check fixed rules first
        if (exists $fixed_deps{$key}) {
            @deps = @{$fixed_deps{$key} || []};
            $rule = $fixed_rule{$key} || '';
        }

        # Try pattern rules if no fixed rule
        if (!$rule || $rule !~ /\S/) {
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($tgt =~ /^$pattern_re$/) {
                        $stem = $1;
                        my $deps_ref = $pattern_deps{$pkey} || [];
                        my $rule_ref = $pattern_rule{$pkey} || '';

                        # Get deps (expand stem)
                        my @pdeps = (ref($deps_ref) eq 'ARRAY' && ref($deps_ref->[0]) eq 'ARRAY') ?
                                    @{$deps_ref->[0]} : (ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ());
                        @pdeps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @pdeps;
                        push @deps, @pdeps;

                        $rule = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[0] : $rule_ref;
                        $rule =~ s/\$\*/$stem/g if $stem;

                        # Check for multi-output siblings
                        my ($mf_part, $pattern_part) = split(/\t/, $pkey, 2);
                        my $target_key = "$makefile\t$pattern_part";
                        if (exists $multi_output_siblings{$target_key}) {
                            @siblings = map { my $s = $_; $s =~ s/%/$stem/g; $s } @{$multi_output_siblings{$target_key}};
                        }
                        last;
                    }
                }
            }
        }

        # Check pseudo rules
        if (!$rule && exists $pseudo_deps{$key}) {
            @deps = @{$pseudo_deps{$key} || []};
            $rule = $pseudo_rule{$key} || '';
        }

        # Add order-only deps
        if (exists $fixed_order_only{$key}) {
            push @deps, @{$fixed_order_only{$key} || []};
        }

        # Expand variables in deps
        @deps = map {
            my $d = $_;
            while ($d =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $d =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            split(/\s+/, $d);
        } @deps;
        @deps = grep { defined $_ && /\S/ && !/dirstamp$/ && !/\.deps\// && !m{^/usr/} } @deps;

        # Determine exec_dir from target path
        my $exec_dir = '.';
        if ($tgt =~ m{^(.+)/[^/]+$}) {
            $exec_dir = $1;
        }

        # Store target info
        $all_targets{$tgt} = \@deps;
        $target_info{$tgt} = {
            rule => $rule,
            exec_dir => $exec_dir,
            siblings => \@siblings,
            compound_parent => '',
        };

        # Handle compound targets
        if (@siblings > 1) {
            my $compound = join('&', sort @siblings);
            $all_targets{$compound} = \@deps;
            (my $siblings_str = $compound) =~ s/&/ /g;
            $target_info{$compound} = {
                rule => $rule,
                exec_dir => $exec_dir,
                siblings => \@siblings,
                compound_parent => '',
                post_build => "check-siblings $siblings_str",
            };
            # Mark ALL siblings (including current target) as built by compound
            for my $sib (@siblings) {
                $target_info{$sib} = {
                    rule => "(built by $compound)",
                    exec_dir => $exec_dir,
                    siblings => [],
                    compound_parent => $compound,
                };
                $all_targets{$sib} = [$compound];  # Sibling depends on compound
            }
        }

        # Recurse into dependencies
        for my $dep (@deps) {
            $get_target_data->($dep, $depth + 1);
        }
    };

    # Collect from root target
    $get_target_data->($target, 0);

    print "Collected " . scalar(keys %all_targets) . " targets from cached rules\n";
    my %tgt_layer;  # target => layer

    # Compute layers: layer = max(layer of deps) + 1
    my $compute;
    $compute = sub {
        my ($tgt) = @_;
        return $tgt_layer{$tgt} if exists $tgt_layer{$tgt};

        my $deps = $all_targets{$tgt} || [];
        if (@$deps == 0) {
            return $tgt_layer{$tgt} = 0;
        }

        my $max = -1;
        for my $d (@$deps) {
            next unless exists $all_targets{$d};
            my $l = $compute->($d);
            $max = $l if $l > $max;
        }
        return $tgt_layer{$tgt} = $max + 1;
    };
    $compute->($_) for keys %all_targets;

    # Group by layer
    my @layers;
    my $max_layer = 0;
    for my $tgt (keys %tgt_layer) {
        my $l = $tgt_layer{$tgt};
        $layers[$l] //= [];
        push @{$layers[$l]}, $tgt;
        $max_layer = $l if $l > $max_layer;
    }

    if (@layers == 0) {
        print "No buildable targets for: $target\n";
        return;
    }

    # Helper to get target status: 'ok' (green), 'stale' (red), 'dirty' (blue)
    my $get_status = sub {
        my ($tgt) = @_;
        # Check if marked dirty
        if (exists $stale_targets_cache{$tgt}) {
            return 'dirty';
        }
        # Check if file exists and is up-to-date
        if (-e $tgt) {
            my $tgt_mtime = (stat($tgt))[9];
            my $deps = $all_targets{$tgt} || [];
            for my $dep (@$deps) {
                if (-e $dep) {
                    my $dep_mtime = (stat($dep))[9];
                    if ($dep_mtime > $tgt_mtime) {
                        return 'stale';
                    }
                }
            }
            return 'ok';
        }
        return 'stale';  # Doesn't exist, needs building
    };

    # ANSI color codes
    my %colors = (
        ok    => "\033[32m",  # green
        stale => "\033[31m",  # red
        dirty => "\033[34m",  # blue
        reset => "\033[0m",
    );

    # Get target info for HTML - use captured data from dry-run, fall back to static tables
    my $get_target_info = sub {
        my ($tgt) = @_;
        my $key = "$makefile\t$tgt";
        my %info = (target => $tgt);

        # Use captured data from dry-run if available (has properly expanded rules)
        if (exists $target_info{$tgt}) {
            $info{rule} = $target_info{$tgt}{rule};
            $info{exec_dir} = $target_info{$tgt}{exec_dir} || '.';
            $info{siblings} = $target_info{$tgt}{siblings} || [];
            $info{compound_parent} = $target_info{$tgt}{compound_parent} || '';
            $info{post_build} = $target_info{$tgt}{post_build} || '';
        } else {
            # Fall back to static rule tables
            if (exists $fixed_rule{$key}) {
                $info{rule} = $fixed_rule{$key};
            } elsif (exists $pattern_rule{$key}) {
                my $rule_ref = $pattern_rule{$key};
                $info{rule} = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[0] : $rule_ref;
            }

            # Derive exec_dir from target path
            if ($tgt =~ m{^(.+)/[^/]+$}) {
                $info{exec_dir} = $1;
            } else {
                $info{exec_dir} = '.';
            }
        }

        # Get deps from dry-run capture
        $info{deps} = $all_targets{$tgt} || [];

        # File info
        if (-e $tgt) {
            my @stat = stat($tgt);
            $info{exists} = 1;
            $info{mtime} = $stat[9];
            $info{size} = $stat[7];
        } else {
            $info{exists} = 0;
        }

        # Post-build hook (use local target_info first, fall back to global)
        $info{post_build} //= $post_build{$tgt} // '';

        return \%info;
    };

    # Generate HTML output
    if ($html_file) {
        open(my $fh, '>', $html_file) or do {
            print "Cannot write to $html_file: $!\n";
            return;
        };

        print $fh <<'HTML_HEAD';
<!DOCTYPE html>
<html>
<head>
<title>Build Tree</title>
<style>
body { font-family: monospace; margin: 20px; background: #1e1e1e; color: #d4d4d4; }
h1, h2 { color: #569cd6; }
.layer { margin: 20px 0; padding: 10px; border: 1px solid #3c3c3c; border-radius: 5px; }
.layer-title { font-weight: bold; color: #dcdcaa; margin-bottom: 10px; }
.target { padding: 5px 10px; margin: 2px 0; cursor: pointer; border-radius: 3px; }
.target:hover { background: #2d2d2d; }
.ok { color: #4ec9b0; }
.stale { color: #f14c4c; }
.dirty { color: #569cd6; }
.indicator { color: #808080; margin-right: 5px; }
.info-panel { display: none; position: fixed; top: 50px; right: 20px; width: 400px;
              background: #252526; border: 1px solid #3c3c3c; border-radius: 5px;
              padding: 15px; max-height: 80vh; overflow-y: auto; }
.info-panel.visible { display: block; }
.info-panel h3 { color: #dcdcaa; margin-top: 0; }
.info-panel pre { background: #1e1e1e; padding: 10px; border-radius: 3px;
                  overflow-x: auto; white-space: pre-wrap; }
.info-panel .label { color: #569cd6; }
.close-btn { float: right; cursor: pointer; color: #808080; }
.close-btn:hover { color: #d4d4d4; }
.legend { margin-bottom: 20px; }
.legend span { margin-right: 20px; }
</style>
</head>
<body>
<h1>Build Tree: TARGET_PLACEHOLDER</h1>
<div class="legend">
  <span class="ok">&#9679; OK (up-to-date)</span>
  <span class="stale">&#9679; Stale (needs rebuild)</span>
  <span class="dirty">&#9679; Dirty (marked for rebuild)</span>
</div>
<div id="info-panel" class="info-panel">
  <span class="close-btn" onclick="hideInfo()">&times;</span>
  <h3 id="info-target"></h3>
  <div id="info-content"></div>
</div>
HTML_HEAD

        # Close and reopen to write the actual content
        close($fh);
        open($fh, '>', $html_file) or die;

        my $html_head = <<'HTML_HEAD';
<!DOCTYPE html>
<html>
<head>
<title>Build Tree</title>
<style>
body { font-family: monospace; margin: 20px; background: #1e1e1e; color: #d4d4d4; }
h1, h2 { color: #569cd6; }
.layer { margin: 20px 0; padding: 10px; border: 1px solid #3c3c3c; border-radius: 5px; }
.layer-title { font-weight: bold; color: #dcdcaa; margin-bottom: 10px; }
.target { padding: 5px 10px; margin: 2px 0; cursor: pointer; border-radius: 3px; }
.target:hover { background: #2d2d2d; }
.ok { color: #4ec9b0; }
.stale { color: #f14c4c; }
.dirty { color: #569cd6; }
.indicator { color: #808080; margin-right: 5px; }
.info-panel { display: none; position: fixed; top: 50px; right: 20px; width: 400px;
              background: #252526; border: 1px solid #3c3c3c; border-radius: 5px;
              padding: 15px; max-height: 80vh; overflow-y: auto; }
.info-panel.visible { display: block; }
.info-panel h3 { color: #dcdcaa; margin-top: 0; }
.info-panel pre { background: #1e1e1e; padding: 10px; border-radius: 3px;
                  overflow-x: auto; white-space: pre-wrap; }
.info-panel .label { color: #569cd6; }
.close-btn { float: right; cursor: pointer; color: #808080; }
.close-btn:hover { color: #d4d4d4; }
.legend { margin-bottom: 20px; }
.legend span { margin-right: 20px; }
</style>
</head>
<body>
HTML_HEAD
        print $fh $html_head;
        print $fh "<h1>Build Tree: " . _html_escape($target) . "</h1>\n";
        print $fh qq{<div class="legend">\n};
        print $fh qq{  <span class="ok">&#9679; OK (up-to-date)</span>\n};
        print $fh qq{  <span class="stale">&#9679; Stale (needs rebuild)</span>\n};
        print $fh qq{  <span class="dirty">&#9679; Dirty (marked for rebuild)</span>\n};
        print $fh qq{</div>\n};
        print $fh qq{<div id="info-panel" class="info-panel">\n};
        print $fh qq{  <span class="close-btn" onclick="hideInfo()">&times;</span>\n};
        print $fh qq{  <h3 id="info-target"></h3>\n};
        print $fh qq{  <div id="info-content"></div>\n};
        print $fh qq{</div>\n};

        # Build target info database for JavaScript
        print $fh "<script>\nvar targetInfo = {\n";
        for my $tgt (keys %all_targets) {
            my $info = $get_target_info->($tgt);
            my $status = $get_status->($tgt);
            my $escaped_tgt = $tgt;
            $escaped_tgt =~ s/'/\\'/g;
            print $fh "  '$escaped_tgt': {\n";
            print $fh "    status: '$status',\n";
            print $fh "    exists: " . ($info->{exists} ? 'true' : 'false') . ",\n";
            print $fh "    size: " . ($info->{size} // 0) . ",\n";
            print $fh "    mtime: " . ($info->{mtime} // 0) . ",\n";
            print $fh "    deps: [" . join(", ", map { "'" . _html_escape($_) . "'" } @{$info->{deps}}) . "],\n";
            my $exec_dir = $info->{exec_dir} // '.';
            $exec_dir =~ s/'/\\'/g;
            print $fh "    execDir: '$exec_dir',\n";
            # Add siblings (for compound targets)
            my @siblings = @{$info->{siblings} || []};
            print $fh "    siblings: [" . join(", ", map { "'" . _html_escape($_) . "'" } @siblings) . "],\n";
            # Add compound parent (for sibling targets)
            my $compound = $info->{compound_parent} // '';
            $compound =~ s/'/\\'/g;
            print $fh "    compoundParent: '$compound',\n";
            my $rule = $info->{rule} // '';
            $rule =~ s/\\/\\\\/g;
            $rule =~ s/'/\\'/g;
            $rule =~ s/\n/\\n/g;
            print $fh "    rule: '$rule',\n";
            my $post_build = $info->{post_build} // '';
            $post_build =~ s/\\/\\\\/g;
            $post_build =~ s/'/\\'/g;
            print $fh "    postBuild: '$post_build'\n";
            print $fh "  },\n";
        }
        print $fh "};\n";

        print $fh <<'HTML_SCRIPT';
function showInfo(target) {
  var info = targetInfo[target];
  if (!info) return;
  document.getElementById('info-target').textContent = target;
  var html = '<p><span class="label">Status:</span> <span class="' + info.status + '">' + info.status + '</span></p>';
  if (info.exists) {
    html += '<p><span class="label">Size:</span> ' + info.size + ' bytes</p>';
    html += '<p><span class="label">Modified:</span> ' + new Date(info.mtime * 1000).toLocaleString() + '</p>';
  } else {
    html += '<p><span class="label">File:</span> does not exist</p>';
  }
  if (info.execDir && info.execDir !== '.') {
    html += '<p><span class="label">Execution directory:</span> ' + info.execDir + '</p>';
  }
  if (info.compoundParent) {
    html += '<p><span class="label">Built by compound target:</span> <span onclick="showInfo(\'' + info.compoundParent + '\')" style="cursor:pointer;text-decoration:underline">' + info.compoundParent + '</span></p>';
  }
  if (info.siblings && info.siblings.length > 1) {
    html += '<p><span class="label">Multi-output siblings:</span></p><ul>';
    info.siblings.forEach(function(s) {
      var sinfo = targetInfo[s];
      var cls = sinfo ? sinfo.status : 'stale';
      html += '<li class="' + cls + '" onclick="showInfo(\'' + s + '\')" style="cursor:pointer">' + s + '</li>';
    });
    html += '</ul>';
  }
  if (info.deps.length > 0) {
    html += '<p><span class="label">Dependencies:</span></p><ul>';
    info.deps.forEach(function(d) {
      var dinfo = targetInfo[d];
      var cls = dinfo ? dinfo.status : 'stale';
      html += '<li class="' + cls + '" onclick="showInfo(\'' + d + '\')" style="cursor:pointer">' + d + '</li>';
    });
    html += '</ul>';
  }
  if (info.rule) {
    html += '<p><span class="label">Build command:</span></p><pre>' + info.rule.replace(/</g, '&lt;') + '</pre>';
  }
  if (info.postBuild) {
    html += '<p><span class="label">Post-build:</span></p><pre>' + info.postBuild.replace(/</g, '&lt;') + '</pre>';
  }
  document.getElementById('info-content').innerHTML = html;
  document.getElementById('info-panel').classList.add('visible');
}
function hideInfo() {
  document.getElementById('info-panel').classList.remove('visible');
}
</script>
HTML_SCRIPT

        print $fh "<p>Build order: Layer 0 builds first, layer $max_layer builds last.</p>\n";

        my $total = 0;
        for my $layer (0 .. $max_layer) {
            next unless $layers[$layer] && @{$layers[$layer]};
            my @targets = sort @{$layers[$layer]};
            my $count = scalar @targets;
            $total += $count;

            print $fh qq{<div class="layer">\n};
            print $fh qq{<div class="layer-title">Layer $layer};
            print $fh " (builds first)" if $layer == 0;
            print $fh " [$count target" . ($count == 1 ? "" : "s") . "]</div>\n";

            for my $t (@targets) {
                my $status = $get_status->($t);
                my $indicator = "";
                if ($t =~ /&/) { $indicator = "[compound]"; }  # Multi-output target
                elsif ($t =~ /\.a$/) { $indicator = "[lib]"; }
                elsif ($t =~ /\.o$/) { $indicator = "[obj]"; }
                elsif ($t =~ /\.(c|cpp|cc|cxx)$/) { $indicator = "[src]"; }
                elsif ($t =~ /\.(h|hpp)$/) { $indicator = "[hdr]"; }
                elsif (-x $t || $t =~ /^bin\//) { $indicator = "[exe]"; }

                my $escaped = _html_escape($t);
                my $js_escaped = $t;
                $js_escaped =~ s/'/\\'/g;
                print $fh qq{<div class="target $status" onclick="showInfo('$js_escaped')">};
                print $fh qq{<span class="indicator">$indicator</span>} if $indicator;
                print $fh "$escaped</div>\n";
            }
            print $fh "</div>\n";
        }

        print $fh "<p>Total: $total targets in " . ($max_layer + 1) . " layers</p>\n";
        print $fh "</body>\n</html>\n";
        close($fh);

        print "HTML output written to: $html_file\n";

        if ($launch_browser) {
            system("$launch_browser $html_file &");
            print "Launched browser: $launch_browser\n";
        }
        return;
    }

    # Terminal output with colors
    print "Build tree for: $target\n";
    print "=" x 60 . "\n";
    print "Legend: $colors{ok}green=ok$colors{reset}, $colors{stale}red=stale$colors{reset}, $colors{dirty}blue=dirty$colors{reset}\n";
    print "Build order: Layer 0 builds first, layer $max_layer builds last.\n";

    my $total = 0;
    for my $layer (0 .. $max_layer) {
        next unless $layers[$layer] && @{$layers[$layer]};

        my @targets = sort @{$layers[$layer]};
        my $count = scalar @targets;
        $total += $count;

        print "\nLayer $layer";
        print " (builds first)" if $layer == 0;
        print " [$count target" . ($count == 1 ? "" : "s") . "]:\n";

        for my $t (@targets) {
            my $status = $get_status->($t);
            my $color = $colors{$status} // '';
            my $reset = $colors{reset};

            my $indicator = "";
            if ($t =~ /&/) {
                $indicator = "[compound] ";  # Multi-output target
            } elsif ($t =~ /\.a$/) {
                $indicator = "[lib] ";
            } elsif ($t =~ /\.o$/) {
                $indicator = "[obj] ";
            } elsif ($t =~ /\.(c|cpp|cc|cxx)$/) {
                $indicator = "[src] ";
            } elsif ($t =~ /\.(h|hpp)$/) {
                $indicator = "[hdr] ";
            } elsif (-x $t || $t =~ /^bin\//) {
                $indicator = "[exe] ";
            }
            print "  $color$indicator$t$reset\n";
        }
    }

    print "\n" . "=" x 60 . "\n";
    print "Total: $total targets in " . ($max_layer + 1) . " layers\n";
}

# Helper for HTML escaping
sub _html_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

sub cmd_vpath {
    my ($words, $socket) = @_;

    if (@$words == 0) {
        print "Usage: vpath <file>\n";
        return;
    }

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $file = $words->[0];
    print $socket "VPATH $file\n";
    my $response = <$socket>;
    print "$response" if $response;
}

sub cmd_start {
    my ($words, $opts, $state) = @_;

    my $socket = ${$state->{socket}};
    my $num_workers = @$words > 0 ? $words->[0] : 1;

    if ($socket) {
        # Server already running - add workers
        print "Adding $num_workers worker(s) to job server...\n";
        print $socket "ADD_WORKER $num_workers\n";
        my $response = <$socket>;
        chomp $response if $response;
        print "$response\n" if $response;
        return;
    }

    # No server running - start new one
    my $num_jobs = @$words > 0 ? $words->[0] : ($opts->{jobs} || 1);
    my $wait = $opts->{wait} // 0;

    print "Starting job server with $num_jobs workers" . ($wait ? " (waiting for workers)" : " (async)") . "...\n";

    # Set global $jobs variable before calling start_job_server
    # (start_job_server doesn't take parameters, it uses the global)
    my $old_jobs = $jobs;
    $jobs = $num_jobs;

    # Start the job server with error handling
    eval {
        require Smak;  # Make sure we have access to start_job_server
        Smak::start_job_server($wait);
    };

    if ($@) {
        # Restore old jobs value on error
        $jobs = $old_jobs;
        print "Failed to start job server: $@\n";
        return;
    }

    # Check if job server actually started
    if (!$Smak::job_server_socket) {
        # Restore old jobs value on failure
        $jobs = $old_jobs;
        print "Failed to start job server (no socket created)\n";
        return;
    }

    # Update state
    ${$state->{socket}} = $Smak::job_server_socket;
    ${$state->{server_pid}} = $Smak::job_server_pid;

    print "Job server started (PID: $Smak::job_server_pid)\n";
}

sub cmd_stop {
    my ($words, $opts, $state) = @_;

    my $socket = ${$state->{socket}};
    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $num_workers = @$words > 0 ? $words->[0] : 1;
    print "Removing $num_workers worker(s) from job server...\n";
    print $socket "REMOVE_WORKER $num_workers\n";
    my $response = <$socket>;
    chomp $response if $response;
    print "$response\n" if $response;
}

sub cmd_auto_retry {
    my ($words, $opts, $state) = @_;

    if (@$words == 0) {
        # Show current patterns
        if (@Smak::auto_retry_patterns) {
            print "Auto-retry enabled for patterns:\n";
            for my $pattern (@Smak::auto_retry_patterns) {
                print "  $pattern\n";
            }
        } else {
            print "No auto-retry patterns configured.\n";
            print "Usage: auto-retry *.cc *.hh  - Enable auto-retry for matching files\n";
            print "       auto-retry -clear      - Clear all patterns\n";
        }
        return;
    }

    if ($words->[0] eq '-clear') {
        @Smak::auto_retry_patterns = ();
        %Smak::retry_counts = ();
        print "Cleared all auto-retry patterns.\n";
        return;
    }

    # Add patterns
    for my $pattern (@$words) {
        push @Smak::auto_retry_patterns, $pattern unless grep { $_ eq $pattern } @Smak::auto_retry_patterns;
    }
    print "Auto-retry enabled for: " . join(", ", @$words) . "\n";
    print "Matching files will be automatically retried once if they fail.\n";
}

sub cmd_kill {
    my ($socket) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    print "Killing all workers...\n";
    print $socket "KILL_WORKERS\n";
    my $response = <$socket>;
    chomp $response if $response;
    print "$response\n" if $response;
}

sub cmd_restart {
    my ($words, $socket, $opts) = @_;

    if (!$socket) {
        print "Job server not running.\n";
        return;
    }

    my $count = @$words > 0 ? $words->[0] : ($opts->{jobs} || 1);
    print "Restarting workers with $count workers...\n";
    print $socket "RESTART_WORKERS $count\n";
    my $response = <$socket>;
    chomp $response if $response;
    print "$response\n" if $response;
}


sub perform_auto_rescan {
    my ($last_mtimes_ref, $OUT) = @_;
    my $stale_count = 0;

    # Get targets that have been built (from rules hash)
    my %targets_to_check;

    # Access package variables
    our %fixed_rule;
    our %is_phony;
    our %stale_targets_cache;

    # Check all rules for targets that exist as files
    for my $key (keys %fixed_rule) {
        my ($mf, $target) = split(/\t/, $key, 2);
        next unless $target;

        # Skip phony targets
        next if exists $is_phony{$target};
        next if $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/;

        $targets_to_check{$target} = 1 if -e $target;
    }

    # Check each target for changes
    for my $target (keys %targets_to_check) {
        my $current_mtime = (stat($target))[9];

        if (!-e $target) {
            # File was deleted
            if (exists $last_mtimes_ref->{$target}) {
                $stale_count++;
                delete $last_mtimes_ref->{$target};
                # Mark as stale in cache
                $stale_targets_cache{$target} = time();
                print STDERR "  [auto-rescan] Marked stale (deleted): $target\n" if $ENV{SMAK_DEBUG};
            }
        } elsif (!exists $last_mtimes_ref->{$target}) {
            # New file - track it
            $last_mtimes_ref->{$target} = $current_mtime;
        } elsif ($current_mtime != $last_mtimes_ref->{$target}) {
            # File was modified
            $stale_count++;
            $last_mtimes_ref->{$target} = $current_mtime;
            # Mark as stale in cache
            $stale_targets_cache{$target} = time();
            print STDERR "  [auto-rescan] Marked stale (modified): $target\n" if $ENV{SMAK_DEBUG};
        }
    }

    return $stale_count;
}

sub auto_rescan_watcher {
    my ($socket, $makefile_ref, $parent_pid) = @_;

    # Set process name for visibility in smak-ps
    use Sys::Hostname;
    my $hostname = hostname() || 'local';
    $parent_pid //= getppid();  # Use parent PID if not passed
    set_process_name("smak-scan for $hostname:$parent_pid");

    # Run at lower priority to avoid interfering with builds
    eval { setpriority(0, 0, 10); };  # Nice +10 (lower priority)

    # Track file mtimes
    my %last_mtimes;
    my %watched_targets;  # Targets we're actively watching

    # Get initial list of targets from makefile
    our %fixed_rule;
    our %is_phony;

    # Populate initial watch list with non-phony file targets
    for my $key (keys %fixed_rule) {
        my ($mf, $target) = split(/\t/, $key, 2);
        next unless $target;
        next if exists $is_phony{$target};
        next if $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/;

        if (-e $target) {
            $watched_targets{$target} = 1;
            $last_mtimes{$target} = (stat($target))[9];
        }
    }

    $socket->autoflush(1);

    # Main watcher loop
    while (1) {
        # Check for commands from parent using select (avoid eof() issues with non-blocking)
        my $select = IO::Select->new($socket);
        while ($select->can_read(0)) {  # Non-blocking check
            my $cmd = <$socket>;
            unless (defined $cmd) {
                # Actual EOF - parent closed socket
                exit 0;
            }
            chomp $cmd;

            if ($cmd eq 'SHUTDOWN') {
                exit 0;
            } elsif ($cmd =~ /^WATCH:(.+)$/) {
                my $target = $1;
                $watched_targets{$target} = 1;
                if (-e $target) {
                    $last_mtimes{$target} = (stat($target))[9];
                }
            } elsif ($cmd =~ /^UNWATCH:(.+)$/) {
                my $target = $1;
                delete $watched_targets{$target};
                delete $last_mtimes{$target};
            }
        }

        # Scan watched targets for changes
        for my $target (keys %watched_targets) {
            if (!-e $target) {
                # File was deleted
                if (exists $last_mtimes{$target}) {
                    $socket->blocking(1);
                    print $socket "DELETE:$$:$target\n";
                    delete $last_mtimes{$target};
                }
            } else {
                # File exists - check if modified
                my $current_mtime = (stat($target))[9];
                if (!exists $last_mtimes{$target}) {
                    # Newly appeared
                    $last_mtimes{$target} = $current_mtime;
                    $socket->blocking(1);
                    print $socket "CREATE:$$:$target\n";
                } elsif ($current_mtime != $last_mtimes{$target}) {
                    # Modified
                    $last_mtimes{$target} = $current_mtime;
                    $socket->blocking(1);
                    print $socket "MODIFY:$$:$target\n";
                }
            }
        }

        # Sleep ~1 second between scans (low CPU usage)
        sleep 1;
    }
}

sub run_standalone_scanner {
    my (@watch_paths) = @_;

    use IO::Socket::INET;
    use IO::Select;
    use File::Spec;
    use File::Basename;
    use Cwd 'abs_path';

    # Convert paths to absolute
    my @abs_paths;
    my %path_map;  # Maps absolute paths back to original
    for my $path (@watch_paths) {
        my $abs_path = abs_path($path) || File::Spec->rel2abs($path);
        push @abs_paths, $abs_path;
        $path_map{$abs_path} = $path;
        if (! -e $path) {
            warn "Warning: Path does not exist: $path\n";
        }
    }

    # Check for FUSE monitoring
    my %fuse_sockets;  # mountpoint => socket
    my %fuse_paths;    # path => mountpoint
    my %polling_paths; # Paths that need polling

    for my $abs_path (@abs_paths) {
        my $dir = -d $abs_path ? $abs_path : dirname($abs_path);

        if (my ($mountpoint, $fuse_port, $server, $remote_path) = detect_fuse_monitor($dir)) {
            # Check if we already connected to this mountpoint
            if (!exists $fuse_sockets{$mountpoint}) {
                my $socket = IO::Socket::INET->new(
                    PeerHost => '127.0.0.1',
                    PeerPort => $fuse_port,
                    Proto    => 'tcp',
                    Timeout  => 5,
                );
                if ($socket) {
                    $socket->autoflush(1);
                    $fuse_sockets{$mountpoint} = $socket;
                    print STDERR "Connected to FUSE monitor for $mountpoint (port $fuse_port)\n";
                } else {
                    warn "Warning: Could not connect to FUSE monitor on port $fuse_port: $!\n";
                    $polling_paths{$abs_path} = 1;
                }
            }
            $fuse_paths{$abs_path} = $mountpoint if exists $fuse_sockets{$mountpoint};
        } else {
            $polling_paths{$abs_path} = 1;
        }
    }

    # Track file mtimes for polling paths
    my %last_mtimes;
    for my $abs_path (keys %polling_paths) {
        if (-e $abs_path) {
            $last_mtimes{$abs_path} = (stat($abs_path))[9];
        }
    }

    my $pid = $$;

    # Set up select for FUSE sockets
    my $select = IO::Select->new();
    for my $socket (values %fuse_sockets) {
        $select->add($socket);
    }

    # Track inode to path mapping for FUSE events
    my %inode_to_path;

    # Main scanner loop (runs until interrupted)
    while (1) {
        # Check FUSE sockets with small timeout
        my @ready = $select->can_read(0.5);

        for my $socket (@ready) {
            my $line = <$socket>;
            unless (defined $line) {
                # FUSE monitor disconnected
                print STDERR "FUSE monitor disconnected\n";
                $select->remove($socket);
                # Move paths from this socket to polling
                for my $path (keys %fuse_paths) {
                    my $mp = $fuse_paths{$path};
                    if ($fuse_sockets{$mp} == $socket) {
                        delete $fuse_paths{$path};
                        $polling_paths{$path} = 1;
                        $last_mtimes{$path} = (stat($path))[9] if -e $path;
                    }
                }
                next;
            }
            chomp $line;

            # Parse FUSE event: OP:PID:INODE or INO:INODE:PATH
            if ($line =~ /^(\w+):(\d+):(.+)$/) {
                my ($op, $arg1, $arg2) = ($1, $2, $3);

                if ($op eq 'INO') {
                    # Inode-to-path mapping
                    my ($inode, $fuse_path) = ($arg1, $arg2);
                    $inode_to_path{$inode} = $fuse_path;
                } elsif ($op =~ /^(DELETE|MODIFY|CREATE)$/) {
                    my $inode = $arg2;
                    my $fuse_path = $inode_to_path{$inode} || "inode:$inode";

                    # Check if this path is in our watch list
                    for my $abs_path (keys %fuse_paths) {
                        # Simple check - if the FUSE path ends with our watched file
                        my $watch_file = File::Spec->abs2rel($abs_path, '/');
                        if ($fuse_path =~ /\Q$watch_file\E$/ || $abs_path eq $fuse_path) {
                            my $orig_path = $path_map{$abs_path};
                            print "$op:$pid:$orig_path (via FUSE)\n";
                            STDOUT->flush();
                        }
                    }
                }
            }
        }

        # Poll non-FUSE paths
        for my $abs_path (keys %polling_paths) {
            my $orig_path = $path_map{$abs_path};
            if (!-e $abs_path) {
                # File was deleted
                if (exists $last_mtimes{$abs_path}) {
                    print "DELETE:$pid:$orig_path\n";
                    STDOUT->flush();
                    delete $last_mtimes{$abs_path};
                }
            } else {
                # File exists - check if modified
                my $current_mtime = (stat($abs_path))[9];
                if (!defined $current_mtime) {
                    # stat failed, file disappeared between -e check and stat
                    next;
                }
                if (!exists $last_mtimes{$abs_path}) {
                    # Newly appeared
                    $last_mtimes{$abs_path} = $current_mtime;
                    print "CREATE:$pid:$orig_path\n";
                    STDOUT->flush();
                } elsif ($current_mtime != $last_mtimes{$abs_path}) {
                    # Modified
                    $last_mtimes{$abs_path} = $current_mtime;
                    print "MODIFY:$pid:$orig_path\n";
                    STDOUT->flush();
                }
            }
        }

        # Sleep briefly if we're only polling (FUSE has already waited in select)
        sleep 0.5 if keys %polling_paths;
    }
}

sub interactive_debug {
    my ($OUT,$input) = @_ ;
    my $term = Term::ReadLine->new('smak');
    my $have_input = defined $input;
    my $exit_after_one = $have_input;  # Exit after one command if input was provided
    if (! defined $OUT) {
	$OUT = $term->OUT || \*STDOUT;
    }

    # Set interactive flag so Ctrl-C doesn't exit
    local $interactive = 1;

    # Auto-rescan state
    my $auto_rescan_enabled = 0;
    my $watcher_pid;
    my $watcher_socket;

    # Check if stdin is a TTY (interactive) or piped (scripted)
    my $is_tty = -t STDIN;

    # Only show welcome message if interactive
    if ($is_tty) {
        print $OUT "Interactive smak debugger. Type 'help' for commands.\n";
        $OUT->flush() if $OUT->can('flush');
    }

    while (1) {
        if (!$have_input) {
            # Print prompt before waiting for input (only in TTY mode)
            if ($is_tty) {
                print $OUT $prompt;
                $OUT->flush() if $OUT->can('flush');
                STDOUT->flush();
            }
            # Use select() with timeout to allow periodic checks
            my $rin = '';
            vec($rin, fileno(STDIN), 1) = 1;

            # Add watcher socket to select if auto-rescan is enabled
            if ($watcher_socket) {
                vec($rin, fileno($watcher_socket), 1) = 1;
            }

            my $timeout = 60.0;  # 60s timeout (watcher handles auto-rescan timing)
            my $nfound = select(my $rout = $rin, undef, undef, $timeout);

            if ($nfound > 0) {
                # Check if watcher has events
                if ($watcher_socket && vec($rout, fileno($watcher_socket), 1)) {
                    # Process watcher events
                    $watcher_socket->blocking(0);
                    while (my $event = <$watcher_socket>) {
                        chomp $event;

                        # Parse event: "OP:PID:PATH"
                        if ($event =~ /^(\w+):\d+:(.+)$/) {
                            my ($op, $path) = ($1, $2);

                            if ($op eq 'DELETE' || $op eq 'MODIFY') {
                                # Mark target as stale
                                $stale_targets_cache{$path} = time();
                                print $OUT "[auto-rescan] $path $op detected\n";
                            }
                        }
                    }
                }

                # Check if STDIN has input
                if (vec($rout, fileno(STDIN), 1)) {
                    # Input available - read it directly from STDIN
                    print $OUT $prompt if ($echo && $is_tty);
                    $input = <STDIN>;
                    unless (defined $input) {
                        # EOF (Ctrl-D) or Ctrl-C
                        if ($SmakCli::cancel_requested) {
                            $SmakCli::cancel_requested = 0;  # Clear the flag
                            next;  # Return to prompt, don't exit
                        }
                        last;  # Ctrl-D or other termination
                    }
                }
            } elsif ($nfound == 0) {
                # Timeout - no activity
                next;  # Continue loop
            } else {
                # Error in select
                last;
            }
        }
        $have_input = 0;  # Only use provided input once

        chomp $input;

        # Skip comment lines (but not empty lines, those are handled below)
        next if $input =~ /^\s*#/;

        # Echo the line if echo mode is enabled (only in TTY mode)
        if ($echo && $input ne '' && $is_tty) {
            print "$prompt$input\n";
        }

        # Skip empty input
        next if $input =~ /^\s*$/;

        # Add to history
        $term->addhistory($input) if $input =~ /\S/;

        # Parse command
        my @parts = split /\s+/, $input;
        my $cmd = lc($parts[0]);

        if ($cmd eq 'quit' || $cmd eq 'q' || $cmd eq 'exit') {
            last;
        }
        elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
            print $OUT <<'HELP';
Commands:
  list, l              - List all rules
  rules <target>       - Show rules for a specific target
  show <target>        - Alias for 'rules <target>'
  build <target>       - Build a target
  progress	       - Show work in progress
  rescan               - Rescan timestamps
  rescan -auto         - Enable auto-rescan (detects file changes automatically)
  rescan -noauto       - Disable auto-rescan
  vpath <file>         - Test vpath resolution for a file
  dry-run <target>     - Dry run a target
  print <expr>         - Evaluate and print an expression (in isolated subprocess)
  eval <expr>          - Evaluate a Perl expression
  safe-eval <expr>     - Evaluate a Perl expression (in isolated subprocess)
  !<command>           - Run a shell command
  set                  - Show control variables
  set <var> <value>    - Set a control variable (timeout, prompt, echo)
  add-rule <target> : <deps> : <rule>
                       - Add a new rule
  mod-rule <target> : <rule>
                       - Modify rule commands
  mod-deps <target> : <deps>
                       - Modify dependencies
  del-rule <target>    - Delete a rule
  save <file>          - Save modifications to file
  help, h, ?           - Show this help
  quit, q, exit        - Exit debugger
HELP
        }
        elsif ($cmd eq 'list' || $cmd eq 'l') {
            print_rules();
        }
        elsif ($cmd eq 'rules' || $cmd eq 'show') {
            if (@parts < 2) {
                print $OUT "Usage: rules <target>\n";
            } else {
                my $target = $parts[1];

                # Look for explicit fixed rules
                my $found = 0;
                for my $key (keys %fixed_deps) {
                    if ($key =~ /^([^\t]+)\t\Q$target\E$/) {
                        my $mf = $1;
                        $found = 1;
                        print $OUT "Explicit rule in $mf:\n";
                        print $OUT "  Target: $target\n";

                        # Show dependencies
                        if (exists $fixed_deps{$key}) {
                            my @deps = @{$fixed_deps{$key}};
                            # Convert $MV{VAR} back to $(VAR) for display
                            my @display_deps = map {
                                my $d = $_;
                                $d =~ s/\$MV\{([^}]+)\}/\$($1)/g;
                                $d;
                            } @deps;
                            print $OUT "  Dependencies: " . join(' ', @display_deps) . "\n";
                        }

                        # Show order-only prerequisites if any
                        if (exists $fixed_order_only{$key}) {
                            my @order_only = @{$fixed_order_only{$key}};
                            my @display_order = map {
                                my $d = $_;
                                $d =~ s/\$MV\{([^}]+)\}/\$($1)/g;
                                $d;
                            } @order_only;
                            print $OUT "  Order-only prerequisites: " . join(' ', @display_order) . "\n";
                        }

                        # Show commands
                        my $rule = $fixed_rule{$key} || '';
                        if ($rule && $rule =~ /\S/) {
                            # Convert $MV{VAR} back to $(VAR) for display
                            $rule =~ s/\$MV\{([^}]+)\}/\$($1)/g;
                            print $OUT "  Commands:\n";
                            for my $line (split /\n/, $rule) {
                                print $OUT "  $line\n";
                            }
                        } else {
                            print $OUT "  Commands: (none)\n";
                        }
                    }
                }

                # Check for pattern rules that might match
                for my $key (keys %pattern_rule) {
                    if ($key =~ /^([^\t]+)\t(.+)$/) {
                        my ($mf, $pattern) = ($1, $2);
                        my $pattern_re = $pattern;
                        $pattern_re =~ s/%/(.*)/;
                        $pattern_re = "^$pattern_re\$";

                        if ($target =~ /$pattern_re/) {
                            my $stem = $1 // '';
                            print $OUT "Pattern rule in $mf:\n";
                            print $OUT "  Pattern: $pattern\n";
                            print $OUT "  Matches: $target (stem='$stem')\n";

                            if (exists $pattern_deps{$key}) {
                                my @deps = @{$pattern_deps{$key}};
                                my @display_deps = map {
                                    my $d = $_;
                                    $d =~ s/\$MV\{([^}]+)\}/\$($1)/g;
                                    $d =~ s/%/$stem/g;
                                    $d;
                                } @deps;
                                print $OUT "  Prereqs pattern: " . join(' ', @{$pattern_deps{$key}}) . "\n";
                                print $OUT "  Expanded prereqs: " . join(' ', @display_deps) . "\n";
                            }

                            my $rule = $pattern_rule{$key} || '';
                            if ($rule && $rule =~ /\S/) {
                                $rule =~ s/\$MV\{([^}]+)\}/\$($1)/g;
                                print $OUT "  Commands:\n";
                                for my $line (split /\n/, $rule) {
                                    print $OUT "  $line\n";
                                }
                            }
                            $found = 1;
                        }
                    }
                }

                if (!$found) {
                    print $OUT "No rules found for target '$target'\n";
                    print $OUT "Target may be built by implicit rules or already exists\n";
                }
            }
        }
        elsif ($cmd eq 'build') {
            if (@parts < 2) {
                print $OUT "Usage: build <target>\n";
            } else {
                my $target = $parts[1];

                # Check if we have a job server connection
                if ($job_server_socket) {
                    # Using job server - submit directly and wait for completion
                    my $build_start_time = time();

                    # Submit the job directly to job server (avoid race condition with build_target)
                    use IO::Select;
                    use Cwd 'getcwd';
                    my $cwd = getcwd();

                    print $job_server_socket "SUBMIT_JOB\n";
                    print $job_server_socket "$target\n";
                    print $job_server_socket "$cwd\n";
                    print $job_server_socket "true\n";  # Composite target placeholder command
                    $job_server_socket->flush();

                    # Wait for job completion, displaying output as it arrives
                    my $select = IO::Select->new($job_server_socket);
                    my $job_done = 0;
                    my $cancelled = 0;
                    my $timeout = 60;  # 60 seconds total timeout
                    my $deadline = time() + $timeout;

                    while (!$job_done && !$cancelled && time() < $deadline) {
                        # Check for Ctrl-C cancel request
                        if ($SmakCli::cancel_requested) {
                            print $OUT "\nCtrl-C - Cancelling build...\n";
                            print $job_server_socket "KILL_WORKERS\n";
                            $job_server_socket->flush();
                            $SmakCli::cancel_requested = 0;
                            $cancelled = 1;
                            # Drain socket to clear pending messages
                            while ($select->can_read(0.5)) {
                                my $drain = <$job_server_socket>;
                                last unless defined $drain;
                            }
                            last;
                        }
                        # Process messages from job server
                        if ($select->can_read(0.1)) {
                            my $response = <$job_server_socket>;
                            unless (defined $response) {
                                print $OUT "Connection to job server lost\n";
                                last;
                            }
                            chomp $response;

                            if ($response =~ /^OUTPUT (.*)$/) {
                                print $OUT "$1\n";
                                $OUT->flush() if $OUT->can('flush');
                            } elsif ($response =~ /^ERROR (.*)$/) {
                                print $OUT "ERROR: $1\n";
                                $OUT->flush() if $OUT->can('flush');
                            } elsif ($response =~ /^WARN (.*)$/) {
                                print $OUT "WARN: $1\n";
                                $OUT->flush() if $OUT->can('flush');
                            } elsif ($response =~ /^JOB_COMPLETE\s+(\S+)\s+(\d+)$/) {
                                my ($completed_target, $exit_code) = ($1, $2);
                                # Only stop when we get completion for our requested target
                                if ($completed_target eq $target) {
                                    $job_done = 1;
                                    my $elapsed = time() - $build_start_time;
                                    if ($exit_code != 0) {
                                        # Failure message already shown via ERROR/OUTPUT
                                    }
                                }
                            }
                        }
                    }

                    if (!$job_done && !$cancelled) {
                        print $OUT "Build timed out after ${timeout}s\n";
                    }
                } else {
                    # No job server - build sequentially
                    eval { build_target($target); };
                    if ($@) {
                        print $OUT "Error building target: $@\n";
                    }
                }
            }
        }
        elsif ($cmd eq 'progress') {
	    foreach my $target (keys %in_progress) {
		my $state = $in_progress{$target};
		my $op = lc($parts[1]);
		print STDERR "$target\n$state\n";
		if ('done' eq $state && 'clear' eq $op) {
		    undef $in_progress{$target};
		}
	    }
	}
        elsif ($cmd eq 'rescan') {
            # Handle rescan command
            shift @parts;  # Remove 'rescan' from @parts to get just the arguments
            my $arg = @parts > 0 ? $parts[0] : '';

            if ($arg eq '-auto') {
                # Enable auto-rescan with background watcher
                if (!$watcher_pid) {
                    # Create socketpair for bidirectional communication
                    use Socket;
                    socketpair(my $parent_sock, my $child_sock, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
                        or die "socketpair failed: $!";

                    $parent_sock->autoflush(1);
                    $child_sock->autoflush(1);

                    $watcher_pid = fork();
                    die "fork failed: $!" unless defined $watcher_pid;

                    if ($watcher_pid == 0) {
                        # Child process - run watcher
                        close($parent_sock);
                        auto_rescan_watcher($child_sock, \$makefile);
                        exit 0;  # Should never reach here
                    } else {
                        # Parent process - keep parent socket
                        close($child_sock);
                        $watcher_socket = $parent_sock;
                        $auto_rescan_enabled = 1;
                        print $OUT "Auto-rescan enabled (background watcher PID $watcher_pid)\n";
                    }
                } else {
                    print $OUT "Auto-rescan already enabled (PID $watcher_pid)\n";
                }

            } elsif ($arg eq '-noauto') {
                # Disable auto-rescan and shutdown watcher
                if ($watcher_pid) {
                    print $watcher_socket "SHUTDOWN\n" if $watcher_socket;
                    waitpid($watcher_pid, 0);
                    close($watcher_socket) if $watcher_socket;
                    $watcher_pid = undef;
                    $watcher_socket = undef;
                }
                $auto_rescan_enabled = 0;
                print $OUT "Auto-rescan disabled.\n";

            } else {
                # One-time rescan
                if ($job_server_socket) {
                    cmd_rescan(\@parts, $job_server_socket, undef);
                } else {
                    # Perform immediate scan
                    my %temp_mtimes;
                    my $stale_count = perform_auto_rescan(\%temp_mtimes, $OUT);
                    print $OUT "Rescan complete. Marked $stale_count target(s) as stale.\n";
                }
            }
        }
        elsif ($cmd eq 'vpath') {
            if (@parts < 2) {
                print $OUT "Usage: vpath <file>\n";
            } else {
                my $file = $parts[1];
                use Cwd 'getcwd';
                my $cwd = getcwd();

                # Show vpath patterns
                print $OUT "Available vpath patterns:\n";
                if (keys %vpath) {
                    for my $p (keys %vpath) {
                        print $OUT "  '$p' => [" . join(", ", @{$vpath{$p}}) . "]\n";
                    }
                } else {
                    print $OUT "  (none)\n";
                }

                # Test resolution
                print $OUT "\nResolving '$file':\n";
                my $resolved = resolve_vpath($file, $cwd);
                if ($resolved ne $file) {
                    print $OUT "  ✓ Resolved to: $resolved\n";
                } else {
                    print $OUT "  ✗ Not resolved (returned as-is)\n";
                }
            }
        }
        elsif ($cmd eq 'dry-run') {
            if (@parts < 2) {
                print $OUT "Usage: dry-run <target>\n";
            } else {
                my $target = $parts[1];
                dry_run_target($target);
            }
        }
        elsif ($cmd eq 'print') {
            my $expr = $input;
            $expr =~ s/^\s*print\s+//;

	    $SmakCli::cli_owner = $$;

            # Fork a subprocess to evaluate the expression with a timeout
            my $pid = fork();
            if (!defined $pid) {
                print $OUT "Failed to fork: $!\n";
                next;
            }

            if ($pid == 0) {
                # Child process
                # Expand variables in the expression
                my $expanded = expand_vars($expr);
                print "$expanded\n";
                exit 0;
            } else {
                # Parent process
                my $start_time = time();
                my $timed_out = 0;

                while (1) {
                    my $kid = waitpid($pid, WNOHANG);
                    if ($kid > 0) {
                        # Child exited
                        last;
                    }
                    if (time() - $start_time > $timeout) {
                        # Timeout
                        kill 'KILL', $pid;
                        waitpid($pid, 0);
                        $timed_out = 1;
                        last;
                    }
                    select(undef, undef, undef, 0.1);  # Sleep 0.1 seconds
                }

                if ($timed_out) {
                    print $OUT "Evaluation timed out after $timeout seconds\n";
                }
            }
        }
        elsif ($cmd eq 'set') {
            if (@parts == 1) {
                print $OUT "Control variables:\n";
                print $OUT "  timeout = $timeout\n";
                print $OUT "  prompt = $prompt\n";
                print $OUT "  echo = $echo\n";
            } elsif (@parts >= 3) {
                my $var = lc($parts[1]);
                my $value = join(' ', @parts[2..$#parts]);

                if ($var eq 'timeout') {
                    $timeout = $value;
                    print $OUT "Set timeout = $timeout\n";
                } elsif ($var eq 'prompt') {
                    # Remove quotes if present
                    $value =~ s/^["']|["']$//g;
                    $prompt = $value;
                    print $OUT "Set prompt = $prompt\n";
                } elsif ($var eq 'echo') {
                    $echo = $value;
                    print $OUT "Set echo = $echo\n";
                } else {
                    print $OUT "Unknown variable: $var\n";
                }
            } else {
                print $OUT "Usage: set <variable> <value>\n";
            }
        }
        elsif ($cmd eq 'add-rule') {
            if ($input =~ /^\s*add-rule\s+(.+?)\s*:\s*(.+?)\s*:\s*(.+)$/i) {
                my ($target, $deps, $rule_text) = ($1, $2, $3);

                # Handle escape sequences
                $rule_text =~ s/\\n/\n/g;
                $rule_text =~ s/\\t/\t/g;

                # Ensure each line starts with a tab
                $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                add_rule($target, $deps, $rule_text);
            } else {
                print $OUT "Usage: add-rule <target> : <deps> : <rule>\n";
            }
        }
        elsif ($cmd eq 'mod-rule') {
            if ($input =~ /^\s*mod-rule\s+(.+?)\s*:\s*(.+)$/i) {
                my ($target, $rule_text) = ($1, $2);

                # Handle escape sequences
                $rule_text =~ s/\\n/\n/g;
                $rule_text =~ s/\\t/\t/g;

                # Ensure each line starts with a tab
                $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                modify_rule($target, $rule_text);
            } else {
                print $OUT "Usage: mod-rule <target> : <rule>\n";
            }
        }
        elsif ($cmd eq 'mod-deps') {
            if ($input =~ /^\s*mod-deps\s+(.+?)\s*:\s*(.+)$/i) {
                my ($target, $deps) = ($1, $2);
                modify_deps($target, $deps);
            } else {
                print $OUT "Usage: mod-deps <target> : <deps>\n";
            }
        }
        elsif ($cmd eq 'del-rule') {
            if (@parts >= 2) {
                my $target = $parts[1];
                delete_rule($target);
            } else {
                print $OUT "Usage: del-rule <target>\n";
            }
        }
        elsif ($cmd eq 'save') {
            if (@parts >= 2) {
                my $filename = $parts[1];
                save_modifications($filename);
            } else {
                print $OUT "Usage: save <filename>\n";
            }
        }
        elsif ($cmd eq 'eval') {
           my $expr = $input;
           $expr =~ s/^\s*eval\s+//;
	   my $result = eval $expr;
	   if ($@) {
	       print "Error: $@\n";
	   } else {
	       print "$result\n" if defined $result;
	   }
	}
        elsif ($cmd eq 'safe-eval') {
            my $expr = $input;
            $expr =~ s/^\s*eval\s+//;

            # Evaluate Perl expression in subprocess with timeout
            my $pid = fork();
            if (!defined $pid) {
                print $OUT "Failed to fork: $!\n";
                next;
            }

            if ($pid == 0) {
                # Child process - evaluate the expression
                my $result = eval $expr;
                if ($@) {
                    print "Error: $@\n";
                } else {
                    print "$result\n" if defined $result;
                }
                exit 0;
            } else {
                # Parent process - wait with timeout
                my $start_time = time();
                my $timed_out = 0;

                while (1) {
                    my $kid = waitpid($pid, WNOHANG);
                    if ($kid > 0) {
                        last;
                    }
                    if (time() - $start_time > $timeout) {
                        kill 'KILL', $pid;
                        waitpid($pid, 0);
                        $timed_out = 1;
                        last;
                    }
                    select(undef, undef, undef, 0.1);
                }

                if ($timed_out) {
                    print $OUT "Evaluation timed out after $timeout seconds\n";
                }
            }
        }
        elsif ($input =~ /^!(.+)/) {
            # Shell command execution
            my $shell_cmd = $1;
            system($shell_cmd);
        }
        else {
            print $OUT "Unknown command: $cmd (type 'help' for commands)\n";
        }

	last if $exit_after_one;
    }

    # Cleanup: shutdown watcher process if running
    if ($watcher_pid) {
        print $watcher_socket "SHUTDOWN\n" if $watcher_socket;
        waitpid($watcher_pid, 0);
        close($watcher_socket) if $watcher_socket;
    }
}

sub print_rules {
    print "Rules parsed from $makefile:\n";
    print "=" x 60 . "\n\n";

    # Print pseudo rules
    if (keys %pseudo_rule || keys %pseudo_deps) {
        print "PSEUDO RULES (.PHONY, .PRECIOUS, etc.):\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %pseudo_rule, keys %pseudo_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$pseudo_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($pseudo_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print pattern rules
    if (keys %pattern_rule || keys %pattern_deps) {
        print "PATTERN RULES (with % wildcards):\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %pattern_rule, keys %pattern_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$pattern_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($pattern_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print fixed rules
    if (keys %fixed_rule || keys %fixed_deps) {
        print "FIXED RULES:\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %fixed_rule, keys %fixed_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$fixed_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($fixed_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print variables
    if (keys %MV) {
        print "VARIABLES:\n";
        print "-" x 60 . "\n";
        for my $var (sort keys %MV) {
            my $value = format_output($MV{$var});
            print "$var = $value\n";
        }
    }
}

# List all targets, optionally filtered by pattern
sub list_targets {
    my ($pattern) = @_;
    $pattern ||= '';

    my %targets;

    # Collect from fixed rules and deps
    # Key format is: base\ttarget
    for my $key (keys %fixed_rule) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }
    for my $key (keys %fixed_deps) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }

    # Collect from pattern rules and deps
    for my $key (keys %pattern_rule) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }
    for my $key (keys %pattern_deps) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }

    # Collect from pseudo rules and deps
    for my $key (keys %pseudo_rule) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }
    for my $key (keys %pseudo_deps) {
        my ($base, $target) = split(/\t/, $key);
        $targets{$target} = 1;
    }

    # Filter by pattern if provided
    my @result;
    if ($pattern) {
        @result = grep { /$pattern/ } keys %targets;
    } else {
        @result = keys %targets;
    }

    return @result;
}

# List all variables, optionally filtered by pattern
sub list_variables {
    my ($pattern) = @_;
    $pattern ||= '';

    my @result;
    if ($pattern) {
        @result = grep { /$pattern/ } keys %MV;
    } else {
        @result = keys %MV;
    }

    return @result;
}

# Get variable value (expanded)
sub get_variable {
    my ($var) = @_;

    # Check command-line overrides first
    return expand_vars($cmd_vars{$var}) if exists $cmd_vars{$var};

    # Check makefile variables
    return expand_vars($MV{$var}) if exists $MV{$var};

    # Check environment
    return $ENV{$var} if exists $ENV{$var};

    return '';
}

sub detect_fuse_monitor {
    my ($path) = @_;
    # Check if we're in a FUSE filesystem

    my $mountpoint;
    my $port;
    my $server;
    my $remote_path;
    
    # Use df to get the mountpoint for current directory
    my $df_output = `df $path 2>/dev/null | tail -1`;
    if ($df_output =~ /\s+(\/\S+)$/) {
	$mountpoint = $1;
	vprint "Mount point for current directory: $mountpoint\n";
    } else {
	return ();
    }
    
    # Read /proc/mounts to verify it's a FUSE filesystem
    open(my $mounts, '<', '/proc/mounts') or return ();
    my $is_fuse = 0;
    my $fstype;
    while (my $line = <$mounts>) {
	# Look for fuse.sshfs or similar at our mountpoint
	if ($line =~ /^(\S+)\s+\Q$mountpoint\E\s+fuse\.(\S+)/) {
	    my $remote = $1;
	    $fstype = $2;
	    $remote =~ /((.*)@)(.*):(.*)/;
	    $remote_path = $4;
	    $server = $3;
	    $is_fuse = 1;
	    vprint "Detected FUSE filesystem: $fstype at $mountpoint\n";
	    last;
	}
    }
    close($mounts);
    
    return () unless $is_fuse;
    
    # Find the FUSE monitor port using lsof -i
    # Look for sshfs processes with LISTEN state
    my $lsof_output = `lsof -i 2>/dev/null | grep sshfs | grep LISTEN`;
    for my $line (split /\n/, $lsof_output) {
	# Parse lsof output: sshfs PID user ... TCP *:PORT (LISTEN)
	if ($line =~ /sshfs\s+(\d+)\s+.*TCP\s+\*:(\d+)\s+\(LISTEN\)/) {
	    my ($pid, $port) = ($1, $2);
	    vprint "Found FUSE monitor on port $port (PID $pid)\n";
	    return ($mountpoint, $port, $server, $remote_path);
	}
    }
    
    return ();
}

# Get FUSE remote server information from df output
# Returns (server, remote_path) or (undef, undef) if not FUSE
sub get_fuse_remote_info {
    my ($path) = @_;
    $path //= '.';

    my ($mountpoint, $port, $server, $remote_path) = detect_fuse_monitor($path);

    return ($server, $remote_path);
}

# Show dependencies for a target
sub show_dependencies {
    my ($target) = @_;

    # Try different rule types
    my $found = 0;

    # Check fixed rules
    # Key format is: base\ttarget
    for my $key (keys %fixed_deps) {
        my ($base, $t) = split(/\t/, $key);
        if ($t eq $target) {
            print "Target: $target (fixed rule)\n";
            print "Base directory: $base\n";
            my @deps = @{$fixed_deps{$key} || []};
            my @active_deps = grep { !is_ignored_dir($_) } @deps;
            my @ignored_deps = grep { is_ignored_dir($_) } @deps;

            if (@active_deps) {
                print "Dependencies:\n";
                foreach my $dep (@active_deps) {
                    print "  $dep\n";
                }
            } else {
                print "No dependencies\n";
            }

            if (@ignored_deps) {
                print "Ignored dependencies (" . scalar(@ignored_deps) . " in system directories):\n";
                foreach my $dep (@ignored_deps[0..9]) {
                    last unless defined $dep;
                    print "  $dep\n";
                }
                if (@ignored_deps > 10) {
                    print "  ... (" . (@ignored_deps - 10) . " more)\n";
                }
            }
            if (exists $fixed_rule{$key}) {
                print "Rule:\n";
                my @lines = split(/\n/, $fixed_rule{$key});
                foreach my $line (@lines) {
                    print "  $line\n";
                }
            }
            $found = 1;
            print "\n";
        }
    }

    # Check pattern rules
    for my $key (keys %pattern_deps) {
        my ($base, $t) = split(/\t/, $key);
        if ($t eq $target) {
            print "Target: $target (pattern rule)\n";
            print "Base directory: $base\n";
            my @deps = @{$pattern_deps{$key} || []};
            if (@deps) {
                print "Dependencies:\n";
                foreach my $dep (@deps) {
                    print "  $dep\n";
                }
            } else {
                print "No dependencies\n";
            }
            if (exists $pattern_rule{$key}) {
                print "Rule:\n";
                my @lines = split(/\n/, $pattern_rule{$key});
                foreach my $line (@lines) {
                    print "  $line\n";
                }
            }
            $found = 1;
            print "\n";
        }
    }

    # Check pseudo rules
    for my $key (keys %pseudo_deps) {
        my ($base, $t) = split(/\t/, $key);
        if ($t eq $target) {
            print "Target: $target (phony/pseudo)\n";
            print "Base directory: $base\n";
            my @deps = @{$pseudo_deps{$key} || []};
            if (@deps) {
                print "Dependencies:\n";
                foreach my $dep (@deps) {
                    print "  $dep\n";
                }
            } else {
                print "No dependencies\n";
            }
            if (exists $pseudo_rule{$key}) {
                print "Rule:\n";
                my @lines = split(/\n/, $pseudo_rule{$key});
                foreach my $line (@lines) {
                    print "  $line\n";
                }
            }
            $found = 1;
            print "\n";
        }
    }

    unless ($found) {
        print "No rule found for target: $target\n";
    }
}

# Job-master main loop - runs in forked child with full Makefile data
# This allows intelligent dependency-aware parallelization
sub run_job_master {
    my ($num_workers, $bin_dir) = @_;

    use IO::Socket::INET;
    use IO::Select;
    use POSIX qw(:sys_wait_h);
    use Cwd qw(abs_path getcwd);

    # Set project root to current directory at job-master startup
    # All target paths will be computed relative to this
    $project_root = getcwd();

    # Job-master should ignore SIGINT (Ctrl-C)
    # The CLI process handles cancellation - job-master should keep running
    $SIG{INT} = 'IGNORE';

    # Job-master has access to all parsed Makefile data:
    # Bring package-level variables into scope
    our %fixed_deps;
    our %pattern_deps;
    our %pseudo_deps;
    our %fixed_rule;
    our %pattern_rule;
    our %pseudo_rule;
    our %MV;  # Variables
    our $makefile;  # Current makefile path
    our %rules;  # All rules (for is_build_relevant and stale checking)
    our %targets;  # All targets
    our $ssh_host;  # SSH host for remote workers
    our $remote_cd;  # Remote directory for SSH workers

    our @workers;
    our %worker_status;  # socket => {ready => 0/1, task_id => N}

    # Use dummy worker for dry-run mode, normal worker otherwise
    my $worker_script = $dry_run_mode ? "$bin_dir/smak-worker-dry" : "$bin_dir/smak-worker";
    warn "DEBUG: dry_run_mode=$dry_run_mode, worker_script=$worker_script\n" if $ENV{SMAK_DEBUG};
    die "Worker script not found: $worker_script\n" unless -x $worker_script;

    # Workers always connect to localhost (either directly or via SSH tunnel)
    if ($ssh_host) {
        vprint "SSH mode: workers will connect via reverse port forwarding\n";
    }

    # Create socket server for master connections
    my $master_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => 1,
        Reuse     => 1,
    ) or die "Cannot create master server: $!\n";

    my $master_port = $master_server->sockport();
    vprint "Job-master master server on port $master_port\n";

    # Create socket server for workers
    my $worker_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => $num_workers,
        Reuse     => 1,
    ) or die "Cannot create worker server: $!\n";

    my $worker_port = $worker_server->sockport();
    vprint "Job-master worker server on port $worker_port\n";

    # Create socket server for observers (monitoring/attach)
    my $observer_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => 5,  # Allow multiple observers
        Reuse     => 1,
    ) or die "Cannot create observer server: $!\n";

    my $observer_port = $observer_server->sockport();
    vprint "Job-master observer server on port $observer_port\n";

    # Write ports to file for smak-attach to find
    my $port_dir = get_port_file_dir();
    my $port_file = "$port_dir/smak-jobserver-$$.port";
    open(my $port_fh, '>', $port_file) or warn "Cannot write port file: $!\n";
    if ($port_fh) {
        print $port_fh "$observer_port\n";
        print $port_fh "$master_port\n";
        close($port_fh);

        # Create symlink in current directory for easy access
        my $local_link = ".smak.connect";
        unlink($local_link) if -l $local_link;  # Remove old symlink if exists
        if (!symlink($port_file, $local_link)) {
            warn "Warning: Cannot create symlink $local_link: $!\n" if $ENV{SMAK_DEBUG};
        }
    }

    our @observers;  # List of connected observers

    # Detect and connect to FUSE filesystem monitor
    my $fuse_socket;
    my %inode_cache;  # inode => path
    my %pending_path_requests;  # inode => 1 (waiting for resolution)
    my %file_modifications;  # path => {workers => [pids], last_op => time}
    our %dirty_files;  # Manually marked dirty files: path => 1 (global for cmd_dirty)
    my $watch_client;  # Client socket to send watch notifications to

    our %worker_env;

    # Helper to check if a file path is relevant to the build
    sub is_build_relevant {
        my ($path) = @_;

        # In debug mode, show everything
        return 1 if $ENV{SMAK_DEBUG};

        # Skip .git files and directories
        return 0 if $path =~ /\/\.git\//;
        return 0 if $path =~ /\.git$/;

        # Skip lock files and temp files
        return 0 if $path =~ /\.lock$/;
        return 0 if $path =~ /~$/;
        return 0 if $path =~ /\.tmp$/;
        return 0 if $path =~ /\.swp$/;

        # Get just the filename (might be absolute path)
        my $file = $path;
        $file =~ s{^.*/}{};  # Remove directory path

        # Check if it's a known target or has a rule
        return 1 if exists $rules{$file};
        return 1 if exists $targets{$file};

        # Check if it matches any pattern in rules (for wildcards)
        for my $rule_pattern (keys %rules) {
            if ($file =~ /$rule_pattern/) {
                return 1;
            }
        }

        # Check common source file extensions
        return 1 if $path =~ /\.(c|cc|cpp|cxx|C|h|hpp|hxx|H)$/;
        return 1 if $path =~ /\.(f|f90|f95|F|F90|F95)$/;
        return 1 if $path =~ /\.(s|S|asm)$/;
        return 1 if $path =~ /\.(java|py|pl|pm|rb)$/;
        return 1 if $path =~ /\.(o|a|so|dylib|dll)$/;

        # Default to not showing
        return 0;
    }

    sub send_env {
	my ($worker) = @_;
	
	print $worker "ENV_START\n";
	for my $key (keys %worker_env) {
	    print $worker "ENV $key=$worker_env{$key}\n";
	}
	print $worker "ENV_END\n";
    }
    
    my $fuse_mountpoint;
    our $has_fuse = 0;
    # Check if FUSE was detected early (before makefile parsing)
    my $fuse_early_detected = $ENV{SMAK_FUSE_DETECTED} || 0;

    if (my ($mountpoint, $fuse_port) = detect_fuse_monitor(abs_path('.'))) {
        $fuse_mountpoint = $mountpoint;
        $has_fuse = 1;
        print STDERR "Detected FUSE filesystem at $mountpoint, port $fuse_port\n" if $ENV{SMAK_DEBUG};
        unless ($fuse_early_detected) {
            # Only print this if we didn't already detect FUSE early
            print STDERR "Auto-rescan disabled (FUSE provides file notifications). Use 'rescan -auto' to enable if needed.\n";
        }
        # Connect to FUSE monitor
        $fuse_socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $fuse_port,
            Proto    => 'tcp',
            Timeout  => 5,
        );
        if ($fuse_socket) {
            $fuse_socket->autoflush(1);
            vprint "Connected to FUSE monitor\n";
        } else {
            print STDERR "Warning: Could not connect to FUSE monitor on port $fuse_port: $!\n";
        }
    } else {
        print STDERR "No FUSE monitor detected\n" if $ENV{SMAK_DEBUG};
        print STDERR "Auto-rescan enabled by default (no FUSE file notifications)\n" if $ENV{SMAK_DEBUG};
    }

    # Wait for initial master connection
    vprint "Waiting for master connection...\n";
    our $master_socket = $master_server->accept();
    die "Failed to accept master connection\n" unless $master_socket;
    $master_socket->autoflush(1);
    vprint "Master connected
";

    # Receive environment from master
    while (my $line = <$master_socket>) {
        chomp $line;
        last if $line eq 'ENV_END';
        if ($line =~ /^ENV (\w+)=(.*)$/) {
            $worker_env{$1} = $2;
        }
    }
    vprint "Job-master received environment\n";

    # Get server info for worker process names
    my $server_pid = $$;
    chomp(my $hostname = `hostname -s 2>/dev/null` || 'localhost');

    # Spawn workers
    for (my $i = 0; $i < $num_workers; $i++) {
        my $pid = fork();
        die "Cannot fork worker: $!\n" unless defined $pid;

        if ($pid == 0) {
            # Child - run worker
            set_process_name("smak-worker for $hostname:$server_pid");

            # Close inherited sockets that worker doesn't use
            # This ensures proper reference counting so job-server sees disconnects correctly
            close($master_socket) if $master_socket;
            close($master_server);
            close($observer_server);
            close($worker_server);  # Worker connects as client, doesn't use listening socket

            if ($ssh_host) {
		my $local_path = getcwd();
		$local_path =~ s=^$fuse_mountpoint/== if defined $fuse_mountpoint;
                # SSH mode: launch worker on remote host with reverse port forwarding
                # Use -R to tunnel remote port back to local worker_port
                my $remote_port = 30000 + int(rand(10000));  # Random port 30000-39999
                my @ssh_cmd = ('ssh', '-n', '-R', "$remote_port:127.0.0.1:$worker_port", $ssh_host);
                # Construct remote worker command
                # Use PATH that includes smak directory, or absolute path if SMAK_REMOTE_PATH is set
                my $remote_worker = $dry_run_mode ? 'smak-worker-dry' : 'smak-worker';
                my $remote_cmd;
                if ($ENV{SMAK_REMOTE_PATH}) {
                    # Use explicit path from environment
                    $remote_cmd = "$ENV{SMAK_REMOTE_PATH}/$remote_worker";
                } else {
                    # Try to find smak in PATH, or use worker from bin_dir
                    $remote_cmd = "PATH=$bin_dir:\$PATH $remote_worker";
                }
                if ($remote_cd) {
                    push @ssh_cmd, "$remote_cmd -cd $remote_cd/$local_path 127.0.0.1:$remote_port";
                } else {
                    push @ssh_cmd, "$remote_cmd 127.0.0.1:$remote_port";
                }
                exec(@ssh_cmd);
                die "Failed to exec SSH worker: $!\n";
            } else {
                # Local mode - call worker routine directly
                # This avoids fork+exec overhead by calling the routine in the same process
                use SmakWorker;
                SmakWorker::run_worker('127.0.0.1', $worker_port, $dry_run_mode);
                # Should not reach here - run_worker() exits
                exit 99;
            }
        }
        vprint "Spawned worker $i (PID $pid)\n";
    }

    # Set up IO::Select for multiplexing
    $worker_server->blocking(0);
    $observer_server->blocking(0);
    $master_server->blocking(0);
    my $select = IO::Select->new($worker_server, $observer_server, $master_socket, $master_server);
    $select->add($fuse_socket) if $fuse_socket;
    my $workers_connected = 0;
    my $startup_timeout = 10;
    my $start_time = time();

    # Wait for all workers to connect
    while ($workers_connected < $num_workers) {
        if (time() - $start_time > $startup_timeout) {
            die "Timeout waiting for workers to connect\n";
        }

        my @ready = $select->can_read(0.1);
        for my $socket (@ready) {
            if ($socket == $worker_server) {
                my $worker = $worker_server->accept();
                if ($worker) {
                    $worker->autoflush(1);
                    # Disable Nagle's algorithm for low latency
                    use Socket qw(IPPROTO_TCP TCP_NODELAY);
                    setsockopt($worker, IPPROTO_TCP, TCP_NODELAY, 1);
                    # Read READY signal
                    my $ready = <$worker>;
                    chomp $ready if defined $ready;
                    if ($ready eq 'READY') {
                        push @workers, $worker;
                        $worker_status{$worker} = {ready => 0, task_id => 0};  # Not ready until env sent
                        $select->add($worker);
                        $workers_connected++;
                        vprint "Worker connected ($workers_connected/$num_workers)\n";

                        # Send environment
			send_env($worker);

                        # Now worker is ready to receive tasks
                        $worker_status{$worker}{ready} = 1;
                        vprint "Worker $workers_connected environment sent, now ready\n";
                    }
                }
            }
        }
    }

    vprint "All workers ready. Job-master entering listen loop.\n";
    print $master_socket "JOBSERVER_WORKERS_READY\n";

    # Job queue and dependency tracking - use 'our' to avoid closure warnings
    our @job_queue;  # Queue of jobs to dispatch
    our %running_jobs;  # task_id => {target, worker, dir, command, started}
    our %completed_targets;  # target => 1 (successfully built targets)
    our %phony_ran_this_session;  # target => 1 (phony targets that ran successfully this session)
    our %failed_targets;  # target => exit_code (failed targets)
    our %pending_composite;  # composite targets waiting for dependencies
                            # target => {deps => [list], master_socket => socket}
    our %currently_dispatched;  # target => task_id (防 duplicate dispatch tracking)
    our $next_task_id = 1;
    # Auto-rescan: Enable by default when FUSE is NOT detected
    # When FUSE is present, it provides file change notifications
    # When FUSE is absent, we need periodic polling to detect changes
    # Disable in dry-run mode since targets are never actually built
    our $auto_rescan = $dry_run_mode ? 0 : ($has_fuse ? 0 : 1);

    # Spawn scanner process if auto_rescan is enabled
    # Scanner runs in background and sends events using same protocol as FUSE
    our $scanner_socket;
    our $scanner_pid;
    if ($auto_rescan) {
        use Socket;
        socketpair(my $parent_sock, my $child_sock, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair failed: $!";
        $parent_sock->autoflush(1);
        $child_sock->autoflush(1);

        my $job_master_pid = $$;  # Save job-master PID before forking
        $scanner_pid = fork();
        die "fork scanner failed: $!" unless defined $scanner_pid;

        if ($scanner_pid == 0) {
            # Child process - run scanner
            close($parent_sock);
            close($master_socket) if $master_socket;
            close($master_server);
            close($observer_server);
            close($worker_server);
            for my $w (@workers) {
                close($w);
            }
            auto_rescan_watcher($child_sock, \$makefile, $job_master_pid);
            exit 0;
        } else {
            # Parent process - keep parent socket
            close($child_sock);
            $scanner_socket = $parent_sock;
            $select->add($scanner_socket);
            vprint "Auto-rescan scanner spawned (PID $scanner_pid)\n";
        }
    }

    # FUSE auto-clear: Enable by default when FUSE is detected
    # When enabled, FUSE events automatically clear failed targets (like rescan -auto)
    # When disabled (unwatch), FUSE events are collected but manual rescan is needed
    our $fuse_auto_clear = $has_fuse ? 1 : 0;

    # Track last FUSE debug message to suppress consecutive duplicates
    my $last_fuse_debug_msg = '';

    # Helper functions
    sub process_command {
        my ($cmd) = @_;
        return '' unless defined $cmd;

        # Process each line of multi-line commands
        my @processed;
        for my $line (split /\n/, $cmd) {
            next unless $line =~ /\S/;  # Skip empty lines

            # Check for - (ignore errors) prefix before stripping
            my $ignore_errors = ($line =~ /^\s*-/);

            # Strip @ (silent) and - (ignore errors) prefixes
            $line =~ s/^\s*[@-]+//;

            next unless $line =~ /\S/;

            # If command had -, wrap it so errors don't stop the chain
            if ($ignore_errors) {
                push @processed, "($line || true)";
            } else {
                push @processed, $line;
            }
        }

        # Join multiple commands with && so they execute sequentially
        # Commands with - prefix are wrapped in (cmd || true) to not break the chain
        return join(" && ", @processed);
    }

    # Extract directories referenced in a command that might have build rules
    # Returns list of directory names that have rules and should be implicit dependencies
    sub extract_directory_deps {
        my ($command, $makefile) = @_;
        return () unless defined $command && $command =~ /\S/;

        my %dirs;

        # Look for patterns like "mv foo.d dep/foo.d" or references to "somedir/somefile"
        # Extract directory components from destination paths
        while ($command =~ m{\b(?:mv|cp)\s+\S+\s+(\S+/)[^\s/]*}g) {
            my $dir = $1;
            $dir =~ s{/$}{};  # Remove trailing slash
            $dirs{$dir} = 1 if $dir =~ /^\w+$/;  # Only simple directory names
        }

        # Filter to directories that have build rules
        my @result;
        for my $dir (keys %dirs) {
            my $key = "$makefile\t$dir";
            if (exists $fixed_deps{$key} || exists $pattern_deps{$key} || exists $pseudo_deps{$key}) {
                push @result, $dir;
            }
        }

        return @result;
    }

    # Split a command string into external commands and trailing builtins
    # Returns (external_parts_arrayref, trailing_builtins_arrayref)
    sub split_command_parts {
        my ($command) = @_;
        return ([], []) unless defined $command && $command =~ /\S/;

        my @cmd_parts = split(/\s*&&\s*/, $command);
        my @external_parts;
        my @trailing_builtins;
        my $in_trailing_builtins = 0;

        # Scan from the end to find trailing built-in commands
        for my $i (reverse 0 .. $#cmd_parts) {
            my $part = $cmd_parts[$i];
            $part =~ s/^\s+|\s+$//g;
            my $clean_part = $part;
            $clean_part =~ s/^[@-]+//;  # Strip prefixes for checking

            # Check if it's a built-in command
            if ($clean_part =~ /^\s*(rm|mkdir|mv|cp|echo|true|false|cd|:|touch)\b/) {
                if (!$in_trailing_builtins && $i == $#cmd_parts) {
                    # Found trailing built-in
                    unshift @trailing_builtins, $part;
                    $in_trailing_builtins = 1;
                } elsif ($in_trailing_builtins) {
                    # Continue collecting trailing built-ins
                    unshift @trailing_builtins, $part;
                } else {
                    # Built-in in the middle, can't optimize
                    unshift @external_parts, $part;
                }
            } else {
                # Non-builtin command
                $in_trailing_builtins = 0;  # Stop collecting trailing builtins
                unshift @external_parts, $part;
            }
        }

        return (\@external_parts, \@trailing_builtins);
    }

    sub expand_job_command {
        my ($cmd, $target, $deps_ref) = @_;
        return '' unless defined $cmd && $cmd =~ /\S/;

        my @deps = $deps_ref ? @$deps_ref : ();

        # Debug: Show what deps we're expanding with
        if ($ENV{SMAK_DEBUG} && @deps) {
            print STDERR "DEBUG expand_job_command: target='$target', deps=(" . join(", ", @deps) . ")\n";
        }

        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($cmd);
        # Expand variables
        my $expanded = expand_vars($converted);

        # Determine first prerequisite ($<), filtering out .dirstamp and .deps/ files
        # These are directory marker dependencies that should not be used as source files
        my $first_prereq = '';
        for my $dep (@deps) {
            next if $dep =~ /dirstamp$/;   # Skip .dirstamp files
            next if $dep =~ /\.deps\//;     # Skip .deps/ directory markers
            $first_prereq = $dep;
            last;
        }

        # Expand automatic variables
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$first_prereq/g;               # $< = first prerequisite (excluding dirstamp)
        $expanded =~ s/\$\^/join(' ', @deps)/ge;          # $^ = all prerequisites

        return $expanded;
    }

    sub is_phony_target {
        my ($target) = @_;

        # Check if target is in any .PHONY dependencies (check all makefiles)
        for my $key (keys %pseudo_deps) {
            if ($key =~ /\t\.PHONY$/) {
                my @phony_targets = @{$pseudo_deps{$key}};
                return 1 if grep { $_ eq $target } @phony_targets;
            }
        }

        # Auto-detect common phony target names
        if ($target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/) {
            return 1;
        }

        return 0;
    }

    sub is_target_pending {
        my ($target) = @_;

        # Phony targets should never be considered pending from cache
        # They must always run when requested
        if (is_phony_target($target)) {
            # Check if actively running/queued
            # If status is 'done', remove from in_progress so it can run again
            if (exists $in_progress{$target}) {
                my $status = $in_progress{$target} // 'undef';
                if ($status eq 'done') {
                    # Phony target completed, allow it to be queued again
                    delete $in_progress{$target};
                    print STDERR "DEBUG is_target_pending: '$target' was done, removed from in_progress [PHONY]\n" if $ENV{SMAK_DEBUG};
                    return 0;
                }
                # Still actively running or in another non-done state
                print STDERR "DEBUG is_target_pending: '$target' in in_progress (status='$status') [PHONY]\n" if $ENV{SMAK_DEBUG};
                return 1;
            }

            for my $job (@job_queue) {
                if ($job->{target} eq $target) {
                    print STDERR "DEBUG is_target_pending: '$target' in job_queue [PHONY]\n" if $ENV{SMAK_DEBUG};
                    return 1;
                }
            }

            for my $task_id (keys %running_jobs) {
                if ($running_jobs{$task_id}{target} eq $target) {
                    print STDERR "DEBUG is_target_pending: '$target' in running_jobs [PHONY]\n" if $ENV{SMAK_DEBUG};
                    return 1;
                }
            }

            print STDERR "DEBUG is_target_pending: '$target' NOT pending [PHONY]\n" if $ENV{SMAK_DEBUG};
            return 0;
        }

        # Check if already completed
        if (exists $completed_targets{$target}) {
            print STDERR "DEBUG is_target_pending: '$target' in completed_targets\n" if $ENV{SMAK_DEBUG};
            return 1;
        }

        # Check if in progress (includes queued, running, and pending composite targets)
        if (exists $in_progress{$target}) {
            my $status = $in_progress{$target} // 'undef';
            print STDERR "DEBUG is_target_pending: '$target' in in_progress (status='$status')\n" if $ENV{SMAK_DEBUG};
            return 1;
        }

        # Check if already in queue
        for my $job (@job_queue) {
            if ($job->{target} eq $target) {
                print STDERR "DEBUG is_target_pending: '$target' in job_queue\n" if $ENV{SMAK_DEBUG};
                return 1;
            }
        }

        # Check if currently running
        for my $task_id (keys %running_jobs) {
            if ($running_jobs{$task_id}{target} eq $target) {
                print STDERR "DEBUG is_target_pending: '$target' in running_jobs\n" if $ENV{SMAK_DEBUG};
                return 1;
            }
        }

        print STDERR "DEBUG is_target_pending: '$target' NOT pending\n" if $ENV{SMAK_DEBUG};
        return 0;
    }

    sub broadcast_observers {
        my ($msg) = @_;
        for my $obs (@observers) {
            print $obs "$msg\n";
        }
    }

    sub send_status {
        my ($socket) = @_;
        print $socket "STATUS_START\n";
        print $socket "WORKERS " . scalar(@workers) . "\n";
        print $socket "QUEUED " . scalar(@job_queue) . "\n";
        print $socket "RUNNING " . scalar(keys %running_jobs) . "\n";
        print $socket "STATUS_END\n";
    }

    sub shutdown_workers {
        for my $worker (@workers) {
            print $worker "SHUTDOWN\n";
        }
    }
    
    sub wait_for_worker_done {
	my ($ready_worker) = @_;
	print STDERR "wait_for_worker_done: NIY\n";
    }

    # Verify that a target file actually exists on disk
    # Retries with fsync if needed to handle filesystem buffering delays
    # Handles compound targets (e.g., "parse.cc&parse.h") by checking all parts
    sub verify_target_exists {
        my ($target, $dir) = @_;

        # Handle compound targets (multi-output pattern rules)
        # A compound target like "parse.cc&parse.h" means both files must exist
        if ($target =~ /&/) {
            my @parts = split(/&/, $target);
            for my $part (@parts) {
                return 0 unless verify_target_exists($part, $dir);
            }
            return 1;
        }

        # Construct full path
        my $target_path = $dir ? "$dir/$target" : $target;

        # First quick check
        return 1 if -e $target_path;

        # FUSE filesystems may have significant caching delays
        # Use longer retries and delays for FUSE
        my $max_attempts = $has_fuse ? 10 : 3;
        my $delay_multiplier = $has_fuse ? 0.05 : 0.01;  # 50ms vs 10ms per attempt

        # If not found, try syncing the directory and retry
        # This handles cases where the file is buffered but not yet visible
        for my $attempt (1..$max_attempts) {
            # Sync the directory to flush filesystem buffers
            if ($dir && -d $dir) {
                # Open and sync the directory
                if (opendir(my $dh, $dir)) {
                    # On Linux, we can't fsync a directory handle directly in Perl
                    # But closing will flush some buffers
                    closedir($dh);
                }
            }

            # Delay to allow filesystem to catch up
            # FUSE: 50ms, 100ms, 150ms, ... up to 500ms (total 2.75s)
            # Local: 10ms, 20ms, 30ms (total 60ms)
            select(undef, undef, undef, $delay_multiplier * $attempt);

            return 1 if -e $target_path;

            vprint "Warning: Target '$target' not found at '$target_path', retry $attempt/$max_attempts\n";
        }

        # Final check
        if (-e $target_path) {
            print STDERR "Target '$target' found after retries\n";
            return 1;
        }

        vprint "ERROR: Target '$target' does not exist at '$target_path' after task completion\n";
        return 0;
    }

    # Compute layer for a target based on its dependencies
    # Layer 0 = leaves (no buildable deps), higher layers depend on lower layers
    # Returns the layer number for this target
    sub compute_target_layer {
        my ($deps_ref) = @_;
        my $max_dep_layer = -1;

        for my $dep (@$deps_ref) {
            next unless defined $dep && $dep =~ /\S/;
            # If dependency has a layer, it needs building
            if (exists $target_layer{$dep}) {
                my $dep_layer = $target_layer{$dep};
                $max_dep_layer = $dep_layer if $dep_layer > $max_dep_layer;
            }
            # Source files (no layer) don't contribute
        }

        # Our layer is one above our highest dependency
        return $max_dep_layer + 1;
    }

    # Add a job to the appropriate layer
    sub add_job_to_layer {
        my ($job, $layer) = @_;

        # Track the target's layer
        $target_layer{$job->{target}} = $layer;

        # Update max layer if needed
        if ($layer > $max_dispatch_layer) {
            $max_dispatch_layer = $layer;
        }

        # Initialize layer array if needed
        $job_layers[$layer] //= [];

        # Add job to layer
        push @{$job_layers[$layer]}, $job;

        # Also add to flat queue for compatibility during transition
        push @job_queue, $job;

        print STDERR "DEBUG: Added '$job->{target}' to layer $layer\n" if $ENV{SMAK_DEBUG};
    }

    # Recursively queue a target and all its dependencies
    our @recurse_log; # for debug
    our $recurse_limit = 20;
    sub queue_target_recursive {
        my ($target, $dir, $msocket, $depth, $prefix) = @_;
        $msocket ||= $master_socket;  # Use provided or fall back to global
        $prefix //= '';  # Path prefix from project root (e.g., "ivlpp" for targets in ivlpp/)

        # Compute full target path for storage/tracking
        my $full_target = target_with_prefix($target, $prefix);

        # FIRST: Skip source control files entirely (prevents infinite recursion)
        # Check for ,v suffix (RCS) or other source control patterns
        for my $ext (keys %source_control_extensions) {
            if ($target =~ /\Q$ext\E/) {
                print STDERR "Skipping source control target: $target (contains $ext)\n" if $ENV{SMAK_DEBUG};
                return;
            }
        }

        # Check for source control directory recursion (RCS/RCS/, SCCS/SCCS/, s.s., etc.)
        if (has_source_control_recursion($target)) {
            print STDERR "Skipping recursive source control target: $target\n" if $ENV{SMAK_DEBUG};
            return;
        }

        # Skip inactive implicit rule patterns (e.g., RCS/SCCS if not present in project)
        if (is_inactive_pattern($target)) {
            print STDERR "Skipping inactive pattern target: $target\n" if $ENV{SMAK_DEBUG};
            return;
        }

        # Skip if already handled (use full_target for tracking)
        return if is_target_pending($full_target);

        # Check if target is assumed (marked as already built)
        if (exists $assumed_targets{$full_target}) {
            $completed_targets{$full_target} = 1;
            $in_progress{$full_target} = "done";
            warn "Target '$full_target' is assumed (marked as already built), skipping\n" if $ENV{SMAK_DEBUG};
            return;
        }

	$recurse_log[$depth] = "${dir}:$full_target";

        # Lookup dependencies
        my $key = "$makefile\t$target";
        my @deps;
        my $rule = '';
        my $stem = '';

        my $has_fixed_deps = 0;
        if (exists $fixed_deps{$key}) {
            @deps = @{$fixed_deps{$key} || []};
            $rule = $fixed_rule{$key} || '';
            $has_fixed_deps = 1;
        } elsif (exists $pattern_deps{$key}) {
            my $deps_ref = $pattern_deps{$key} || [];
            my $rule_ref = $pattern_rule{$key} || '';
            # Handle both single variant and multiple variants
            # For deps: if first element is an array, we have multiple variants, use first
            @deps = (ref($deps_ref) eq 'ARRAY' && ref($deps_ref->[0]) eq 'ARRAY') ?
                    @{$deps_ref->[0]} :
                    (ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ());
            # For rule: if it's an array, use first variant
            $rule = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[0] : $rule_ref;
        } elsif (exists $pseudo_deps{$key}) {
            @deps = @{$pseudo_deps{$key} || []};
            $rule = $pseudo_rule{$key} || '';
        }

        # Track which pattern rule matched (for multi-output detection)
        my $matched_pattern_key;

        # If we have fixed deps but no rule, try suffix rules first, then pattern rules
        if ($has_fixed_deps && !($rule && $rule =~ /\S/)) {
            print STDERR "Target '$target' in fixed_deps but no rule, checking for suffix/pattern rules\n" if $ENV{SMAK_DEBUG};

            # Try suffix rules FIRST (they take precedence over built-in pattern rules)
            if ($target =~ /^(.+)(\.[^.\/]+)$/) {
                my ($base, $target_suffix) = ($1, $2);
                for my $source_suffix (@suffixes) {
                    my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                    if (exists $suffix_rule{$suffix_key}) {
                        my $source = "$base$source_suffix";
                        my $resolved_source = resolve_vpath($source, $dir);
                        if (-f $resolved_source || -f "$dir/$source") {
                            $stem = $base;
                            push @deps, $source unless grep { $_ eq $source } @deps;
                            $rule = $suffix_rule{$suffix_key};
                            my $suffix_deps_ref = $suffix_deps{$suffix_key};
                            if ($suffix_deps_ref && @$suffix_deps_ref) {
                                my @suffix_deps_expanded = map {
                                    my $d = $_;
                                    $d =~ s/%/$stem/g;
                                    $d;
                                } @$suffix_deps_ref;
                                push @deps, @suffix_deps_expanded;
                            }
                            print STDERR "Using suffix rule $source_suffix$target_suffix for $target (job master)\n" if $ENV{SMAK_DEBUG};
                            last;
                        }
                    }
                }
            }

            # Fall back to pattern rules if no suffix rule found
            if (!($rule && $rule =~ /\S/)) {
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        # Found matching pattern rule - use its rule, keep fixed deps
                        my $rule_ref = $pattern_rule{$pkey} || '';
                        # Handle both single rule (string) and multiple variants (array)
                        $rule = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[0] : $rule_ref;
                        $stem = $1;  # Save stem for $* expansion
                        $matched_pattern_key = $pkey;  # Save for multi-output detection
                        print STDERR "Found pattern rule '$pattern' for target '$target' (stem='$stem')\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
            }  # End of pattern rule fallback block
        }

        # If still no deps/rule, try suffix rules first, then pattern rules
        if (!$has_fixed_deps && !@deps) {
            # Try suffix rules FIRST (they take precedence over built-in pattern rules)
            if ($target =~ /^(.+)(\.[^.\/]+)$/) {
                my ($base, $target_suffix) = ($1, $2);
                for my $source_suffix (@suffixes) {
                    my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                    if (exists $suffix_rule{$suffix_key}) {
                        my $source = "$base$source_suffix";
                        my $resolved_source = resolve_vpath($source, $dir);
                        # Check if source exists OR can be built (has a rule)
                        my $source_exists = (-f $resolved_source || -f "$dir/$source");
                        my $source_key = "$makefile\t$source";
                        my $source_can_be_built = exists $fixed_rule{$source_key} || exists $pattern_rule{$source_key};
                        if ($source_exists || $source_can_be_built) {
                            $stem = $base;
                            push @deps, $source unless grep { $_ eq $source } @deps;
                            $rule = $suffix_rule{$suffix_key};
                            my $suffix_deps_ref = $suffix_deps{$suffix_key};
                            if ($suffix_deps_ref && @$suffix_deps_ref) {
                                my @suffix_deps_expanded = map {
                                    my $d = $_;
                                    $d =~ s/%/$stem/g;
                                    $d;
                                } @$suffix_deps_ref;
                                push @deps, @suffix_deps_expanded;
                            }
                            print STDERR "Using suffix rule $source_suffix$target_suffix for $target (source " . ($source_exists ? "exists" : "can be built") . ")\n" if $ENV{SMAK_DEBUG};
                            last;
                        }
                    }
                }
            }

            # Fall back to pattern rules if no suffix rule found
            if (!($rule && $rule =~ /\S/)) {
            PATTERN_LOOP: for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        my $deps_ref = $pattern_deps{$pkey} || [];
                        my $rule_ref = $pattern_rule{$pkey} || '';
                        $stem = $1;  # Save stem for $* expansion
                        $matched_pattern_key = $pkey;  # Save for multi-output detection

                        # Check if we have multiple variants (array of arrays)
                        if (ref($deps_ref) eq 'ARRAY' && @$deps_ref && ref($deps_ref->[0]) eq 'ARRAY') {
                            # Multiple variants - find one whose source file exists
                            my $found_variant = 0;
                            for my $vi (0 .. $#$deps_ref) {
                                my @variant_deps = @{$deps_ref->[$vi]};
                                # Expand stem and makefile variables in deps
                                @variant_deps = map {
                                    my $d = $_;
                                    $d =~ s/%/$stem/g;
                                    $d = expand_vars($d);  # Expand $(srcdir) etc.
                                    # Also expand $MV{VAR} format
                                    while ($d =~ /\$MV\{([^}]+)\}/) {
                                        my $var = $1;
                                        my $val = $MV{$var} // '';
                                        $d =~ s/\$MV\{\Q$var\E\}/$val/;
                                    }
                                    $d;
                                } @variant_deps;
                                my @resolved_deps = map { resolve_vpath($_, $dir) } @variant_deps;
                                # Check if the first dep (source file) exists or can be built
                                my $first_dep = $variant_deps[0] // '';
                                my $first_dep_key = "$makefile\t$first_dep";
                                my $source_exists = @resolved_deps && -f $resolved_deps[0];
                                my $source_can_be_built = exists $fixed_rule{$first_dep_key} || exists $pattern_rule{$first_dep_key};
                                if ($source_exists || $source_can_be_built) {
                                    @deps = @resolved_deps;
                                    $rule = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[$vi] : $rule_ref;
                                    print STDERR "Matched pattern rule '$pattern' variant $vi for target '$target' (stem='$stem', source " . ($source_exists ? "exists" : "can be built") . ")\n" if $ENV{SMAK_DEBUG};
                                    $found_variant = 1;
                                    last PATTERN_LOOP;
                                }
                            }
                            # If no variant's source exists, skip this pattern rule
                            # (don't apply pattern rules when source files are missing)
                            if (!$found_variant) {
                                print STDERR "Skipping pattern rule '$pattern' for target '$target' (stem='$stem', no source file exists)\n" if $ENV{SMAK_DEBUG};
                                $matched_pattern_key = undef;
                                $stem = '';
                                # Don't break - continue looking for other pattern rules
                            }
                        } else {
                            # Single variant or flat deps array
                            my @candidate_deps = ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ();
                            # Expand stem and makefile variables in deps
                            @candidate_deps = map {
                                my $d = $_;
                                $d =~ s/%/$stem/g;
                                $d = expand_vars($d);  # Expand $(srcdir) etc.
                                # Also expand $MV{VAR} format (internal variable storage)
                                while ($d =~ /\$MV\{([^}]+)\}/) {
                                    my $var = $1;
                                    my $val = $MV{$var} // '';
                                    $d =~ s/\$MV\{\Q$var\E\}/$val/;
                                }
                                $d;
                            } @candidate_deps;
                            my @resolved_deps = map { resolve_vpath($_, $dir) } @candidate_deps;

                            # Check if the first dep (source file) exists or can be built
                            my $first_dep = $candidate_deps[0] // '';
                            my $first_dep_key = "$makefile\t$first_dep";
                            my $source_exists = @resolved_deps && (-f $resolved_deps[0] || -f "$dir/$candidate_deps[0]");
                            my $source_can_be_built = exists $fixed_rule{$first_dep_key} || exists $pattern_rule{$first_dep_key};
                            if (@resolved_deps && !$source_exists && !$source_can_be_built) {
                                # Source file doesn't exist and can't be built, skip this pattern rule
                                print STDERR "Skipping pattern rule '$pattern' for target '$target' (stem='$stem', source '$resolved_deps[0]' not found and no rule to build it)\n" if $ENV{SMAK_DEBUG};
                                $matched_pattern_key = undef;
                                $stem = '';
                                # Don't break - continue looking for other pattern rules
                            } else {
                                @deps = @resolved_deps;
                                $rule = ref($rule_ref) eq 'ARRAY' ? $rule_ref->[0] : $rule_ref;
                                if ($ENV{SMAK_DEBUG} && "@candidate_deps" ne "@deps") {
                                    print STDERR "  Deps after vpath: " . join(", ", @deps) . "\n";
                                }
                                print STDERR "Matched pattern rule '$pattern' for target '$target' (stem='$stem')\n" if $ENV{SMAK_DEBUG};
                                last PATTERN_LOOP;
                            }
                        }
                    }
                }
            }
            }  # End of pattern rule fallback block
        }

        # Get order-only prerequisites (must be built before target but don't affect timestamps)
        # These are specified after | in makefile rules: target: deps | order-only-deps
        my @order_only_deps;
        if (exists $fixed_order_only{$key}) {
            push @order_only_deps, @{$fixed_order_only{$key}};
        }
        if (exists $pattern_order_only{$key}) {
            my $oo_ref = $pattern_order_only{$key};
            if (ref($oo_ref) eq 'ARRAY') {
                # Could be array of arrays (multiple variants) or flat array
                if (@$oo_ref && ref($oo_ref->[0]) eq 'ARRAY') {
                    push @order_only_deps, @{$oo_ref->[0]};
                } else {
                    push @order_only_deps, @$oo_ref;
                }
            }
        }
        if (exists $pseudo_order_only{$key}) {
            push @order_only_deps, @{$pseudo_order_only{$key}};
        }
        # Expand % in order-only deps if we have a stem
        if ($stem && @order_only_deps) {
            @order_only_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @order_only_deps;
        }
        @order_only_deps = grep { $_ ne '' } @order_only_deps;

        # Expand variables in order-only deps
        my @expanded_order_only;
        for my $dep (@order_only_deps) {
            while ($dep =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $dep =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            push @expanded_order_only, $dep if $dep ne '';
        }
        @order_only_deps = @expanded_order_only;

        if (@order_only_deps && $ENV{SMAK_DEBUG}) {
            print STDERR "Target '$target' has order-only prerequisites: " . join(', ', @order_only_deps) . "\n";
        }

        # NOTE: Do NOT add order-only deps to @deps - they should be queued and checked
        # separately but NOT used for $< expansion (first prerequisite)

        # Expand variables in dependencies
        my @expanded_deps;
        for my $dep (@deps) {
            while ($dep =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $dep =~ s/\$MV\{\Q$var\E\}/$val/;
            }
            push @expanded_deps, $dep;
        }
        @deps = @expanded_deps;

        # Filter out source control files from dependencies (prevents recursion)
        my @filtered_deps;
        for my $dep (@deps) {
            my $skip = 0;

            # Check for source control file extensions (,v)
            for my $ext (keys %source_control_extensions) {
                if ($dep =~ /\Q$ext\E/) {
                    print STDERR "Filtering source control dependency: $dep (contains $ext)\n" if $ENV{SMAK_DEBUG};
                    $skip = 1;
                    last;
                }
            }

            # Check for source control directory recursion (RCS/RCS/, SCCS/SCCS/, etc.)
            if (!$skip && has_source_control_recursion($dep)) {
                print STDERR "Filtering recursive source control dependency: $dep\n" if $ENV{SMAK_DEBUG};
                $skip = 1;
            }

            push @filtered_deps, $dep unless $skip;
        }
        @deps = @filtered_deps;

        # For composite targets (no rule but has deps), register them BEFORE queuing dependencies
        # This ensures they can be failed if a dependency fails during recursive queuing
        if (!($rule && $rule =~ /\S/) && @deps > 0) {
            my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
            if (-e $target_path) {
                # File already exists, will mark complete after queuing deps
            } else {
                # Register composite target early so it can be failed by dependencies
                # Split each dep on whitespace first (variables like $MV{PROGRAMS} may expand to multiple targets)
                my @all_single_deps;
                for my $dep (@deps) {
                    push @all_single_deps, split /\s+/, $dep;
                }
                @all_single_deps = grep { /\S/ } @all_single_deps;
                # Apply prefix to deps for tracking
                my @full_single_deps = map { target_with_prefix($_, $prefix) } @all_single_deps;
                # Filter out deps that are already tracked as complete/failed
                # NOTE: Don't filter based on file existence - needs_rebuild check happens later
                my @pending_deps = grep {
                    my $dep = $_;
                    # Skip if already tracked as complete/failed in this session
                    # NOTE: Use expressions, not 'return' - return exits the subroutine!
                    !(exists $completed_targets{$dep} ||
                      exists $phony_ran_this_session{$dep} ||
                      exists $failed_targets{$dep})
                } @full_single_deps;
                if (@pending_deps) {
                    $in_progress{$full_target} = "pending";
                    $pending_composite{$full_target} = {
                        deps => \@pending_deps,
                        master_socket => $msocket,
                    };
                    print STDERR "Pre-registering composite target '$full_target' with " . scalar(@pending_deps) . " pending deps\n" if $ENV{SMAK_DEBUG};
                }
                # If no pending deps, continue to process - deps may still need building
            }
        }

        # Recursively queue each dependency first
        for my $dep (@deps) {
            next if $dep =~ /^\.PHONY$/;
            next if $dep !~ /\S/;
            next if $dep =~ /^["']+$/;

            # Split on whitespace for multiple files in one dep
            for my $single_dep (split /\s+/, $dep) {
                next unless $single_dep =~ /\S/;

                # Check if file exists (relative to working directory)
                my $dep_path = $single_dep =~ m{^/} ? $single_dep : "$dir/$single_dep";
                if (-e $dep_path && !exists $fixed_deps{"$makefile\t$single_dep"}
                    && !exists $pattern_deps{"$makefile\t$single_dep"}
                    && !exists $pseudo_deps{"$makefile\t$single_dep"}) {
                    # File exists with no explicit rule - check if a suffix/pattern rule could build it
                    # If so, we need to recurse to check needs_rebuild()
                    my $has_implicit_rule = 0;

                    # Check suffix rules
                    if ($single_dep =~ /^(.+)(\.[^.\/]+)$/) {
                        my ($base, $target_suffix) = ($1, $2);
                        for my $source_suffix (@suffixes) {
                            my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                            if (exists $suffix_rule{$suffix_key}) {
                                my $source = "$base$source_suffix";
                                my $resolved_source = resolve_vpath($source, $dir);
                                if (-f $resolved_source || -f "$dir/$source") {
                                    $has_implicit_rule = 1;
                                    print STDERR "Dependency '$single_dep' has matching suffix rule $source_suffix$target_suffix\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }
                        }
                    }

                    # Check pattern rules if no suffix rule found
                    if (!$has_implicit_rule) {
                        for my $pkey (keys %pattern_rule) {
                            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                                my $pattern = $1;
                                my $pattern_re = $pattern;
                                $pattern_re =~ s/%/(.+)/g;
                                if ($single_dep =~ /^$pattern_re$/) {
                                    $has_implicit_rule = 1;
                                    print STDERR "Dependency '$single_dep' has matching pattern rule '$pattern'\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }
                        }
                    }

                    # Only mark complete if no implicit rule - it's a pure source file
                    if (!$has_implicit_rule) {
                        my $full_dep = target_with_prefix($single_dep, $prefix);
                        $completed_targets{$full_dep} = 1;
                        print STDERR "Dependency '$full_dep' exists at '$dep_path', no rules, marking complete\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                    # Otherwise fall through to recurse and check needs_rebuild
                }

                # Check if this dependency is part of a compound target (multi-output rule)
                # If so, the compound target must be built first
                my $full_dep = target_with_prefix($single_dep, $prefix);
                if (exists $target_to_compound{$full_dep}) {
                    my $compound = $target_to_compound{$full_dep};
                    print STDERR "DEBUG: Dependency '$full_dep' is part of compound '$compound'\n" if $ENV{SMAK_DEBUG};
                    # Mark as waiting for compound (compound should already be queued)
                    if (!exists $in_progress{$full_dep}) {
                        $in_progress{$full_dep} = "compound:$compound";
                    }
                    next;  # Compound handles this target
                }

                # Recursively queue this dependency
		if ($depth > $recurse_limit) {
		    warn "Recursion queuing ${dir}:$single_dep\nTraceback - \n";
		    my $i = 0;
		    while ($i < $#recurse_log) {
			warn "\t ".$recurse_log[$i++]."\n";
		    }
		    return;
		} else {
		    queue_target_recursive($single_dep, $dir, $msocket, $depth+1, $prefix);
		}
            }
        }

        # Also recursively queue order-only prerequisites
        # These must be built before the target but don't affect $< expansion
        for my $dep (@order_only_deps) {
            next if $dep =~ /^\.PHONY$/;
            next if $dep !~ /\S/;

            for my $single_dep (split /\s+/, $dep) {
                next unless $single_dep =~ /\S/;

                my $dep_path = $single_dep =~ m{^/} ? $single_dep : "$dir/$single_dep";
                if (-e $dep_path && !exists $fixed_deps{"$makefile\t$single_dep"}
                    && !exists $pattern_deps{"$makefile\t$single_dep"}
                    && !exists $pseudo_deps{"$makefile\t$single_dep"}) {
                    # Check for implicit rules (same logic as regular deps)
                    my $has_implicit_rule = 0;

                    # Check suffix rules
                    if ($single_dep =~ /^(.+)(\.[^.\/]+)$/) {
                        my ($base, $target_suffix) = ($1, $2);
                        for my $source_suffix (@suffixes) {
                            my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                            if (exists $suffix_rule{$suffix_key}) {
                                my $source = "$base$source_suffix";
                                my $resolved_source = resolve_vpath($source, $dir);
                                if (-f $resolved_source || -f "$dir/$source") {
                                    $has_implicit_rule = 1;
                                    last;
                                }
                            }
                        }
                    }

                    # Check pattern rules
                    if (!$has_implicit_rule) {
                        for my $pkey (keys %pattern_rule) {
                            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                                my $pattern = $1;
                                my $pattern_re = $pattern;
                                $pattern_re =~ s/%/(.+)/g;
                                if ($single_dep =~ /^$pattern_re$/) {
                                    $has_implicit_rule = 1;
                                    last;
                                }
                            }
                        }
                    }

                    if (!$has_implicit_rule) {
                        my $full_dep = target_with_prefix($single_dep, $prefix);
                        $completed_targets{$full_dep} = 1;
                        print STDERR "Order-only dep '$full_dep' exists at '$dep_path', no rules, marking complete\n" if $ENV{SMAK_DEBUG};
                        next;
                    }
                }

                # Check if this order-only dep is part of a compound target
                my $full_dep = target_with_prefix($single_dep, $prefix);
                if (exists $target_to_compound{$full_dep}) {
                    my $compound = $target_to_compound{$full_dep};
                    print STDERR "DEBUG: Order-only dep '$full_dep' is part of compound '$compound'\n" if $ENV{SMAK_DEBUG};
                    if (!exists $in_progress{$full_dep}) {
                        $in_progress{$full_dep} = "compound:$compound";
                    }
                    next;
                }

                if ($depth > $recurse_limit) {
                    warn "Recursion queuing order-only ${dir}:$single_dep\n";
                    return;
                } else {
                    queue_target_recursive($single_dep, $dir, $msocket, $depth+1, $prefix);
                }
            }
        }

        # Now queue this target if it has a command
        if ($rule && $rule =~ /\S/) {
            # Check if target is .PHONY
            my $is_phony = 0;
            my $phony_key = "$makefile\t.PHONY";
            if (exists $pseudo_deps{$phony_key}) {
                my @phony_targets = @{$pseudo_deps{$phony_key} || []};
                $is_phony = 1 if grep { $_ eq $target } @phony_targets;
            }
            # Auto-detect common phony targets
            if (!$is_phony && $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/) {
                $is_phony = 1;
            }

            # Check if target needs rebuilding (unless it's phony)
            my $needs_build = $is_phony;
            unless ($is_phony) {
                my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
                if (-e $target_path) {
                    # Target exists - check if it needs rebuilding
                    $needs_build = needs_rebuild($target);
                    if ($needs_build) {
                        $stale_targets_cache{$full_target} = time();
                        warn "Target '$full_target' needs rebuilding\n" if $ENV{SMAK_DEBUG};
                    } else {
                        # Target is up-to-date
                        warn "Target '$target' is up-to-date, checking for missing intermediates...\n" if $ENV{SMAK_DEBUG};

                        # Check for missing intermediate dependencies
                        if ($rebuild_missing_intermediates) {
                            # Default behavior (match make): rebuild missing intermediates even if target is up-to-date
                            my $has_missing_intermediates = 0;

                            for my $dep (@deps) {
                                next if $dep =~ /^\.PHONY$/;
                                next if $dep !~ /\S/;

                                # Check if dependency file exists (relative to working directory)
                                my $dep_path = $dep =~ m{^/} ? $dep : "$dir/$dep";
                                if (!-e $dep_path) {
                                    # Check if dependency has a rule (is an intermediate, not a source file)
                                    my $dep_key = "$makefile\t$dep";
                                    my $has_rule = exists $fixed_rule{$dep_key} || exists $pattern_rule{$dep_key};

                                    if ($has_rule) {
                                        warn "smak: Rebuilding missing intermediate '$dep' (even though '$target' is up-to-date)\n";
                                        $has_missing_intermediates = 1;
                                        # Queue the missing intermediate for building
                                        queue_target_recursive($dep, $dir, $msocket, $depth + 1, $prefix);
                                    }
                                }
                            }

                            # If we queued missing intermediates, don't mark target as complete yet
                            if ($has_missing_intermediates) {
                                $in_progress{$full_target} = "pending";
                                return;
                            }
                        } else {
                            # Optimized behavior: notify about missing intermediates but don't rebuild
                            for my $dep (@deps) {
                                next if $dep =~ /^\.PHONY$/;
                                next if $dep !~ /\S/;

                                my $dep_path = $dep =~ m{^/} ? $dep : "$dir/$dep";
                                if (!-e $dep_path) {
                                    my $dep_key = "$makefile\t$dep";
                                    my $has_rule = exists $fixed_rule{$dep_key} || exists $pattern_rule{$dep_key};

                                    if ($has_rule) {
                                        warn "smak: Note: intermediate '$dep' is missing but not rebuilt (target '$target' up-to-date, sources unchanged)\n";
                                    }
                                }
                            }
                        }

                        # Mark target as complete and done
                        $completed_targets{$full_target} = 1;
                        $in_progress{$full_target} = "done";
                        warn "Target '$full_target' is up-to-date, skipping\n" if $ENV{SMAK_DEBUG};
                        delete $stale_targets_cache{$full_target} if exists $stale_targets_cache{$full_target};
                        return;
                    }
                } else {
                    # Target doesn't exist - needs building
                    $needs_build = 1;
                    $stale_targets_cache{$full_target} = time();
                    warn "Target '$full_target' doesn't exist, needs building\n" if $ENV{SMAK_DEBUG};
                }
            }

            # Expand $* with stem if we matched a pattern rule
            if ($stem) {
                $rule =~ s/\$\*/$stem/g;
            }

            # Check if any command line has @ prefix (silent mode)
            # In parallel mode we join commands, so if ANY line has @, we suppress
            # printing the entire combined command to avoid exposing @ prefixed lines
            my $any_silent = 0;
            for my $line (split /\n/, $rule) {
                next unless $line =~ /\S/;  # Skip empty lines
                my $trimmed = $line;
                $trimmed =~ s/^\s+//;  # Remove leading whitespace
                if ($trimmed =~ /^@/) {
                    $any_silent = 1;
                    last;
                }
            }

            # Expand variables FIRST, then process command prefixes
            # (so $(AM_V_at)-rm becomes -rm which then gets processed)
            my $expanded_rule = expand_job_command($rule, $target, \@deps);
            my $processed_rule = process_command($expanded_rule);

            # Handle multi-output pattern rules (e.g., parse%cc parse%h: parse%y)
            # Create a compound pseudo-target (e.g., "parse.cc&parse.h") that holds the build command.
            # Individual targets depend on the compound target.
            my @sibling_targets;
            my $compound_target;
            if ($matched_pattern_key) {
                # matched_pattern_key should be set when we matched a pattern rule
                # Extract just the pattern part (after the tab)
                my ($mf_part, $pattern_part) = split(/\t/, $matched_pattern_key, 2);
                my $target_key = "$makefile\t$pattern_part";
                if (exists $multi_output_siblings{$target_key}) {
                    # This target is part of a multi-output group
                    # Expand all sibling patterns with the current stem
                    @sibling_targets = map { my $s = $_; $s =~ s/%/$stem/g; $s } @{$multi_output_siblings{$target_key}};
                    warn "DEBUG: Multi-output target '$target' has siblings: @sibling_targets\n" if $ENV{SMAK_DEBUG};

                    # Create compound target name from all siblings (sorted for consistency)
                    my @full_siblings = map { target_with_prefix($_, $prefix) } sort @sibling_targets;
                    $compound_target = join('&', @full_siblings);

                    # Register each sibling in target_to_compound map
                    # This allows dependencies on any sibling to find the compound target
                    for my $sibling (@full_siblings) {
                        $target_to_compound{$sibling} = $compound_target;
                        print STDERR "DEBUG: Registered '$sibling' -> compound '$compound_target'\n" if $ENV{SMAK_DEBUG};
                    }

                    # Check if compound target is already queued or in progress
                    if (exists $in_progress{$compound_target}) {
                        my $status = $in_progress{$compound_target};
                        if ($status eq "done") {
                            # Compound already completed - mark this individual target as done
                            $completed_targets{$full_target} = 1;
                            $in_progress{$full_target} = "done";
                            warn "DEBUG: Target '$full_target' already built via compound '$compound_target'\n" if $ENV{SMAK_DEBUG};
                            return;
                        } else {
                            # Compound is building - mark this target as depending on it
                            $in_progress{$full_target} = "compound:$compound_target";
                            warn "DEBUG: Target '$full_target' waiting for compound '$compound_target'\n" if $ENV{SMAK_DEBUG};
                            return;
                        }
                    }

                    # Use compound target for the job instead of individual target
                    # Note: Individual sibling placeholders are queued after the compound job is added
                    $full_target = $compound_target;
                }
            }

            # Compute layer based on dependencies AND order-only deps (all queued recursively)
            # Order-only deps must also be considered since target can't run until they exist
            my $layer = compute_target_layer([@deps, @order_only_deps]);

            # Sanity check: ensure layer is higher than all order-only deps
            # (order-only deps must complete before this target can run)
            for my $oo_dep (@order_only_deps) {
                next unless defined $oo_dep && $oo_dep =~ /\S/;
                for my $single_oo (split /\s+/, $oo_dep) {
                    next unless $single_oo =~ /\S/;
                    if (exists $target_layer{$single_oo} && $target_layer{$single_oo} >= $layer) {
                        my $new_layer = $target_layer{$single_oo} + 1;
                        print STDERR "DEBUG: Bumping layer for '$target' from $layer to $new_layer (order-only dep '$single_oo' is in layer $target_layer{$single_oo})\n" if $ENV{SMAK_DEBUG};
                        $layer = $new_layer;
                    }
                }
            }

            # Split command into external parts and trailing builtins for efficient execution
            my ($external_parts, $trailing_builtins) = split_command_parts($processed_rule);

            # Extract implicit directory dependencies from the command
            # e.g., "mv foo.d dep/foo.d" implies a dependency on "dep" if it has a build rule
            my @implicit_dir_deps = extract_directory_deps($processed_rule, $makefile);
            if (@implicit_dir_deps) {
                print STDERR "DEBUG: Found implicit directory deps for '$target': @implicit_dir_deps\n" if $ENV{SMAK_DEBUG};
                for my $dir_dep (@implicit_dir_deps) {
                    # Queue the directory target if not already handled
                    my $full_dir_dep = target_with_prefix($dir_dep, $prefix);
                    unless (is_target_pending($full_dir_dep) || exists $completed_targets{$full_dir_dep}) {
                        queue_target_recursive($dir_dep, $dir, $msocket, $depth + 1, $prefix);
                    }
                    # Add as order-only dependency (for layer computation)
                    push @order_only_deps, $dir_dep unless grep { $_ eq $dir_dep } @order_only_deps;
                }
                # Recompute layer since we added dependencies
                $layer = compute_target_layer([@deps, @order_only_deps]);
            }

            my $job = {
                target => $full_target,  # Use full path from project root
                dir => '.',  # Verification base (target has full path from project root)
                exec_dir => $dir,  # Where worker should cd to execute command
                command => $processed_rule,  # Keep original for display
                external_commands => $external_parts,  # Commands needing external execution
                trailing_builtins => $trailing_builtins,  # Builtins to run after externals
                silent => $any_silent,  # Track if any command has @ prefix
                siblings => [map { target_with_prefix($_, $prefix) } @sibling_targets],  # Track siblings with full paths
                layer => $layer,  # Store layer for reference
                deps => [map { target_with_prefix($_, $prefix) } @deps],  # Store deps for dispatch lookup (compound targets)
                order_only_deps => [map { target_with_prefix($_, $prefix) } @order_only_deps],  # Store order-only deps
            };
            add_job_to_layer($job, $layer);
            $in_progress{$full_target} = "queued";

            # For multi-output pattern rules: queue placeholder jobs for individual targets in layer N+1
            # These placeholders depend on the compound target and should be marked done when compound completes.
            # If a placeholder ever executes, it's a bug - compound completion should have marked it done first.
            if ($compound_target && @sibling_targets > 1) {
                # Set default post-build hook for compound target: verify all siblings were created
                (my $siblings = $compound_target) =~ s/&/ /g;
                $post_build{$compound_target} = "check-siblings $siblings";
                warn "DEBUG: Set post_build for '$compound_target': $post_build{$compound_target}\n" if $ENV{SMAK_DEBUG};
                my $placeholder_layer = $layer + 1;
                for my $sibling (@sibling_targets) {
                    my $full_sibling = target_with_prefix($sibling, $prefix);
                    my $placeholder_job = {
                        target => $full_sibling,
                        dir => '.',  # Verification base
                        exec_dir => $dir,  # Worker chdir
                        command => "echo 'ASSERTION FAILED: Placeholder for $full_sibling should have been marked done by compound $compound_target' >&2 && exit 1",
                        external_commands => ["echo 'ASSERTION FAILED: Placeholder for $full_sibling should have been marked done by compound $compound_target' >&2 && exit 1"],
                        trailing_builtins => [],
                        silent => 0,
                        siblings => [],
                        layer => $placeholder_layer,
                        deps => [$compound_target],
                        order_only_deps => [],
                        is_compound_placeholder => 1,
                        compound_parent => $compound_target,
                    };
                    add_job_to_layer($placeholder_job, $placeholder_layer);
                    $in_progress{$full_sibling} = "queued";
                    print STDERR "DEBUG: Queued placeholder for '$full_sibling' in layer $placeholder_layer (depends on compound '$compound_target')\n" if $ENV{SMAK_DEBUG};
                }
            } elsif (@sibling_targets > 0) {
                # Non-compound case: mark siblings as depending on this target
                for my $sibling (@sibling_targets) {
                    my $full_sibling = target_with_prefix($sibling, $prefix);
                    if ($full_sibling ne $full_target) {
                        $in_progress{$full_sibling} = "sibling:$full_target";
                    }
                }
            }
            vprint "Queued target: $full_target" . (@sibling_targets > 1 ? " (with siblings: " . join(", ", grep { $_ ne $target } @sibling_targets) . ")" : "") . "\n";
        } elsif (@deps > 0) {
            # Composite target or target with dependencies but no rule
            if ($ENV{SMAK_DEBUG}) {
                print STDERR "Target '$full_target' has " . scalar(@deps) . " dependencies but no rule\n";
                print STDERR "  Dependencies: " . join(", ", @deps) . "\n";
            }
            # If file exists (relative to working directory), consider it satisfied
            my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
            if (-e $target_path) {
                $completed_targets{$full_target} = 1;
                $in_progress{$full_target} = "done";
                print STDERR "Target '$full_target' exists at '$target_path', marking complete (no rule found)\n" if $ENV{SMAK_DEBUG};
            } else {
                # Update or finalize composite target registration
                # Check if any dependencies failed during recursive queuing
                my @full_deps = map { target_with_prefix($_, $prefix) } @deps;
                my @failed_deps = grep { exists $failed_targets{$_} } @full_deps;
                if (@failed_deps) {
                    # One or more dependencies failed - this should have been caught already
                    # but handle it here as a safety net
                    if (exists $pending_composite{$full_target}) {
                        delete $pending_composite{$full_target};
                    }
                    $in_progress{$full_target} = "failed";
                    $failed_targets{$full_target} = $failed_targets{$failed_deps[0]};
                    print STDERR "Composite target '$full_target' FAILED due to failed dependency '$failed_deps[0]'\n";
		    reprompt();
                } else {
                    # Split each dep on whitespace first (variables may expand to multiple targets)
                    my @all_single_deps;
                    for my $dep (@deps) {
                        push @all_single_deps, split /\s+/, $dep;
                    }
                    @all_single_deps = grep { /\S/ } @all_single_deps;
                    # Apply prefix to deps for tracking
                    my @full_single_deps = map { target_with_prefix($_, $prefix) } @all_single_deps;
                    my @pending_deps = grep { !exists $completed_targets{$_} && !exists $phony_ran_this_session{$_} } @full_single_deps;
                    if (@pending_deps) {
                        # Update the composite target (may have been pre-registered)
                        $in_progress{$full_target} = "pending";
                        $pending_composite{$full_target} = {
                            deps => \@pending_deps,
                            master_socket => $msocket,
                        };
                        vprint "Composite target $full_target waiting for " . scalar(@pending_deps) . " dependencies\n";
                        print STDERR "  Pending: " . join(", ", @pending_deps) . "\n" if $ENV{SMAK_DEBUG};
                    } else {
                        # All deps already complete
                        if (exists $pending_composite{$full_target}) {
                            delete $pending_composite{$full_target};
                        }
                        $completed_targets{$full_target} = 1;
                        $in_progress{$full_target} = "done";
                        print $msocket "JOB_COMPLETE $full_target 0\n" if $msocket;
                    }
                }
            }
        } else {
            # No command and no deps - check if file exists
            my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
            if (-e $target_path) {
                $completed_targets{$full_target} = 1;
                $in_progress{$full_target} = "done";
                print STDERR "Target '$full_target' exists at '$target_path', marking complete (no rule or deps)\n" if $ENV{SMAK_DEBUG};
            } else {
                # Target doesn't exist and has no rule to build it
                # Like make, assume it exists (e.g., source files, .git metadata, etc.)
                $completed_targets{$full_target} = 1;
                $in_progress{$full_target} = "done";
                print STDERR "No rule for target '$full_target', assuming it exists\n" if $ENV{SMAK_DEBUG};
            }
        }
    }

    our ($last_queued, $last_running, $last_ready) = (0, 0, 0);

    sub check_queue_state {
        my ($label) = @_;

        my $ready_workers = 0;
        for my $w (@workers) {
            $ready_workers++ if $worker_status{$w}{ready};
        }

        my $queued = scalar(@job_queue);
        my $running = scalar(keys %running_jobs);

        # Check if state changed (use // 0 to handle uninitialized case on first call)
        my $changed = ($queued != ($last_queued // 0) || $running != ($last_running // 0) || $ready_workers != ($last_ready // 0));

        if ($changed) {
            $last_queued = $queued;
            $last_running = $running;
            $last_ready = $ready_workers;

            # Clear spinner before printing status (skip in dry-run mode)
            print STDERR "\r  \r" unless $dry_run_mode;

            if (scalar(@workers) != $ready_workers || $queued || $running) {
                vprint $stomp_prompt,
                    "Queue: $queued queued, $ready_workers/" . scalar(@workers) . " ready, $running running";

                # Show running targets (up to 5)
                if ($running) {
                    my @running_names;
                    for my $task_id (keys %running_jobs) {
                        my $job = $running_jobs{$task_id};
                        my $display_name = $job->{target};

                        # Try to extract output filename from command (look for -o argument)
                        my $cmd = $job->{command};
                        if ($cmd =~ /-o\s+(\S+)/) {
                            my $output = $1;
                            $output =~ s{.*/}{};
                            $display_name = $output if $output;
                        } elsif ($job->{target} =~ /\.(o|a|so|exe|out)$/) {
                            $display_name = $job->{target};
                        }
                        push @running_names, $display_name;
                    }

                    @running_names = sort @running_names;
                    if (@running_names <= 5) {
                        vprint " (" . join(", ", @running_names) . ")";
                    } else {
                        vprint " (" . join(", ", @running_names[0..4]) . ", +" . (@running_names - 5) . ")";
                    }
                }
                vprint "\n";
            }
        } else {
            # No change - show spinning wheel for activity indicator
            # Skip spinner in dry-run mode, debug mode, or when STDERR is not a terminal
            if (($queued || $running) && !$dry_run_mode && !$ENV{SMAK_DEBUG} && -t STDERR) {
                print STDERR "\r" . $wheel_chars[$wheel_pos] . " ";
                STDERR->flush();  # Ensure spinner updates immediately
                $wheel_pos = ($wheel_pos + 1) % scalar(@wheel_chars);
            }
        }

	# Deadlock detection - queued work, available workers, but nothing running
	# Only check during intermittent checks (not at startup/dispatch where nothing running is normal)
	# Skip in dry-run mode where missing files can cause false positives
	if ($label =~ /intermittent/ && !$dry_run_mode) {
	    if (scalar(@job_queue) > 0 && $ready_workers > 0 && scalar(keys %running_jobs) == 0) {
	        # Potential deadlock - try to fail jobs whose dependencies have failed
	        my $failed_count = 0;
	        my @remaining_jobs;
	        for my $job (@job_queue) {
	            my $target = $job->{target};
	            my $failed_dep = has_failed_dependency($target);
	            if (defined $failed_dep) {
	                print STDERR "Job '$target' FAILED: dependency '$failed_dep' failed\n";
	                $in_progress{$target} = "failed";
	                $failed_targets{$target} = $failed_targets{$failed_dep} || 1;
	                fail_dependent_composite_targets($target, $failed_targets{$target});
	                $failed_count++;
	            } else {
	                push @remaining_jobs, $job;
	            }
	        }
	        @job_queue = @remaining_jobs;

	        # If we failed some jobs, report it
	        if ($failed_count > 0) {
	            vprint "Deadlock recovery: failed $failed_count jobs with failed dependencies\n";
	        }

	        # Check if we need to advance the dispatch layer
	        # This handles the case where all jobs in current layer are done but
	        # jobs exist in higher layers (e.g., from recursive subdirectory processing)
	        if (@job_queue > 0) {
	            # Find next layer with jobs using @job_layers
	            for my $next_layer ($current_dispatch_layer + 1 .. $#job_layers) {
	                if ($job_layers[$next_layer] && @{$job_layers[$next_layer]} > 0) {
	                    vprint "Advancing dispatch layer from $current_dispatch_layer to $next_layer (deadlock recovery)\n";
	                    $current_dispatch_layer = $next_layer;
	                    last;
	                }
	            }
	        }

	        # Always try to dispatch before concluding deadlock
	        # This handles the race condition where workers just became ready
	        if (@job_queue > 0) {
	            dispatch_jobs();
	        }

	        # Recount ready workers after dispatch attempt
	        $ready_workers = 0;
	        for my $w (@workers) {
	            $ready_workers++ if $worker_status{$w}{ready};
	        }

	        # If still stuck with jobs, that's a real deadlock
	        if (@job_queue > 0 && $ready_workers > 0 && scalar(keys %running_jobs) == 0) {
	            # Before failing, dump diagnostic info
	            warn "Deadlock diagnostic:\n";
	            warn "  current_dispatch_layer=$current_dispatch_layer, max_dispatch_layer=$max_dispatch_layer\n";
	            warn "  Job queue (" . scalar(@job_queue) . " jobs):\n";
	            for my $i (0 .. ($#job_queue < 5 ? $#job_queue : 4)) {
	                my $job = $job_queue[$i];
	                warn "    [$i] $job->{target} (layer " . ($job->{layer} // 0) . ")\n";
	            }
	            warn "    ...\n" if @job_queue > 5;

	            assert_or_die(0,
	                "Deadlock detected in $label: " . scalar(@job_queue) . " jobs queued, " .
	                "$ready_workers workers ready, but nothing running. " .
	                "First queued job: " . ($job_queue[0] ? $job_queue[0]{target} : "unknown")
	            );
	        }
	    }
	}
    }

    # Check if a target can be built (has a rule or exists as a source file)
    sub can_build_target {
        my ($target, $target_dir) = @_;
        $target_dir //= '.';

        # Check if already in progress or queued (for targets from subdirectory expansion)
        return 1 if exists $in_progress{$target};
        return 1 if exists $target_layer{$target};

        # Check if target is part of a compound target that's queued
        # e.g., if we're looking for "vhdlpp/parse.cc", check if "vhdlpp/parse.cc&parse.h" exists
        for my $queued_target (keys %target_layer) {
            if ($queued_target =~ /&/) {
                my @parts = split /&/, $queued_target;
                return 1 if grep { $_ eq $target } @parts;
            }
        }

        # Check if file exists as-is first (for root-relative paths like ivlpp/main.c)
        if (-e $target) {
            return 1;
        }

        # Check if file exists in target_dir subdirectory
        my $target_path = $target =~ m{^/} ? $target : "$target_dir/$target";
        if (-e $target_path) {
            return 1;
        }

        # Check vpath directories
        my $resolved = resolve_vpath($target, $target_dir);
        if ($resolved ne $target) {
            # vpath found the file
            my $resolved_path = $resolved =~ m{^/} ? $resolved : "$target_dir/$resolved";
            return 1 if -e $resolved_path;
        }

        # Check if target has a fixed rule
        my $key = "$makefile\t$target";
        return 1 if exists $fixed_rule{$key};
        return 1 if exists $pattern_rule{$key};
        return 1 if exists $pseudo_rule{$key};

        # Check if target matches any pattern rule
        for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                return 1 if $target =~ /^$pattern_re$/;
            }
        }

        return 0;  # Cannot build this target
    }

    # Check if a target has any failed dependencies (recursively)
    # Returns the failed dependency name if found, undef otherwise
    sub has_failed_dependency {
        my ($target, $visited) = @_;
        $visited //= {};

        # Avoid infinite recursion
        return undef if $visited->{$target}++;

        # Direct check - is this target itself failed?
        return $target if exists $failed_targets{$target};

        # Get dependencies for this target - use proper key format and check all dep types
        my $key = "$makefile\t$target";
        my @deps;
        my $stem;  # For pattern expansion

        if (exists $fixed_deps{$key}) {
            @deps = @{$fixed_deps{$key}};
        } elsif (exists $pattern_deps{$key}) {
            my $deps_ref = $pattern_deps{$key};
            # Handle both single variant and multiple variants
            @deps = (ref($deps_ref) eq 'ARRAY' && ref($deps_ref->[0]) eq 'ARRAY') ?
                    @{$deps_ref->[0]} :
                    (ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ());
        } elsif (exists $pseudo_deps{$key}) {
            @deps = @{$pseudo_deps{$key}};
        }

        # If no deps found by exact match, try pattern matching (like dispatch_jobs does)
        if (!@deps) {
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        my $deps_ref = $pattern_deps{$pkey} || [];
                        # Handle both single variant and multiple variants
                        @deps = (ref($deps_ref) eq 'ARRAY' && ref($deps_ref->[0]) eq 'ARRAY') ?
                                @{$deps_ref->[0]} :
                                (ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ());
                        # Expand % in dependencies using the stem
                        $stem = $1;
                        @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @deps;
                        print STDERR "DEBUG has_failed_dependency: Matched pattern '$pattern' for '$target', expanded deps: [" . join(", ", @deps) . "]\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }

        # Check each dependency recursively
        for my $dep (@deps) {
            next if $dep =~ /^\.PHONY$/;
            next if $dep !~ /\S/;

            # Expand variables in dependency
            my $expanded_dep = $dep;
            while ($expanded_dep =~ /\$MV\{([^}]+)\}/) {
                my $var = $1;
                my $val = $MV{$var} // '';
                $expanded_dep =~ s/\$MV\{\Q$var\E\}/$val/;
            }

            for my $single_dep (split /\s+/, $expanded_dep) {
                next unless $single_dep =~ /\S/;

                my $failed = has_failed_dependency($single_dep, $visited);
                return $failed if defined $failed;
            }
        }

        return undef;
    }

    # Check if failed target is a dependency of any composite target, and fail them
    sub fail_dependent_composite_targets {
        my ($failed_target, $exit_code) = @_;

        for my $comp_target (keys %pending_composite) {
            my $comp = $pending_composite{$comp_target};
            # Check if this failed target is in the composite's dependencies
            if (grep { $_ eq $failed_target } @{$comp->{deps}}) {
                print STDERR "Composite target '$comp_target' FAILED because dependency '$failed_target' failed (exit code $exit_code)\n";
                $in_progress{$comp_target} = "failed";
                $failed_targets{$comp_target} = $exit_code;
                if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                    print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                }
                delete $pending_composite{$comp_target};
            }
        }
    }

    # Get next job from the layered queue (O(1) operation)
    # Returns job or undef if no jobs available at current or lower layers
    sub get_next_job_from_layers {
        # Advance layer if current is empty AND no running jobs in current layer
        while ($current_dispatch_layer <= $max_dispatch_layer) {
            my $layer_jobs = $job_layers[$current_dispatch_layer];
            if ($layer_jobs && @$layer_jobs > 0) {
                # Pop job from current layer
                my $job = shift @$layer_jobs;

                # Also remove from flat queue (for compatibility)
                for my $i (0 .. $#job_queue) {
                    if ($job_queue[$i] && $job_queue[$i]{target} eq $job->{target}) {
                        splice(@job_queue, $i, 1);
                        last;
                    }
                }

                print STDERR "DEBUG: Dispatching '$job->{target}' from layer $current_dispatch_layer\n" if $ENV{SMAK_DEBUG};
                return $job;
            }

            # Current layer queue is empty - check if any jobs from this layer are still running
            my $layer_jobs_running = 0;
            for my $task_id (keys %running_jobs) {
                my $rj = $running_jobs{$task_id};
                if (defined $rj->{layer} && $rj->{layer} == $current_dispatch_layer) {
                    $layer_jobs_running++;
                }
            }

            if ($layer_jobs_running > 0) {
                # Jobs from current layer still running - can't advance yet
                print STDERR "DEBUG: Layer $current_dispatch_layer queue empty but $layer_jobs_running jobs still running, waiting\n" if $ENV{SMAK_DEBUG};
                return undef;  # Wait for running jobs to complete
            }

            # Current layer fully complete, advance to next
            $current_dispatch_layer++;
            print STDERR "DEBUG: Advanced to dispatch layer $current_dispatch_layer\n" if $ENV{SMAK_DEBUG};
        }
        return undef;  # No jobs left
    }

    # Dispatch a single job to a specific worker (called when worker reports READY)
    sub dispatch_job_to_worker {
        my ($worker) = @_;

        # Get next job from layered queue
        my $job = get_next_job_from_layers();
        return 0 unless $job;

        my $target = $job->{target};

        # Check if already being dispatched (race prevention)
        if (exists $currently_dispatched{$target}) {
            print STDERR "DEBUG: Target '$target' already dispatched, skipping\n" if $ENV{SMAK_DEBUG};
            return 0;
        }

        # Mark worker as not ready
        $worker_status{$worker}{ready} = 0;

        # Assign task ID
        my $task_id = $next_task_id++;
        $currently_dispatched{$target} = $task_id;
        $in_progress{$target} = $worker;
        $worker_status{$worker}{task_id} = $task_id;

        $running_jobs{$task_id} = {
            target => $target,
            worker => $worker,
            dir => $job->{dir},  # For verify (should be '.')
            exec_dir => $job->{exec_dir} || $job->{dir},  # For worker chdir
            command => $job->{command},
            siblings => $job->{siblings} || [],
            layer => $job->{layer} // 0,
        };

        # Send task to worker with split commands for efficient execution
        print $worker "TASK $task_id\n";
        # Use exec_dir for worker chdir (falls back to dir for backwards compatibility)
        my $worker_dir = $job->{exec_dir} || $job->{dir};
        print $worker "DIR $worker_dir\n";

        # Send external commands (each executed directly without shell)
        my @ext_cmds = $job->{external_commands} ? @{$job->{external_commands}} : ();
        my @builtins = $job->{trailing_builtins} ? @{$job->{trailing_builtins}} : ();

        print $worker "EXTERNAL_CMDS " . scalar(@ext_cmds) . "\n";
        for my $cmd (@ext_cmds) {
            print $worker "$cmd\n";
        }

        print $worker "TRAILING_BUILTINS " . scalar(@builtins) . "\n";
        for my $cmd (@builtins) {
            print $worker "$cmd\n";
        }

        $worker->flush();

        vprint "Dispatched task $task_id: $target (layer " . ($job->{layer} // 0) . ")\n";

        # Print command unless silent
        my $silent = $job->{silent} || 0;
        if (!$silent_mode && !$silent && !$dry_run_mode) {
            print $stomp_prompt, "$job->{command}\n";
        }

        broadcast_observers("DISPATCHED $task_id $target");
        return 1;
    }

    # New layer-based dispatch (temporarily disabled for debugging)
    sub dispatch_jobs_layered {
	my ($do,$block) = @_;
	my $j = 0;

        check_queue_state("dispatch_jobs start");

        # Layer-based dispatch: jobs in layer N depend only on layers < N
        # When dispatching from layer N, all layers < N are already complete
        while (@job_queue > 0 || $current_dispatch_layer <= $max_dispatch_layer) {
            # Find a ready worker
            my $ready_worker;
            for my $worker (@workers) {
                if ($worker_status{$worker}{ready}) {
                    $ready_worker = $worker;
                    last;
                }
            }
            if (!$ready_worker) {
                print STDERR "DEBUG: No ready workers\n" if $ENV{SMAK_DEBUG};
                last;
            }

            # Dispatch next job from current layer to this worker
            if (dispatch_job_to_worker($ready_worker)) {
                $j++;
                if ($block) {
                    wait_for_worker_done($ready_worker);
                }
                if (defined $do && $do == 1) {
                    last;  # Only dispatch one job
                }
            } else {
                # No more jobs available
                last;
            }
        }

        check_queue_state("dispatch_jobs end") if @job_queue;
        return $j;
    }

    # Original dispatch_jobs code (restored for testing)
    sub dispatch_jobs {
	my ($do,$block) = @_;
	my $j = 0;

        check_queue_state("dispatch_jobs start");

        # Debug: Show entry state
        if ($ENV{SMAK_DEBUG}) {
            my $ready_count = 0;
            for my $w (@workers) {
                $ready_count++ if $worker_status{$w}{ready};
            }
            print STDERR "DEBUG dispatch_jobs: Entering with " . scalar(@job_queue) . " jobs queued, " .
                         "$ready_count/" . scalar(@workers) . " workers ready, " .
                         "current_layer=$current_dispatch_layer, max_layer=$max_dispatch_layer\n";
        }

        while (@job_queue) {
            # Find a ready worker
            my $ready_worker;
            for my $worker (@workers) {
                if ($worker_status{$worker}{ready}) {
                    $ready_worker = $worker;
                    last;
                }
            }
            if (! $ready_worker) {
   	        warn "No workers ready, exiting dispatch loop\n" if $ENV{SMAK_DEBUG};
		last; # No workers available
	    }

            # CRITICAL: Mark worker as not ready IMMEDIATELY to prevent race conditions
            # If we don't find a suitable job, we'll mark it ready again below
            $worker_status{$ready_worker}{ready} = 0;

            # Find next job whose dependencies are all satisfied
            my $job_index = -1;
            my $skipped_for_order_only = 0;  # Track jobs skipped due to order-only deps
            my $skipped_for_layer = 0;       # Track jobs skipped due to layer
            for my $i (0 .. $#job_queue) {
                my $job;
                my $target;

		# Skip/remove any undefined entries at this position
		while ($i <= $#job_queue) {
		    $job = $job_queue[$i];
		    if (! defined $job) {
			warn "ERROR: bad job-queue entry at $i, removed\n";
			splice (@job_queue,$i,1);
			# Check same position again (new job moved into this slot)
			next;
		    }
		    $target = $job->{target};
		    if (! defined $target) {
			warn "ERROR: no target for job-queue entry at $i, removed\n";
			splice (@job_queue,$i,1);
			# Check same position again
			next;
		    }
		    # Found valid job, exit the while loop
		    last;
		}

	        # If we've gone past the end of the queue, exit the for loop
	        last if ($i > $#job_queue);

                # LAYER CHECK: Skip jobs in layers higher than current dispatch layer
                # Jobs in higher layers depend on jobs in lower layers - can't run until
                # all lower layer jobs are complete (skip silently to avoid log spam)
                my $job_layer = $job->{layer} // 0;
                if ($job_layer > $current_dispatch_layer) {
                    print STDERR "DEBUG dispatch: Skipping job '$target' (layer $job_layer > current $current_dispatch_layer)\n" if $ENV{SMAK_DEBUG} && $skipped_for_layer < 3;
                    $skipped_for_layer++;
                    next;
                }

                print STDERR "\n=== DEBUG dispatch: Checking job [$i] '$target' (layer $job_layer) ===\n" if $ENV{SMAK_DEBUG};

                # Check if this job's dependencies are satisfied
                my $key = "$makefile\t$target";
                my @deps;
                my $stem;  # For pattern expansion
                my $has_explicit_rule = 0;  # Track if target has explicit rule (don't apply pattern rules)

                # FIRST: Check if the job has stored deps (set during queueing, required for compound targets)
                if ($job->{deps} && @{$job->{deps}}) {
                    @deps = @{$job->{deps}};
                    print STDERR "DEBUG dispatch: Using stored deps for '$target': [" . join(", ", @deps) . "]\n" if $ENV{SMAK_DEBUG};
                } elsif (exists $fixed_deps{$key}) {
                    @deps = @{$fixed_deps{$key} || []};
                    # Check if there's an explicit rule for this target
                    $has_explicit_rule = exists $fixed_rule{$key} && $fixed_rule{$key} =~ /\S/;
                } elsif (exists $pattern_deps{$key}) {
                    my $deps_ref = $pattern_deps{$key} || [];
                    # Handle both single variant and multiple variants
                    @deps = (ref($deps_ref) eq 'ARRAY' && ref($deps_ref->[0]) eq 'ARRAY') ?
                            @{$deps_ref->[0]} :
                            (ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ());
                } elsif (exists $pseudo_deps{$key}) {
                    @deps = @{$pseudo_deps{$key} || []};
                }

                # If no deps found by exact match and no explicit rule, try suffix rules first, then pattern matching
                # Targets with explicit rules should NOT have pattern rule deps added
                if (!@deps && !$has_explicit_rule) {
                    # Try suffix rules FIRST (they take precedence over built-in pattern rules)
                    my $job_dir = $job->{dir} || '.';
                    if ($target =~ /^(.+)(\.[^.\/]+)$/) {
                        my ($base, $target_suffix) = ($1, $2);
                        for my $source_suffix (@suffixes) {
                            my $suffix_key = "$makefile\t$source_suffix\t$target_suffix";
                            if (exists $suffix_rule{$suffix_key}) {
                                my $source = "$base$source_suffix";
                                my $resolved_source = resolve_vpath($source, $job_dir);
                                if (-f $resolved_source || -f "$job_dir/$source") {
                                    $stem = $base;
                                    push @deps, $source unless grep { $_ eq $source } @deps;
                                    print STDERR "DEBUG dispatch: Using suffix rule $source_suffix$target_suffix for $target, deps: [$source]\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }
                        }
                    }
                }

                # Fall back to pattern rules if no deps found
                if (!@deps) {
                    my $job_dir = $job->{dir} || '.';
                    DISPATCH_PATTERN: for my $pkey (keys %pattern_rule) {
                        if ($pkey =~ /^[^\t]+\t(.+)$/) {
                            my $pattern = $1;
                            my $pattern_re = $pattern;
                            $pattern_re =~ s/%/(.+)/g;
                            if ($target =~ /^$pattern_re$/) {
                                my $deps_ref = $pattern_deps{$pkey} || [];
                                $stem = $1;

                                # Check if we have multiple variants (array of arrays)
                                if (ref($deps_ref) eq 'ARRAY' && @$deps_ref && ref($deps_ref->[0]) eq 'ARRAY') {
                                    # Multiple variants - find one whose source file exists
                                    my $found_variant = 0;
                                    for my $vi (0 .. $#$deps_ref) {
                                        my @variant_deps = @{$deps_ref->[$vi]};
                                        @variant_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @variant_deps;
                                        # Check if the first dep (source file) exists
                                        my $source = $variant_deps[0];
                                        my $resolved_source = resolve_vpath($source, $job_dir);
                                        if (-f $resolved_source || -f "$job_dir/$source") {
                                            @deps = @variant_deps;
                                            print STDERR "DEBUG dispatch: Matched pattern '$pattern' variant $vi for '$target' (stem='$stem', source exists)\n" if $ENV{SMAK_DEBUG};
                                            $found_variant = 1;
                                            last DISPATCH_PATTERN;
                                        }
                                    }
                                    # If no variant's source exists, use the first variant
                                    if (!$found_variant) {
                                        @deps = @{$deps_ref->[0]};
                                        @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @deps;
                                        print STDERR "DEBUG dispatch: Matched pattern '$pattern' for '$target' (stem='$stem', using default variant)\n" if $ENV{SMAK_DEBUG};
                                        last DISPATCH_PATTERN;
                                    }
                                } else {
                                    # Single variant or flat deps array
                                    @deps = ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ();
                                    @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @deps;
                                    print STDERR "DEBUG dispatch: Matched pattern '$pattern' for '$target', stem='$stem', expanded deps: [" . join(", ", @deps) . "]\n" if $ENV{SMAK_DEBUG};
                                    # NOTE: Don't resolve vpath here - dependency names must stay as-is
                                    # for hash lookups (completed_targets, failed_targets, in_progress).
                                    # Vpath resolution happens when checking if files exist.
                                    last DISPATCH_PATTERN;
                                }
                            }
                        }
                    }
                }

                # Also check order-only prerequisites (specified after | in makefile rules)
                # These must be built before the target can run, but don't affect rebuild decisions
                my @order_only_deps;
                # FIRST: Check if the job has stored order_only_deps (for compound targets)
                if ($job->{order_only_deps} && @{$job->{order_only_deps}}) {
                    @order_only_deps = @{$job->{order_only_deps}};
                    print STDERR "DEBUG dispatch: Using stored order-only deps for '$target': [" . join(", ", @order_only_deps) . "]\n" if $ENV{SMAK_DEBUG};
                } else {
                    # No stored deps, look them up by key
                    if (exists $fixed_order_only{$key}) {
                        push @order_only_deps, @{$fixed_order_only{$key}};
                        print STDERR "DEBUG dispatch: Found order-only for key '$key': " . join(", ", @order_only_deps) . "\n" if $ENV{SMAK_DEBUG};
                    } elsif ($target =~ /STD\.STANDARD/) {
                        # Debug: show all keys that might match for STD.STANDARD
                        print STDERR "DEBUG dispatch: No order-only for key '$key', checking available keys...\n" if $ENV{SMAK_DEBUG};
                        for my $k (keys %fixed_order_only) {
                            print STDERR "DEBUG dispatch:   available key: '$k' => " . join(", ", @{$fixed_order_only{$k}}) . "\n" if $ENV{SMAK_DEBUG};
                        }
                    }
                    if (exists $pattern_order_only{$key}) {
                        my $oo_ref = $pattern_order_only{$key};
                        if (ref($oo_ref) eq 'ARRAY') {
                            if (@$oo_ref && ref($oo_ref->[0]) eq 'ARRAY') {
                                push @order_only_deps, @{$oo_ref->[0]};
                            } else {
                                push @order_only_deps, @$oo_ref;
                            }
                        }
                    }
                    if (exists $pseudo_order_only{$key}) {
                        push @order_only_deps, @{$pseudo_order_only{$key}};
                    }
                }
                # Expand % in order-only deps if we have a stem
                if ($stem && @order_only_deps) {
                    @order_only_deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @order_only_deps;
                }
                @order_only_deps = grep { $_ ne '' } @order_only_deps;

                # Expand variables in order-only deps
                my @expanded_order_only;
                for my $dep (@order_only_deps) {
                    while ($dep =~ /\$MV\{([^}]+)\}/) {
                        my $var = $1;
                        my $val = $MV{$var} // '';
                        $dep =~ s/\$MV\{\Q$var\E\}/$val/;
                    }
                    push @expanded_order_only, $dep if $dep ne '';
                }
                @order_only_deps = @expanded_order_only;

                # Add order-only deps to a separate list for checking (not to @deps which affects $<)
                # We'll check both @deps and @order_only_deps for completion

                print STDERR "DEBUG dispatch: Checking job '$target', deps: [" . join(", ", @deps) . "]" .
                             (@order_only_deps ? ", order-only: [" . join(", ", @order_only_deps) . "]" : "") . "\n" if $ENV{SMAK_DEBUG};

                # IMPORTANT: Check order-only deps FIRST before checking regular deps
                # Order-only deps must exist/be complete before we even consider this job
                # This prevents us from checking regular deps (which may be queued) when the
                # order-only prerequisite (like bin/nvc) hasn't been built yet
                my $order_only_satisfied = 1;
                my $order_only_failed = 0;
                for my $dep (@order_only_deps) {
                    next if $dep =~ /^\.PHONY$/;
                    next if $dep !~ /\S/;
                    for my $single_dep (split /\s+/, $dep) {
                        next unless $single_dep =~ /\S/;

                        # First check if order-only dep has failed
                        if (exists $failed_targets{$single_dep}) {
                            print STDERR "Job '$target' FAILED: order-only dependency '$single_dep' failed (exit $failed_targets{$single_dep})\n";
                            $in_progress{$target} = "failed";
                            $failed_targets{$target} = $failed_targets{$single_dep};
                            splice(@job_queue, $i, 1);
                            fail_dependent_composite_targets($target, $failed_targets{$single_dep});
                            $order_only_failed = 1;
                            last;
                        }

                        my $dep_path = $single_dep =~ m{^/} ? $single_dep : "$job->{dir}/$single_dep";

                        # Order-only dep is satisfied if:
                        # 1. It exists as a file, OR
                        # 2. It's marked as completed
                        my $is_complete = exists $completed_targets{$single_dep} ||
                                         exists $phony_ran_this_session{$single_dep} ||
                                         -e $dep_path;

                        # But NOT if it's currently being built
                        if ($is_complete && exists $in_progress{$single_dep}) {
                            my $status = $in_progress{$single_dep};
                            if ($status && $status ne 'done' && $status ne 'failed') {
                                $is_complete = 0;  # Still building
                            }
                        }

                        unless ($is_complete) {
                            print STDERR "DEBUG dispatch:   Order-only dep '$single_dep' not satisfied, skipping job '$target'\n" if $ENV{SMAK_DEBUG};
                            $order_only_satisfied = 0;
                            last;
                        }
                    }
                    last if $order_only_failed;
                    last unless $order_only_satisfied;
                }
                next if $order_only_failed;
                unless ($order_only_satisfied) {
                    # Order-only deps not ready - skip this job entirely for now
                    $skipped_for_order_only++;
                    next;
                }

                # Now check regular deps (order-only deps already verified above)
                my @all_deps_to_check = @deps;

                # Check if any dependency has failed - if so, fail this job too
                my $has_failed_dep = 0;
                for my $dep (@all_deps_to_check) {
                    next if $dep =~ /^\.PHONY$/;
                    next if $dep !~ /\S/;
                    for my $single_dep (split /\s+/, $dep) {
                        next unless $single_dep =~ /\S/;
                        if (exists $failed_targets{$single_dep}) {
                            print STDERR "Job '$target' FAILED: dependency '$single_dep' failed (exit $failed_targets{$single_dep})\n";
                            $in_progress{$target} = "failed";
                            $failed_targets{$target} = $failed_targets{$single_dep};
                            splice(@job_queue, $i, 1);  # Remove from queue
                            # Check if this failed target is a dependency of any composite target
                            fail_dependent_composite_targets($target, $failed_targets{$single_dep});
                            $has_failed_dep = 1;
                            last;
                        }
                    }
                    last if $has_failed_dep;
                }
                next if $has_failed_dep;

                # Check if all dependencies are completed
                my $deps_satisfied = 1;
                my $has_unbuildable_dep = 0;
                for my $dep (@all_deps_to_check) {
                    next if $dep =~ /^\.PHONY$/;
                    next if $dep !~ /\S/;

                    # Expand variables in dependency
                    my $expanded_dep = $dep;
                    while ($expanded_dep =~ /\$MV\{([^}]+)\}/) {
                        my $var = $1;
                        my $val = $MV{$var} // '';
                        $expanded_dep =~ s/\$MV\{\Q$var\E\}/$val/;
                    }

                    # Split on whitespace in case multiple dependencies are in one string
                    for my $single_dep (split /\s+/, $expanded_dep) {
                        next unless $single_dep =~ /\S/;

                        # Check if dependency is completed or exists as file
                        # For expanded subdirectory jobs, deps may already be root-relative (e.g., "ivlpp/lexor.lex")
                        # Don't double-prefix if dependency already starts with job dir
                        my $dep_path;
                        if ($single_dep =~ m{^/}) {
                            $dep_path = $single_dep;  # Absolute path
                        } elsif ($single_dep =~ m{^\Q$job->{dir}\E/}) {
                            $dep_path = $single_dep;  # Already root-relative with job dir prefix
                        } elsif (-e $single_dep) {
                            $dep_path = $single_dep;  # File exists as-is from root
                        } else {
                            $dep_path = "$job->{dir}/$single_dep";  # Relative to job dir
                        }

                        # If file doesn't exist, try vpath resolution
                        if (!-e $dep_path) {
                            my $resolved = resolve_vpath($single_dep, $job->{dir});
                            if ($resolved ne $single_dep) {
                                $dep_path = $resolved =~ m{^/} ? $resolved : "$job->{dir}/$resolved";
                                print STDERR "DEBUG dispatch:     vpath resolved '$single_dep' to '$resolved'\n" if $ENV{SMAK_DEBUG};
                            }
                        }

                        # Only print debug for non-trivial cases (skip satisfied dependencies to reduce noise)
                        # Also check phony_ran_this_session for phony targets that completed but weren't cached
                        my $is_satisfied = (exists $completed_targets{$single_dep} || exists $phony_ran_this_session{$single_dep}) &&
                                          (!exists $in_progress{$single_dep} ||
                                           $in_progress{$single_dep} eq 'done' ||
                                           !$in_progress{$single_dep});

                        if (!$is_satisfied && $ENV{SMAK_DEBUG}) {
                            print STDERR "DEBUG dispatch:   Checking dep '$single_dep' for target '$target'\n";
                            print STDERR "DEBUG dispatch:     completed_targets: " . (exists $completed_targets{$single_dep} ? "YES" : "NO") . "\n";
                            print STDERR "DEBUG dispatch:     in_progress: " . (exists $in_progress{$single_dep} ? $in_progress{$single_dep} : "NO") . "\n";
                        }

                        # If the dependency was recently completed, verify it actually exists on disk
                        # to avoid race conditions where the file isn't visible yet due to filesystem buffering
                        if ($completed_targets{$single_dep} || $phony_ran_this_session{$single_dep}) {
                            # With auto-rescan, FUSE monitoring, or dry-run mode, we can trust completed_targets
                            # because deleted files are automatically detected (or files won't exist in dry-run)
                            if ($auto_rescan || $fuse_auto_clear || $dry_run_mode) {
                                # File monitoring active or dry-run mode - trust completed_targets
                                # (Files would have been removed if deleted, or won't exist in dry-run)
                            } elsif (-e $dep_path) {
                                # No monitoring - verify file exists on disk
                            } elsif (exists $pending_composite{$single_dep}) {
                                # Composite target (phony/aggregator), no file needed
                            } elsif (exists $pseudo_deps{"$makefile\t$single_dep"}) {
                                # Phony target defined in Makefile, no file needed
                            } elsif ($single_dep =~ /^(all|clean|install|test|check|depend|dist|
                                                       distclean|maintainer-clean|mostlyclean|
                                                       cmake_check_build_system|cmake_force|help|list|
                                                       package|preinstall|rebuild_cache|edit_cache)$/x) {
                                # Common phony target, no file needed
                            } else {
                                # Target marked complete but file not visible - verify with retries
                                unless (verify_target_exists($single_dep, $job->{dir})) {
                                    $deps_satisfied = 0;
                                    vprint "Job '$target' waiting for dependency '$single_dep' (completed but not yet visible)\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }
                        } elsif (-e $dep_path) {
                            # File exists on disk - but check if it's being rebuilt
                            if ($in_progress{$single_dep} &&
                                $in_progress{$single_dep} ne "done" &&
                                $in_progress{$single_dep} ne "failed") {
                                # Dependency is being rebuilt - wait for it
                                $deps_satisfied = 0;
                                print STDERR "  Job '$target' waiting for dependency '$single_dep' (being rebuilt)\n" if $ENV{SMAK_DEBUG};
                                last;
                            }
                            # Pre-existing source file or already built, OK to proceed
                        } elsif (exists $in_progress{$single_dep} &&
                                 $in_progress{$single_dep} ne "done" &&
                                 $in_progress{$single_dep} ne "failed") {
                            # Check if dependency is actually being built (has a worker) vs just queued
                            my $dep_status = $in_progress{$single_dep};
                            # Worker references stringify to "GLOB(0x...)" or are objects
                            # Status strings are: "queued", "pending", "sibling:..."
                            my $is_building = ref($dep_status) || $dep_status =~ /^GLOB\(/;

                            if ($is_building) {
                                # Dependency is currently building on a worker - wait for it
                                $deps_satisfied = 0;
                                print STDERR "  Job '$target' waiting for dependency '$single_dep' (building)\n" if $ENV{SMAK_DEBUG};
                                print STDERR "DEBUG dispatch:     Set deps_satisfied=0 for '$target' due to '$single_dep' in_progress (building)\n" if $ENV{SMAK_DEBUG};
                                last;
                            } elsif ($dep_status =~ /^(queued|pending)$/) {
                                # Dependency is queued but not yet dispatched - must wait
                                $deps_satisfied = 0;
                                print STDERR "DEBUG dispatch:     Dep '$single_dep' is queued/pending, must wait\n" if $ENV{SMAK_DEBUG};
                                last;
                            } elsif ($dep_status =~ /^sibling:/) {
                                # Dependency is part of a composite target being built
                                $deps_satisfied = 0;
                                print STDERR "  Job '$target' waiting for dependency '$single_dep' (sibling in progress)\n" if $ENV{SMAK_DEBUG};
                                last;
                            } else {
                                # Unknown status - be conservative and wait
                                $deps_satisfied = 0;
                                print STDERR "  Job '$target' waiting for dependency '$single_dep' (status: $dep_status)\n" if $ENV{SMAK_DEBUG};
                                last;
                            }
                        } else {
                            # Dependency not completed and doesn't exist
                            print STDERR "DEBUG dispatch:     Dep '$single_dep' not completed and doesn't exist\n" if $ENV{SMAK_DEBUG};
                            # Check if the dependency has failed dependencies (transitively)
                            my $failed_dep = has_failed_dependency($single_dep);
                            print STDERR "DEBUG dispatch:     has_failed_dependency returned: " . (defined $failed_dep ? "'$failed_dep'" : "undef") . "\n" if $ENV{SMAK_DEBUG};
                            if (defined $failed_dep) {
                                # Dependency cannot be built - fail this job too
                                print STDERR "Job '$target' FAILED: dependency '$single_dep' cannot be built (depends on failed target '$failed_dep')\n";
                                $in_progress{$target} = "failed";
                                $failed_targets{$target} = $failed_targets{$failed_dep};
                                splice(@job_queue, $i, 1);  # Remove from queue
                                # Check if this failed target is a dependency of any composite target
                                fail_dependent_composite_targets($target, $failed_targets{$failed_dep});
                                $has_unbuildable_dep = 1;
                                last;
                            } else {
                                # Check if this dependency can actually be built
                                if (!can_build_target($single_dep, $job->{dir})) {
                                    # Dependency cannot be built - no rule exists and file doesn't exist
                                    print STDERR "Job '$target' FAILED: dependency '$single_dep' cannot be built (no rule or source file found)\n";
                                    $in_progress{$target} = "failed";
                                    $failed_targets{$target} = 1;  # Generic failure code
                                    splice(@job_queue, $i, 1);  # Remove from queue
                                    fail_dependent_composite_targets($target, 1);
                                    $has_unbuildable_dep = 1;
                                    last;
                                }
                                # Dependency is still building or queued
                                $deps_satisfied = 0;
                                print STDERR "  Job '$target' waiting for dependency '$single_dep'\n" if $ENV{SMAK_DEBUG};
                                print STDERR "DEBUG dispatch:     Set deps_satisfied=0 for '$target' due to '$single_dep'\n" if $ENV{SMAK_DEBUG};
                                last;
                            }
                        }
                    }

                    last if $has_unbuildable_dep;
                    last unless $deps_satisfied;
                }
                next if $has_unbuildable_dep;

                if ($deps_satisfied) {
                    print STDERR "DEBUG dispatch: Job '$target' has all dependencies satisfied, will dispatch\n" if $ENV{SMAK_DEBUG};
                    $job_index = $i;
                    last;
                } else {
                    print STDERR "DEBUG dispatch: Job '$target' dependencies NOT satisfied, skipping\n" if $ENV{SMAK_DEBUG};
                }
            }

            # No job with satisfied dependencies found
            if ($job_index < 0) {
                # Restore worker to ready state since we didn't use it
                $worker_status{$ready_worker}{ready} = 1;

                # Try to advance to next layer if current layer is complete
                # Current layer is complete when: no queued jobs in this layer AND no running jobs in this layer
                my $current_layer_queued = 0;
                my $current_layer_running = 0;

                for my $qjob (@job_queue) {
                    my $jl = $qjob->{layer} // 0;
                    if ($jl == $current_dispatch_layer) {
                        $current_layer_queued++;
                    }
                }

                for my $task_id (keys %running_jobs) {
                    my $rj = $running_jobs{$task_id};
                    if (defined $rj->{layer} && $rj->{layer} == $current_dispatch_layer) {
                        $current_layer_running++;
                    }
                }

                my $layer_advanced = 0;
                if ($current_layer_queued == 0 && $current_layer_running == 0) {
                    # Current layer fully complete - find next layer with jobs
                    for my $next_layer ($current_dispatch_layer + 1 .. $#job_layers) {
                        if ($job_layers[$next_layer] && @{$job_layers[$next_layer]} > 0) {
                            $current_dispatch_layer = $next_layer;
                            print STDERR "DEBUG: Layer complete, advancing to dispatch layer $current_dispatch_layer\n" if $ENV{SMAK_DEBUG};
                            $layer_advanced = 1;
                            last;  # Found new layer, break out of layer-search loop
                        }
                    }
                }

                # If we advanced to a new layer, retry dispatching from that layer
                if ($layer_advanced) {
                    next;  # Retry the outer while loop with the new layer
                }

                if ($current_layer_running > 0) {
                    # Jobs still running in current layer - wait for them
                    print STDERR "DEBUG: Layer $current_dispatch_layer has $current_layer_running running jobs, waiting\n" if $ENV{SMAK_DEBUG};
                    last;  # Exit dispatch loop, will retry when jobs complete
                }

                # Determine why we couldn't dispatch - waiting for layer vs truly stuck
                if ($skipped_for_order_only > 0 || $skipped_for_layer > 0) {
                    # Not stuck - just waiting for earlier layers to complete
                    print STDERR "DEBUG: Waiting for layer $current_dispatch_layer to drain " .
                                 "($skipped_for_layer higher-layer, $skipped_for_order_only order-only skipped)\n" if $ENV{SMAK_DEBUG};
                } elsif ($ENV{SMAK_DEBUG}) {
                    print STDERR "No jobs with satisfied dependencies (stuck!)\n";
                    print STDERR "Current layer: $current_dispatch_layer, max layer: $max_dispatch_layer\n";
                    print STDERR "Job queue has " . scalar(@job_queue) . " jobs:\n";
                    my $max_show = @job_queue < 10 ? $#job_queue : 9;
                    for my $i (0 .. $max_show) {
                        my $job = $job_queue[$i];
                        my $jl = $job->{layer} // 0;
                        print STDERR "  [$i] $job->{target} (layer $jl)\n";
                    }
                    print STDERR "  ...\n" if @job_queue > 10;
                }
                last;
            }

            # Double-check that the job isn't already being dispatched
            # (race condition prevention)
            my $job = $job_queue[$job_index];
            if (exists $in_progress{$job->{target}}) {
                my $status = $in_progress{$job->{target}};
                # Skip if actually building (has a worker reference or GLOB)
                # Don't skip if status is "queued", "pending", "done", or "failed"
                my $is_building = ref($status) || $status =~ /^GLOB\(/;
                if ($is_building) {
                    # Job is already being built - skip it
                    print STDERR "RACE CONDITION PREVENTED: Job '$job->{target}' already in progress (status: $status), skipping duplicate dispatch\n" if $ENV{SMAK_DEBUG};
                    splice(@job_queue, $job_index, 1);  # Remove duplicate from queue
                    next;  # Try next job
                }
            }

            # Dispatch the job
            # CRITICAL: Get target BEFORE removing from queue to minimize race window
            my $peek_job = $job_queue[$job_index];
            my $target = $peek_job->{target};

            # Skip jobs for targets already completed (e.g., placeholder jobs for compound target siblings)
            # When a compound target completes, it marks its siblings as done, so their placeholders
            # should be removed from the queue rather than dispatched.
            if (exists $completed_targets{$target}) {
                print STDERR "DEBUG: Skipping already-completed target '$target' (placeholder removed)\n" if $ENV{SMAK_DEBUG};
                splice(@job_queue, $job_index, 1);
                next;
            }

            # ASSERTION: Check for duplicate dispatch BEFORE incrementing task_id
            if (exists $currently_dispatched{$target}) {
                my $existing_task = $currently_dispatched{$target};
                print STDERR "DEBUG: DUPLICATE DISPATCH DETECTED! Target '$target' already dispatched as task $existing_task\n";
                assert_or_die(0, "Attempting to dispatch '$target' but it's already dispatched as task $existing_task");
            }

            # Try to execute command as a built-in (avoids worker round-trip)
            # This handles compound commands like "(rm -f *.o || true) && (rm -f src/*.o || true)"
            my $peek_cmd = $peek_job->{command};
            if (defined $peek_cmd && $peek_cmd =~ /\S/) {
                # Change to job directory for built-in execution
                my $saved_dir;
                if ($peek_job->{dir} && $peek_job->{dir} ne '.') {
                    use Cwd 'getcwd';
                    $saved_dir = getcwd();
                    if (!chdir($peek_job->{dir})) {
                        warn "Cannot chdir to $peek_job->{dir}: $!\n" if $ENV{SMAK_DEBUG};
                        $saved_dir = undef;  # Don't try to restore
                    }
                }

                my $builtin_exit = try_execute_compound_builtin($peek_cmd);

                # Restore directory
                chdir($saved_dir) if defined $saved_dir;

                if (defined $builtin_exit) {
                    # Command was handled as built-in - no need for worker
                    print STDERR "DEBUG: Built-in execution of '$target': exit $builtin_exit\n" if $ENV{SMAK_DEBUG};

                    # Remove from queue
                    splice(@job_queue, $job_index, 1);

                    # Restore worker to ready state (we didn't use it)
                    $worker_status{$ready_worker}{ready} = 1;

                    if ($builtin_exit == 0) {
                        # Success - mark complete
                        $completed_targets{$target} = 1;
                        $in_progress{$target} = "done";

                        # Tell scanner to watch this target for future changes
                        if ($scanner_socket) {
                            print $scanner_socket "WATCH:$target\n";
                            $scanner_socket->flush();
                        }

                        # Check composite targets
                        for my $comp_target (keys %pending_composite) {
                            my $comp = $pending_composite{$comp_target};
                            $comp->{deps} = [grep { $_ ne $target } @{$comp->{deps}}];

                            if (@{$comp->{deps}} == 0) {
                                vprint "All dependencies complete for composite target '$comp_target' (built-in)\n";
                                $completed_targets{$comp_target} = 1;
                                $in_progress{$comp_target} = "done";
                                if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                                    print {$comp->{master_socket}} "JOB_COMPLETE $comp_target 0\n";
                                }
                                delete $pending_composite{$comp_target};
                            }
                        }

                        # Notify master
                        print $master_socket "JOB_COMPLETE $target 0\n" if $master_socket;
                    } else {
                        # Failure
                        $failed_targets{$target} = $builtin_exit;
                        $in_progress{$target} = "failed";
                        fail_dependent_composite_targets($target, $builtin_exit);
                        print $master_socket "JOB_COMPLETE $target $builtin_exit\n" if $master_socket;
                    }

                    $j++;
                    next;  # Continue to next job
                }

                # Check if this is a recursive smak/make command that should be expanded
                # This handles commands like: smak -C ivlpp all && smak -C driver all
                if (is_builtin_command($peek_cmd)) {
                    print STDERR "DEBUG: is_builtin_command=1 for cmd: $peek_cmd\n" if $ENV{SMAK_DEBUG};
                    # Parse the recursive commands and expand them into the job queue
                    my @cmd_parts = split(/\s*&&\s*/, $peek_cmd);
                    my $all_expanded = 1;

                    for my $cmd_part (@cmd_parts) {
                        $cmd_part =~ s/^\s+|\s+$//g;
                        $cmd_part =~ s/^[@-]+//;
                        next if $cmd_part eq 'true' || $cmd_part eq ':' || $cmd_part eq '';

                        # Check if it's a recursive smak/make call
                        if ($cmd_part =~ m{(?:smak|make)\s.*-C\s+(\S+)}) {
                            my ($sub_makefile, $sub_directory, $sub_vars_ref, @sub_targets) = parse_make_command($cmd_part);

                            if ($sub_directory) {
                                print STDERR "DEBUG: Recursive smak -C $sub_directory - forking to expand targets\n" if $ENV{SMAK_DEBUG};

                                # Fork to expand targets with fresh rule context
                                # Child feeds back job specs with root-relative paths
                                my $safe_dir = $sub_directory;
                                $safe_dir =~ s{[/\s]}{_}g;
                                my $jobs_file = "/tmp/smak_jobs_${$}_${safe_dir}.dat";
                                print STDERR "DEBUG: jobs_file = $jobs_file\n" if $ENV{SMAK_DEBUG};

                                my $pid = fork();
                                if (!defined $pid) {
                                    warn "Warning: Could not fork for recursive make: $!\n";
                                    $all_expanded = 0;
                                    last;
                                }

                                if ($pid == 0) {
                                    # Child: discard parent rules
                                    %fixed_rule = ();
                                    %fixed_deps = ();
                                    %pattern_rule = ();
                                    %pattern_deps = ();
                                    %pseudo_rule = ();
                                    %pseudo_deps = ();
                                    %suffix_rule = ();
                                    %suffix_deps = ();

                                    chdir($sub_directory) or do {
                                        warn "Warning: Could not chdir to '$sub_directory': $!\n";
                                        exit(1);
                                    };

                                    # Parse fresh
                                    my $sub_mf_name = $sub_makefile || 'Makefile';
                                    print STDERR "DEBUG CHILD: Parsing $sub_mf_name in $sub_directory\n";
                                    eval { parse_makefile($sub_mf_name); };
                                    if ($@) {
                                        warn "Warning: Could not parse '$sub_mf_name': $@\n";
                                        exit(1);
                                    }
                                    print STDERR "DEBUG CHILD: makefile='$makefile' fixed_deps keys: " . join(', ', sort keys %fixed_deps) . "\n";

                                    # Expand targets into job specs using dry_run_target with capture
                                    my %captured;
                                    my @targets_to_build = @sub_targets ? @sub_targets : (get_first_target($sub_mf_name) || 'all');
                                    print STDERR "DEBUG CHILD: targets_to_build = @targets_to_build\n";
                                    for my $sub_target (@targets_to_build) {
                                        print STDERR "DEBUG CHILD: Calling dry_run_target('$sub_target')\n";
                                        eval { dry_run_target($sub_target, {}, 0, { capture => \%captured, no_commands => 1 }); };
                                        if ($@) {
                                            warn "Warning: Failed to expand '$sub_target': $@\n";
                                        }
                                    }

                                    # Expand all variables in rules before saving
                                    # (The parent doesn't have access to subdirectory's %MV values)
                                    for my $tgt (keys %captured) {
                                        my $info = $captured{$tgt};
                                        if ($info->{rule} && $info->{rule} =~ /\S/) {
                                            # Expand $MV{...} variables
                                            my $expanded = format_output($info->{rule});
                                            $expanded = expand_vars($expanded);

                                            # Expand automatic variables
                                            my @deps = @{$info->{deps} || []};
                                            my $first_prereq = @deps ? $deps[0] : '';
                                            my $all_prereqs = join(' ', @deps);

                                            # Compute stem for $* (e.g., "foo" from "foo.o" matching "%.o")
                                            my $stem = '';
                                            if ($tgt =~ /^(.+)\.([^.\/]+)$/) {
                                                $stem = $1;
                                            }

                                            $expanded =~ s/\$\@/$tgt/g;
                                            $expanded =~ s/\$</$first_prereq/g;
                                            $expanded =~ s/\$\^/$all_prereqs/ge;
                                            $expanded =~ s/\$\*/$stem/g if $stem;

                                            $info->{rule} = $expanded;
                                        }
                                    }

                                    # Save job specs to temp file
                                    print STDERR "DEBUG CHILD: Captured targets: " . join(', ', sort keys %captured) . "\n";
                                    use Storable;
                                    Storable::nstore(\%captured, $jobs_file);
                                    print STDERR "DEBUG CHILD: Saved to $jobs_file\n";
                                    exit(0);
                                }

                                # Parent: wait for child, load job specs
                                waitpid($pid, 0);
                                my $child_exit = $? >> 8;
                                if ($child_exit != 0 || !-f $jobs_file) {
                                    warn "Warning: Failed to expand targets in '$sub_directory'\n";
                                    unlink($jobs_file) if -f $jobs_file;
                                    $all_expanded = 0;
                                    last;
                                }

                                # Load job specs from child
                                use Storable;
                                my $captured = Storable::retrieve($jobs_file);
                                unlink($jobs_file);

                                if ($captured && %$captured) {
                                    # Helper to normalize paths (remove ./, handle ../)
                                    my $normalize_path = sub {
                                        my ($base_dir, $path) = @_;
                                        # Remove leading ./
                                        $path =~ s{^\./}{};
                                        # Handle ../ by going up from base_dir
                                        while ($path =~ s{^\.\./}{}) {
                                            if ($base_dir =~ m{/}) {
                                                $base_dir =~ s{/[^/]+$}{};  # Remove last component
                                            } else {
                                                $base_dir = '';  # No more components to remove
                                            }
                                        }
                                        return $base_dir ? "$base_dir/$path" : $path;
                                    };

                                    # Queue jobs with root-relative paths
                                    for my $tgt (keys %$captured) {
                                        my $info = $captured->{$tgt};
                                        my $full_target = $normalize_path->($sub_directory, $tgt);
                                        my @full_deps = map { $normalize_path->($sub_directory, $_) } @{$info->{deps} || []};
                                        # Command is already fully expanded by child process
                                        my $cmd = $info->{rule} || '';

                                        # Register the job
                                        print STDERR "DEBUG: Queueing $full_target (cmd: $cmd)\n" if $ENV{SMAK_DEBUG} && $cmd;

                                        # Compute layer based on dependencies
                                        my $layer = compute_target_layer(\@full_deps);

                                        # Queue the job if it has a command
                                        if ($cmd && $cmd =~ /\S/) {
                                            my %job = (
                                                target => $full_target,
                                                dir => $sub_directory,
                                                command => $cmd,
                                                deps => \@full_deps,
                                                layer => $layer,
                                            );
                                            add_job_to_layer(\%job, $layer);
                                            $in_progress{$full_target} = "queued";
                                        } elsif (@full_deps) {
                                            # Composite target with deps but no command - still needs layer tracking
                                            $target_layer{$full_target} = $layer;
                                            $in_progress{$full_target} = "queued";
                                        }
                                    }
                                    print STDERR "DEBUG: Queued " . scalar(keys %$captured) . " targets from $sub_directory\n" if $ENV{SMAK_DEBUG};
                                }
                            }
                        }
                    }

                    print STDERR "DEBUG: all_expanded=$all_expanded for '$target'\n" if $ENV{SMAK_DEBUG};
                    if ($all_expanded) {
                        # Remove from queue and mark complete
                        print STDERR "DEBUG: Marking '$target' complete via expansion\n" if $ENV{SMAK_DEBUG};
                        splice(@job_queue, $job_index, 1);
                        $worker_status{$ready_worker}{ready} = 1;
                        $completed_targets{$target} = 1;
                        $in_progress{$target} = "done";
                        print $master_socket "JOB_COMPLETE $target 0\n" if $master_socket;
                        $j++;
                        next;
                    }
                }
                # Not a built-in - continue with normal worker dispatch
                print STDERR "DEBUG: Fell through is_builtin, continuing to worker dispatch for '$target'\n" if $ENV{SMAK_DEBUG};
            }

            print STDERR "DEBUG: About to dispatch '$target' to worker\n" if $ENV{SMAK_DEBUG};
            # Mark as dispatched IMMEDIATELY (before removing from queue) to prevent race
            my $task_id = $next_task_id++;
            $currently_dispatched{$target} = $task_id;
            print STDERR "DEBUG: Dispatched '$target' as task $task_id\n" if $ENV{SMAK_DEBUG};

            # Now safe to remove from queue
            $job = splice(@job_queue, $job_index, 1);

            # Mark as in_progress IMMEDIATELY to prevent race conditions
            # Do this BEFORE sending to worker to ensure no duplicate dispatch
            $in_progress{$job->{target}} = $ready_worker;

            # Worker was already marked not ready at the top of the loop (line 8718)
            # ASSERTION: Check that no other worker has this task_id
            for my $w (@workers) {
                if ($w ne $ready_worker && exists $worker_status{$w}{task_id} && $worker_status{$w}{task_id} == $task_id) {
                    assert_or_die(0, "Worker collision! Task $task_id assigned to multiple workers");
                }
            }
            # Just set the task_id
            $worker_status{$ready_worker}{task_id} = $task_id;

            $running_jobs{$task_id} = {
                target => $job->{target},
                worker => $ready_worker,
                dir => $job->{dir},  # For verify
                exec_dir => $job->{exec_dir} || $job->{dir},  # For worker chdir
                command => $job->{command},
                siblings => $job->{siblings} || [],  # Multi-output siblings
                layer => $job->{layer},  # Track layer for completion checking
                started => 0,
                output => [],  # Capture output for error analysis
            };

	    $j++;

            # Send task to worker (use exec_dir for chdir)
            my $worker_dir = $job->{exec_dir} || $job->{dir};
            print $ready_worker "TASK $task_id\n";
            print $ready_worker "DIR $worker_dir\n";
            print $ready_worker "CMD $job->{command}\n";
            $ready_worker->flush();  # Ensure immediate send to worker

            vprint "Dispatched task $task_id to worker\n";

	    # Check if command should be echoed (based on @ prefix detection before processing)
	    my $silent = $job->{silent} || 0;

	    # In dry-run mode, the worker will send the command as OUTPUT, so don't print it here
	    if (!$silent_mode && !$silent && !$dry_run_mode) {
		print $stomp_prompt,"$job->{command}\n";
	    }

            broadcast_observers("DISPATCHED $task_id $job->{target}");

            if ($block) {
		wait_for_worker_done($ready_worker);
	    }

	    if (defined $do) {
		last if (1 == $do); # done for now
	    }
        }

        check_queue_state("dispatch_jobs end") if @job_queue;

	return $j;
    }

    # Main event loop
    my $idle_timeouts = 0;  # Count consecutive select timeouts with no activity
    my $max_exit_code = 0;  # Track highest exit code from all jobs
    my $idle_sent = 0;      # Track if we've sent IDLE (avoid flooding)
    # Auto-rescan is now handled by the smak-scan background process

    while (1) {
        # Check if idle (nothing queued, nothing running)
        # Note: pending_composite doesn't matter - if nothing queued/running, no progress possible
        my $is_idle = (@job_queue == 0 && keys(%running_jobs) == 0);

        # If idle and master connected, send IDLE notification (only once per idle period)
        if ($is_idle && defined($master_socket) && !$idle_sent) {
            # Clear spinner before going idle (skip in dry-run mode)
            print STDERR "\r  \r" unless $dry_run_mode;
            my $final_exit = $max_exit_code;
            if (!$final_exit && keys(%failed_targets)) {
                for my $target (keys %failed_targets) {
                    if ($failed_targets{$target} && $failed_targets{$target} > $final_exit) {
                        $final_exit = $failed_targets{$target};
                    }
                }
                $final_exit ||= 1;
            }
            my $idle_time = Time::HiRes::time();
            print $master_socket "IDLE $final_exit $idle_time\n" if $master_socket;
            $master_socket->flush() if $master_socket;
            $idle_sent = 1;
        }

        # Reset idle_sent when we have work
        $idle_sent = 0 if !$is_idle;

        # Diagnostic: detect "stuck" state - jobs queued but nothing running and can't dispatch
        if (!$is_idle && keys(%running_jobs) == 0 && @job_queue > 0) {
            our $stuck_warned;
            if (!$stuck_warned && $ENV{SMAK_DEBUG}) {
                print STDERR "WARNING: Jobs queued (" . scalar(@job_queue) . ") but nothing running\n";
                print STDERR "  current_dispatch_layer=$current_dispatch_layer, max_dispatch_layer=$max_dispatch_layer\n";
                for my $i (0 .. ($#job_queue < 5 ? $#job_queue : 4)) {
                    my $j = $job_queue[$i];
                    print STDERR "  [$i] $j->{target} (layer " . ($j->{layer} // '?') . ")\n";
                }
                $stuck_warned = 1;
            }
        }

        # If idle and master disconnected, exit
        if ($is_idle && !defined($master_socket)) {
            vprint "Idle and master disconnected. Job-master exiting.\n";
            my $local_link = ".smak.connect";
            unlink($local_link) if -l $local_link;
            unlink($port_file) if -f $port_file;
            last;
        }

        # In non-CLI mode (batch mode), detect if parent process died
        # When parent dies, getppid() returns 1 (init process)
        # This means master crashed or exited unexpectedly - we should clean up
        if (getppid() == 1 && !defined($master_socket)) {
            print STDERR "Parent process died. Job-master cleaning up and exiting.\n";
            # Kill any running workers
            shutdown_workers();
            my $local_link = ".smak.connect";
            unlink($local_link) if -l $local_link;
            unlink($port_file) if -f $port_file;
            exit 1;
        }

        my @ready = $select->can_read(0.1);

        # On select timeout (nothing ready), do consistency check
        if (@ready == 0) {
            $idle_timeouts++;

            # Report queue state and check for deadlocks
            check_queue_state("intermittent check");

            # Try to dispatch queued jobs if workers are available
            if (@job_queue > 0) {
                my $ready_workers = 0;
                for my $w (@workers) {
                    $ready_workers++ if $worker_status{$w}{ready};
                }
                if ($ready_workers > 0) {
                    dispatch_jobs();
                }

                # After dispatch attempt: if nothing is running and we have ready workers,
                # but jobs couldn't be dispatched, we're effectively idle (stuck or done)
                # Recount ready workers after dispatch (some may have been assigned jobs)
                $ready_workers = 0;
                for my $w (@workers) {
                    $ready_workers++ if $worker_status{$w}{ready};
                }
                if (keys(%running_jobs) == 0 && $ready_workers > 0 && !$idle_sent && $master_socket) {
                    my $final_exit = $max_exit_code;
                    if (!$final_exit && keys(%failed_targets)) {
                        for my $t (keys %failed_targets) {
                            $final_exit = $failed_targets{$t} if $failed_targets{$t} > $final_exit;
                        }
                        $final_exit ||= 1;
                    }
                    my $idle_time = Time::HiRes::time();
                    print $master_socket "IDLE $final_exit $idle_time\n";
                    $master_socket->flush();
                    $idle_sent = 1;
                    print STDERR "DEBUG: Sent IDLE - jobs queued but none dispatchable, nothing running\n" if $ENV{SMAK_DEBUG};
                }
            }

            # Check all worker sockets for pending messages
            for my $worker (@workers) {
                $worker->blocking(0);
                while (my $line = <$worker>) {
                    chomp $line;
                    vprint "Timeout check: processing pending message: $line\n";

                    # Process the message inline (same logic as main event loop)
                    if ($line eq 'READY') {
                        $worker_status{$worker}{ready} = 1;
                        my $dispatched = dispatch_jobs(1);  # Try to dispatch one job
                        if ($dispatched) {
                            vprint "Worker received job (consistency check)\n";
                        } else {
                            vprint "Worker ready\n";
                        }

                    } elsif ($line =~ /^TASK_START (\d+)$/) {
                        my $task_id = $1;
                        if (exists $running_jobs{$task_id}) {
                            $running_jobs{$task_id}{started} = 1;
                        }
                        print STDERR "Task $task_id started\n" if $ENV{SMAK_DEBUG};

                    } elsif ($line =~ /^TASK_END (\d+) (\d+)$/) {
                        my ($task_id, $exit_code) = ($1, $2);
                        my $job = $running_jobs{$task_id};

                        delete $running_jobs{$task_id};

                        my $task_handled_successfully = 0;  # Track if we handled this task as successful

                        if ($exit_code == 0 && $job->{target}) {
                            # Check if this looks like a phony target (doesn't produce a file)
                            # Phony targets typically have no extension or are common make targets
                            my $target = $job->{target};
                            my $looks_like_file = $target =~ /\.[a-zA-Z0-9]+$/ ||  # has extension
                                                  $target =~ /\// ||                # has path separator
                                                  $target =~ /^lib.*\.a$/ ||        # library file
                                                  $target =~ /^.*\.so(\.\d+)*$/;    # shared library

                            # Common phony targets that don't produce files
                            my $is_common_phony = $target =~ /^(all|clean|install|test|check|depend|dist|
                                                                distclean|maintainer-clean|mostlyclean|
                                                                cmake_check_build_system|help|list|
                                                                package|preinstall|rebuild_cache|edit_cache)$/x;

                            # Check if target is explicitly marked as phony in Makefile
                            my $is_phony = $is_common_phony || exists $pseudo_deps{"$makefile\t$target"};

                            # Only verify file existence for targets that look like real files
                            # Skip verification in dry-run mode since files aren't actually created
                            my $should_verify = $looks_like_file && !$is_phony && !$dry_run_mode;

                            if (!$should_verify || verify_target_exists($job->{target}, $job->{dir})) {
                                # Only mark non-phony targets as complete
                                # Phony targets should always run, never be cached
                                if (!$is_phony) {
                                    $completed_targets{$job->{target}} = 1;
                                    $in_progress{$job->{target}} = "done";

                                    # Tell scanner to watch this target for future changes
                                    if ($scanner_socket) {
                                        print $scanner_socket "WATCH:$job->{target}\n";
                                        $scanner_socket->flush();
                                    }

                                    # Execute post-build hook if defined for this target
                                    if (exists $post_build{$job->{target}}) {
                                        my $post_cmd = $post_build{$job->{target}};
                                        warn "DEBUG: Running post-build for '$job->{target}': $post_cmd\n" if $ENV{SMAK_DEBUG};
                                        my $post_exit = execute_builtin($post_cmd);
                                        if (!defined $post_exit) {
                                            # Not a builtin, run as shell command
                                            $post_exit = system($post_cmd);
                                        }
                                        if ($post_exit != 0) {
                                            warn "Post-build hook failed for $job->{target}: $post_cmd\n";
                                        }
                                    }

                                    # If this job has siblings (multi-output pattern rule), mark them as complete too
                                    # Siblings can come from $job->{siblings} OR from compound target name (a&b format)
                                    my @siblings_to_mark;
                                    if ($job->{siblings} && @{$job->{siblings}} > 1) {
                                        @siblings_to_mark = @{$job->{siblings}};
                                    } elsif ($job->{target} =~ /&/) {
                                        # Compound target name encodes siblings: parse.cc&parse.h
                                        @siblings_to_mark = split(/&/, $job->{target});
                                    }
                                    if (@siblings_to_mark > 1) {
                                        for my $sibling (@siblings_to_mark) {
                                            next if $sibling eq $job->{target};  # Don't double-mark self
                                            $completed_targets{$sibling} = 1;
                                            $in_progress{$sibling} = "done";
                                            # Also tell scanner to watch siblings
                                            if ($scanner_socket) {
                                                print $scanner_socket "WATCH:$sibling\n";
                                                $scanner_socket->flush();
                                            }
                                            warn "DEBUG: Marking sibling '$sibling' as complete (created with '$job->{target}')\n" if $ENV{SMAK_DEBUG};
                                        }
                                    }
                                } else {
                                    # For phony targets, remove from in_progress entirely
                                    # This allows them to be queued again on next request
                                    delete $in_progress{$job->{target}};
                                    # But track that they ran this session for dependency checking
                                    $phony_ran_this_session{$job->{target}} = 1;
                                }
                                print STDERR "Task $task_id completed successfully: $job->{target}" .
                                             ($is_phony ? " (phony, removed from tracking)" : "") . "\n" if $ENV{SMAK_DEBUG};
                                $task_handled_successfully = 1;
                            } else {
                                # File doesn't exist even after retries - treat as failure
                                $in_progress{$job->{target}} = "failed";
                                print STDERR "Task $task_id FAILED: $job->{target} - output file not found\n";
                                $exit_code = 1;  # Mark as failed for composite target handling below
                            }
                        }

                        # Handle successful completion
                        if ($task_handled_successfully || ($exit_code == 0 && $job->{target} && $completed_targets{$job->{target}})) {
                            # ASSERTION: Verify successful job produced a valid target
                            # Only run expensive checks when debugging enabled (to avoid performance impact)
                            if (ASSERTIONS_ENABLED && $ENV{SMAK_DEBUG}) {
                                my $target = $job->{target};

                                # Check if this is a phony target
                                my $is_phony_target = 0;

                                # 1. Check .PHONY declarations in pseudo_deps
                                my $phony_key = "$makefile\t.PHONY";
                                if (exists $pseudo_deps{$phony_key}) {
                                    my @phony_targets = @{$pseudo_deps{$phony_key}};
                                    $is_phony_target = 1 if grep { $_ eq $target } @phony_targets;
                                }

                                # 2. Check for common phony target names
                                if (!$is_phony_target && $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/) {
                                    $is_phony_target = 1;
                                }

                                # 3. Check for automake-style phony targets (clean-*, install-*, mostlyclean-*, etc.)
                                if (!$is_phony_target && $target =~ /^(clean|install|uninstall|mostlyclean|distclean|maintainer-clean)-/) {
                                    $is_phony_target = 1;
                                }

                                # 4. Check pseudo_rule as fallback
                                if (!$is_phony_target) {
                                    for my $key (keys %pseudo_rule) {
                                        if ($key =~ /\t\Q$target\E$/) {
                                            $is_phony_target = 1;
                                            last;
                                        }
                                    }
                                }

                                if (!$is_phony_target && !$dry_run_mode) {
                                    # Target file must exist (skip in dry-run since files aren't created)
                                    # Use verify_target_exists which handles compound targets (x&y)
                                    if (!verify_target_exists($target, $job->{dir})) {
                                        assert_or_die(0, "Target '$target' marked as successfully built but file(s) do not exist");
                                    }

                                    # Skip mtime checking for compound targets - too complex
                                    next if $target =~ /&/;

                                    # Get all dependencies for this target (excluding order-only deps)
                                    # Since we don't have makefile in job hash, search all keys that end with this target
                                    my @deps;

                                    # Check fixed deps - search all keys
                                    for my $key (keys %fixed_deps) {
                                        if ($key =~ /\t\Q$target\E$/) {
                                            my $deps_ref = $fixed_deps{$key};
                                            if (ref($deps_ref) eq 'ARRAY') {
                                                push @deps, @$deps_ref;
                                            } else {
                                                push @deps, split /\s+/, $deps_ref;
                                            }
                                        }
                                    }

                                    # Check pseudo deps - search all keys
                                    for my $key (keys %pseudo_deps) {
                                        if ($key =~ /\t\Q$target\E$/) {
                                            my $deps_ref = $pseudo_deps{$key};
                                            if (ref($deps_ref) eq 'ARRAY') {
                                                push @deps, @$deps_ref;
                                            } else {
                                                push @deps, split /\s+/, $deps_ref;
                                            }
                                        }
                                    }

                                    # Verify target is newer than all dependencies
                                    my $target_path = $target =~ m{^/} ? $target : "$job->{dir}/$target";
                                    my $target_mtime = (stat($target_path))[9];
                                    for my $dep (@deps) {
                                        next if $dep eq '';  # Skip empty deps
                                        my $dep_path = $dep =~ m{^/} ? $dep : "$job->{dir}/$dep";
                                        if (-e $dep_path) {
                                            my $dep_mtime = (stat($dep_path))[9];
                                            if ($target_mtime < $dep_mtime) {
                                                assert_or_die(0,
                                                    "Target '$target' (mtime=$target_mtime) is older than dependency '$dep' (mtime=$dep_mtime) after successful build"
                                                );
                                            }
                                        }
                                    }
                                }
                            }

                            # Clear from stale cache after successful build
                            if (exists $stale_targets_cache{$job->{target}}) {
                                delete $stale_targets_cache{$job->{target}};
                                warn "DEBUG[" . __LINE__ . "]: Cleared '$job->{target}' from stale cache after successful build\n" if $ENV{SMAK_DEBUG};
                            }

                            # Check composite targets
                            for my $comp_target (keys %pending_composite) {
                                my $comp = $pending_composite{$comp_target};
                                $comp->{deps} = [grep { $_ ne $job->{target} } @{$comp->{deps}}];

                                if (@{$comp->{deps}} == 0) {
                                    vprint "All dependencies complete for composite target '$comp_target'\n";
                                    $completed_targets{$comp_target} = 1;
                                    $in_progress{$comp_target} = "done";
                                    if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                                        print {$comp->{master_socket}} "JOB_COMPLETE $comp_target 0\n";
                                    }
                                    delete $pending_composite{$comp_target};
                                }
                            }
                        } else {
                            # Check if we should auto-retry this target
                            my $should_retry = 0;
                            my $retry_reason = "";

                            print STDERR "DEBUG: Checking auto-retry for target '$job->{target}' (exit code $exit_code)\n";
                            print STDERR "DEBUG: Auto-retry patterns: " . join(", ", @auto_retry_patterns) . "\n";

                            my $retry_count = $retry_counts{$job->{target}} || 0;
                            if ($job->{target} && $retry_count < $max_retries) {  # Check against max_retries
                                # Analyze captured output for retryable errors
                                my @output = $job->{output} ? @{$job->{output}} : ();
                                print STDERR "DEBUG: Captured output has " . scalar(@output) . " lines\n";

                                for my $line (@output) {
                                    # Strip "ERROR: " prefix if present (we add this when capturing)
                                    my $clean_line = $line;
                                    $clean_line =~ s/^ERROR:\s*//;

                                    # Strip ANSI color codes and formatting (bold, underline, etc.)
                                    $clean_line =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;  # \x1b format
                                    $clean_line =~ s/\033\[[0-9;]*[a-zA-Z]//g;  # \033 format (octal)

                                    # Check for "No such file or directory" errors
                                    if ($clean_line =~ /(fatal error|error):\s+(.+?):\s+No such file or directory/i) {
                                        my $missing_file = $2;
                                        $missing_file =~ s/^\s+|\s+$//g;  # Trim whitespace

                                        print STDERR "Auto-retry: detected missing file '$missing_file' for target '$job->{target}'\n" if $ENV{SMAK_DEBUG};

                                        # Check if file exists now (race condition resolved)
                                        my $file_path = $missing_file =~ m{^/} ? $missing_file : "$job->{dir}/$missing_file";
                                        if (-f $file_path) {
                                            $should_retry = 1;
                                            $retry_reason = "file '$missing_file' exists now (race condition)";
                                            print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                            last;
                                        }

                                        # Check if the missing file matches auto-retry patterns
                                        if (!$should_retry && @auto_retry_patterns) {
                                            for my $pattern (@auto_retry_patterns) {
                                                # Convert glob pattern to regex
                                                my $regex = $pattern;
                                                $regex =~ s/\./\\./g;  # Escape dots
                                                $regex =~ s/\*/[^\/]*/g;  # * matches non-slash chars
                                                $regex =~ s/\?/./g;     # ? matches single char
                                                if ($missing_file =~ /^$regex$/ || $missing_file =~ /$regex$/) {
                                                    $should_retry = 1;
                                                    $retry_reason = "missing file '$missing_file' matches pattern '$pattern'";
                                                    print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                                    last;
                                                }
                                            }
                                        }

                                        last if $should_retry;  # Found a retryable error
                                    }

                                    # Check for linker "cannot find" errors (e.g., "ld: cannot find parse.o")
                                    if (!$should_retry && $clean_line =~ /(?:ld|collect2|link).*:\s*cannot find\s+(.+?)(?:\s*:|$)/i) {
                                        my $missing_file = $1;
                                        $missing_file =~ s/^\s+|\s+$//g;  # Trim whitespace
                                        $missing_file =~ s/^-l//;  # Remove -l prefix if it's a library

                                        print STDERR "Auto-retry: detected linker missing file '$missing_file' for target '$job->{target}'\n" if $ENV{SMAK_DEBUG};

                                        # Try to unblock the missing file if it's stuck in queue
                                        # Clear it from failed state and in_progress so it can be retried
                                        my $was_blocked = 0;
                                        if (exists $failed_targets{$missing_file}) {
                                            print STDERR "Auto-retry: clearing failed state for '$missing_file' to allow rebuild\n" if $ENV{SMAK_DEBUG};
                                            delete $failed_targets{$missing_file};
                                            $was_blocked = 1;
                                        }
                                        if (exists $in_progress{$missing_file}) {
                                            print STDERR "Auto-retry: clearing in_progress state for '$missing_file' (was: $in_progress{$missing_file})\n" if $ENV{SMAK_DEBUG};
                                            delete $in_progress{$missing_file};
                                            $was_blocked = 1;
                                        }

                                        # Also check if the source file (.cc for .o) is stuck
                                        if ($missing_file =~ /^(.+)\.o$/) {
                                            my $base = $1;
                                            for my $ext ('.cc', '.cpp', '.c', '.C') {
                                                my $source = "$base$ext";
                                                if (exists $in_progress{$source}) {
                                                    print STDERR "Auto-retry: clearing in_progress state for source '$source' (was: $in_progress{$source})\n" if $ENV{SMAK_DEBUG};
                                                    delete $in_progress{$source};
                                                    $was_blocked = 1;
                                                }
                                                if (exists $failed_targets{$source}) {
                                                    print STDERR "Auto-retry: clearing failed state for source '$source'\n" if $ENV{SMAK_DEBUG};
                                                    delete $failed_targets{$source};
                                                    $was_blocked = 1;
                                                }
                                            }
                                        }

                                        # Don't dispatch immediately - this can cause race conditions
                                        # Instead, mark that we need to build this dependency after all jobs complete
                                        if ($was_blocked) {
                                            print STDERR "Auto-retry: unblocked '$missing_file', will build after current jobs complete\n" if $ENV{SMAK_DEBUG};
                                        }

                                        # Retry for linker errors - likely a parallel build race condition
                                        # The missing file might be queued or building in another worker
                                        $should_retry = 1;
                                        $retry_reason = "linker missing file '$missing_file' (likely parallel build race)";
                                        print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                        last;
                                    }
                                }

                                # If no intelligent retry detected, fall back to target pattern matching
                                if (!$should_retry && @auto_retry_patterns) {
                                    for my $pattern (@auto_retry_patterns) {
                                        # Convert glob pattern to regex
                                        my $regex = $pattern;
                                        $regex =~ s/\./\\./g;  # Escape dots
                                        $regex =~ s/\*/[^\/]*/g;  # * matches non-slash chars
                                        $regex =~ s/\?/./g;     # ? matches single char
                                        if ($job->{target} =~ /^$regex$/ || $job->{target} =~ /$regex$/) {
                                            $should_retry = 1;
                                            $retry_reason = "matches pattern '$pattern'";
                                            last;
                                        }
                                    }
                                }
                            }

                            if ($should_retry) {
                                # Retry this target
                                $retry_counts{$job->{target}}++;
                                print STDERR "Task $task_id FAILED: $job->{target} (exit code $exit_code) - AUTO-RETRYING ($retry_reason, attempt " . $retry_counts{$job->{target}} . ")\n";

                                # Clear from failed targets so it can be rebuilt
                                delete $failed_targets{$job->{target}};
                                delete $in_progress{$job->{target}};

                                # Check if target is already queued to prevent duplicates
                                my $already_queued = 0;
                                for my $queued_job (@job_queue) {
                                    if ($queued_job->{target} eq $job->{target}) {
                                        $already_queued = 1;
                                        print STDERR "Auto-retry: target '$job->{target}' already in queue, skipping duplicate\n" if $ENV{SMAK_DEBUG};
                                        last;
                                    }
                                }

                                # Re-queue the target only if not already queued
                                if (!$already_queued) {
                                    # Use original layer for retry (preserved in job hash)
                                    my $retry_layer = $job->{layer} // 0;
                                    my $retry_job = {
                                        target => $job->{target},
                                        dir => $job->{dir},
                                        exec_dir => $job->{exec_dir} || $job->{dir},
                                        command => $job->{command},
                                        silent => $job->{silent} || 0,
                                        layer => $retry_layer,
                                    };
                                    add_job_to_layer($retry_job, $retry_layer);
                                    print STDERR "Auto-retry: re-queued '$job->{target}' to layer $retry_layer for retry\n" if $ENV{SMAK_DEBUG};
                                }

                                # Don't dispatch immediately - let dependencies build first
                                # The normal job dispatch cycle will handle it when dependencies are ready
                            } else {
                                # No retry - mark as failed
                                if ($job->{target}) {
                                    $in_progress{$job->{target}} = "failed";
                                    $failed_targets{$job->{target}} = $exit_code;
                                    $max_exit_code = $exit_code if $exit_code > $max_exit_code;
                                }
                                print STDERR "Task $task_id FAILED: $job->{target} (exit code $exit_code)\n";

                                # Check if this failed task is a dependency of any composite target
                                for my $comp_target (keys %pending_composite) {
                                    my $comp = $pending_composite{$comp_target};
                                    # Check if this failed target is in the composite's dependencies
                                    if (grep { $_ eq $job->{target} } @{$comp->{deps}}) {
                                        print STDERR "Composite target '$comp_target' FAILED because dependency '$job->{target}' failed (exit code $exit_code)\n";
                                        $in_progress{$comp_target} = "failed";
                                        if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                                            print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                                        }
                                        delete $pending_composite{$comp_target};
                                    }
                                }
                            }
                        }

                        print $master_socket "JOB_COMPLETE $job->{target} $exit_code\n" if $master_socket;

                        # Clean up dispatch tracking
                        delete $currently_dispatched{$job->{target}} if exists $currently_dispatched{$job->{target}};

                        # Check if this was the last job - send IDLE immediately if so
                        # This ensures non-cli mode gets IDLE promptly after all work completes
                        my $now_idle = (@job_queue == 0 && keys(%running_jobs) == 0);
                        if ($now_idle && $master_socket && !$idle_sent) {
                            my $final_exit = $max_exit_code;
                            if (!$final_exit && keys(%failed_targets)) {
                                for my $t (keys %failed_targets) {
                                    $final_exit = $failed_targets{$t} if $failed_targets{$t} > $final_exit;
                                }
                                $final_exit ||= 1;
                            }
                            my $idle_time = Time::HiRes::time();
                            print $master_socket "IDLE $final_exit $idle_time\n";
                            $master_socket->flush();
                            $idle_sent = 1;
                        }

                    } elsif ($line =~ /^OUTPUT (.*)$/) {
                        warn "CONSISTENCY-CHECK: Got OUTPUT: $1\n" if $ENV{SMAK_DEBUG};
                        print $master_socket "OUTPUT $1\n" if $master_socket;
                    } elsif ($line =~ /^ERROR (.*)$/) {
                        print $master_socket "ERROR $1\n" if $master_socket;
                    } elsif ($line =~ /^WARN (.*)$/) {
                        print $master_socket "WARN $1\n" if $master_socket;
                    }
                }
                $worker->blocking(1);
            }

            # Dispatch any queued jobs to newly freed workers before deadlock check
            # (pending messages may have completed jobs and freed workers)
            if (@job_queue > 0) {
                my $ready_workers = 0;
                for my $w (@workers) {
                    $ready_workers++ if $worker_status{$w}{ready};
                }
                if ($ready_workers > 0) {
                    dispatch_jobs();
                }
            }

            # Auto-rescan is now handled by the smak-scan background process
            # which sends events via scanner_socket using the FUSE protocol
        }

        # Reset timeout counter when we have activity
        $idle_timeouts = 0 if @ready;

        for my $socket (@ready) {
            if ($socket == $master_server) {
                # New master connecting
                my $new_master = $master_server->accept();
                if ($new_master) {
                    if ($master_socket) {
                        print STDERR "New master connecting, closing old connection\n";
                        $select->remove($master_socket);
                        close($master_socket);
                    }
                    $master_socket = $new_master;
                    $master_socket->autoflush(1);
                    $select->add($master_socket);
                    print STDERR "New master connected\n";

                    # Receive environment from new master
                    %worker_env = ();
                    while (my $line = <$master_socket>) {
                        chomp $line;
                        last if $line eq 'ENV_END';
                        if ($line =~ /^ENV (\w+)=(.*)$/) {
                            $worker_env{$1} = $2;
                        }
                    }
                    print $master_socket "JOBSERVER_WORKERS_READY\n";
                    print STDERR "New master ready\n";

                    # Check queue state before dispatching
                    check_queue_state("master reconnect");

                    # Dispatch any queued jobs that may have been waiting
                    dispatch_jobs();
                }

            } elsif (defined $master_socket && $socket == $master_socket) {
                # Master sent us something
                my $line = <$socket>;
                unless (defined $line) {
                    # Master disconnected - clean up silently
                    $select->remove($master_socket);
                    close($master_socket);
                    # Clear watch client if this was the watching client
                    $watch_client = undef if $watch_client && $watch_client == $master_socket;
                    $master_socket = undef;
                    next;
                }
                chomp $line;

                if ($line eq 'SHUTDOWN') {
                    print STDERR "Shutdown requested by master.\n" if $ENV{SMAK_DEBUG} || $ENV{SMAK_VERBOSE};
                    shutdown_workers();
                    print $master_socket "SHUTDOWN_ACK\n";
                    exit 0;

                } elsif ($line eq 'STATUS') {
                    # Report job-master status for debugging
                    my $queue_size = scalar(@job_queue);
                    my $running_count = keys(%running_jobs);
                    my $completed_count = keys(%completed_targets);
                    my $failed_count = keys(%failed_targets);
                    my $in_progress_count = keys(%in_progress);
                    my $pending_composite_count = keys(%pending_composite);

                    print $master_socket "STATUS_START\n";
                    print $master_socket "=== Job-Master Status ===\n";
                    print $master_socket "Queue: $queue_size jobs\n";
                    print $master_socket "Running: $running_count jobs\n";
                    print $master_socket "Completed: $completed_count targets\n";
                    print $master_socket "Failed: $failed_count targets\n";
                    print $master_socket "In-progress: $in_progress_count\n";
                    print $master_socket "Pending composite: $pending_composite_count\n";

                    # Show running job details
                    if ($running_count > 0) {
                        print $master_socket "Running jobs:\n";
                        for my $task_id (sort { $a <=> $b } keys %running_jobs) {
                            my $job = $running_jobs{$task_id};
                            print $master_socket "  [$task_id] $job->{target}\n";
                        }
                    }

                    # Show failed targets
                    if ($failed_count > 0) {
                        print $master_socket "Failed targets:\n";
                        for my $target (sort keys %failed_targets) {
                            print $master_socket "  $target (exit=$failed_targets{$target})\n";
                        }
                    }

                    # Show worker status
                    my $ready_workers = 0;
                    my $busy_workers = 0;
                    for my $w (@workers) {
                        if ($worker_status{$w}{ready}) {
                            $ready_workers++;
                        } else {
                            $busy_workers++;
                        }
                    }
                    print $master_socket "Workers: $ready_workers ready, $busy_workers busy (total " . scalar(@workers) . ")\n";
                    print $master_socket "Auto-rescan: " . ($auto_rescan ? "enabled" : "disabled") . "\n";

                    # Show pending composite targets (blocking completion)
                    if ($pending_composite_count > 0) {
                        print $master_socket "Pending composite targets:\n";
                        for my $target (sort keys %pending_composite) {
                            my $comp = $pending_composite{$target};
                            my $dep_count = scalar(@{$comp->{deps} || []});
                            print $master_socket "  $target (waiting for $dep_count deps)\n";
                            # Show first few pending deps
                            my @deps = @{$comp->{deps} || []};
                            my $max_show = $#deps < 4 ? $#deps : 4;
                            for my $i (0 .. $max_show) {
                                print $master_socket "    - $deps[$i]\n";
                            }
                            if (@deps > 5) {
                                print $master_socket "    ... and " . (@deps - 5) . " more\n";
                            }
                        }
                    }

                    print $master_socket "=== End Status ===\n";
                    print $master_socket "STATUS_END\n";
                    $master_socket->flush();

                } elsif ($line =~ /^CLI_OWNER (\d+)$/) {
                    # Update CLI owner in job master
                    my $new_owner = $1;
                    $SmakCli::cli_owner = $new_owner;
                    $ENV{SMAK_CLI_PID} = $new_owner;
                    vprint "CLI ownership claimed by PID $new_owner\n";

                    # Broadcast to all workers via socket
                    for my $worker (@workers) {
                        print $worker "CLI_OWNER $new_owner\n";
                        $worker->flush() if $worker->can('flush');
                    }

                    # Send SIGWINCH to job master itself to trigger any handlers
                    kill 'WINCH', $$;

                } elsif ($line =~ /^BUILD (.+)$/) {
                    # Handle recursive smak invocation - child smak is relaying its build request
                    my $build_args = $1;
                    warn "Received BUILD request: $build_args\n" if $ENV{SMAK_DEBUG};

                    # Parse: directory target1 target2 ...
                    my ($dir, @targets) = split(/\s+/, $build_args);

                    # Save current directory
                    use Cwd 'getcwd';
                    my $saved_cwd = getcwd();

                    # Change to target directory
                    chdir($dir) or do {
                        warn "Failed to chdir to $dir: $!\n";
                        print $socket "COMPLETE 1\n";
                        next;
                    };

                    # Parse makefile in new directory if needed
                    my $saved_makefile = $makefile;
                    my $new_makefile = 'Makefile';
                    if (!exists $fixed_deps{"$new_makefile\t" . ($targets[0] || 'all')}) {
                        eval { parse_makefile($new_makefile); };
                        if ($@) {
                            warn "Failed to parse makefile: $@\n";
                            chdir($saved_cwd);
                            $makefile = $saved_makefile;
                            print $socket "COMPLETE 1\n";
                            next;
                        }
                    }
                    $makefile = $new_makefile;

                    # Queue targets for parallel dispatch (instead of sequential build_target)
                    # Use $dir as prefix for directory-qualified target tracking
                    my $prefix = ($dir eq '.' || $dir eq $saved_cwd) ? '' : $dir;
                    for my $target (@targets) {
                        queue_target_recursive($target, $dir, $master_socket, 0, $prefix);
                    }

                    # Restore directory and makefile (targets are now queued)
                    chdir($saved_cwd);
                    $makefile = $saved_makefile;

                    # Track this socket so we can send COMPLETE when all queued work finishes
                    # For now, send COMPLETE immediately - the work is queued and will dispatch
                    # TODO: properly track completion of these specific targets
                    print $socket "COMPLETE 0\n";
                    $socket->flush();

                } elsif ($line =~ /^SUBMIT_JOB$/) {
                    # Read job details
                    my $target = <$socket>; chomp $target if defined $target;
                    my $dir = <$socket>; chomp $dir if defined $dir;
                    my $cmd = <$socket>; chomp $cmd if defined $cmd;

                    vprint "Received job request for target: $target\n";

                    # Reset layer dispatch state for new build
                    # This ensures layer 0 jobs are dispatchable when a new build starts
                    if (@job_queue == 0 && keys(%running_jobs) == 0) {
                        $current_dispatch_layer = 0;
                        $max_dispatch_layer = 0;
                        @job_layers = ();
                        print STDERR "DEBUG: Reset layer state for new build\n" if $ENV{SMAK_DEBUG};
                    }

                    # Lookup dependencies using the key format "makefile\ttarget"
                    my $key = "$makefile\t$target";
                    my @deps;
                    my $rule = '';

                    # Find target in fixed, pattern, or pseudo rules
                    if (exists $fixed_deps{$key}) {
                        @deps = @{$fixed_deps{$key} || []};
                        $rule = $fixed_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in fixed_deps\n" if $ENV{SMAK_DEBUG};
                    } elsif (exists $pattern_deps{$key}) {
                        @deps = @{$pattern_deps{$key} || []};
                        $rule = $pattern_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in pattern_deps\n" if $ENV{SMAK_DEBUG};
                    } elsif (exists $pseudo_deps{$key}) {
                        @deps = @{$pseudo_deps{$key} || []};
                        $rule = $pseudo_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in pseudo_deps\n" if $ENV{SMAK_DEBUG};
                    } else {
                        print STDERR "DEBUG: '$target' NOT found in any dependency tables\n" if $ENV{SMAK_DEBUG};
                    }

                    print STDERR "DEBUG: Target '$target' has " . scalar(@deps) . " dependencies\n" if $ENV{SMAK_DEBUG};
                    print STDERR "DEBUG: Dependencies: " . join(', ', @deps) . "\n" if $ENV{SMAK_DEBUG} && @deps;

                    # Use recursive queuing to handle dependencies
                    # Compute prefix from dir for directory-qualified tracking
                    my $prefix = '';
                    if ($dir && $dir ne '.' && $dir !~ m{^/}) {
                        $prefix = $dir;  # Relative subdirectory becomes the prefix
                    }
                    queue_target_recursive($target, $dir, $master_socket, 0, $prefix);

                    vprint "Job queue now has " . scalar(@job_queue) . " jobs\n";
                    broadcast_observers("QUEUED $target");

                    # Try to dispatch
                    dispatch_jobs();

                    # Reset timeout counter and idle flag after job submission
                    $idle_timeouts = 0;
                    $idle_sent = 0;

                    # Check if target is already complete AND no work was dispatched
                    # If so, send JOB_COMPLETE immediately so client doesn't hang
                    # Only do this if the target is truly done with no pending work

                    # Check if target is phony (should never be cached as complete)
                    my $is_common_phony = $target =~ /^(all|clean|install|test|check|depend|dist|
                                                        distclean|maintainer-clean|mostlyclean|
                                                        cmake_check_build_system|help|list|
                                                        package|preinstall|rebuild_cache|edit_cache)$/x;
                    my $is_phony = $is_common_phony || exists $pseudo_deps{"$makefile\t$target"};

                    my $target_complete = !$is_phony && (exists $completed_targets{$target} ||
                                          (exists $in_progress{$target} && $in_progress{$target} eq "done"));
                    my $target_failed = (exists $failed_targets{$target} ||
                                        (exists $in_progress{$target} && $in_progress{$target} eq "failed"));

                    # Check if target or its dependencies are being built
                    my $work_in_progress = (exists $in_progress{$target} &&
                                           $in_progress{$target} ne "done" &&
                                           $in_progress{$target} ne "failed") ||
                                          (@job_queue > 0) ||
                                          (keys %running_jobs > 0);

                    if ($target_complete && !$work_in_progress) {
                        print $master_socket "JOB_COMPLETE $target 0\n" if $master_socket && defined fileno($master_socket);
                        print STDERR "Target '$target' already up-to-date, notified client\n" if $ENV{SMAK_DEBUG};
                        # Send IDLE since no work is pending
                        if (!$idle_sent && $master_socket) {
                            my $idle_time = Time::HiRes::time();
                            print $master_socket "IDLE 0 $idle_time\n";
                            $master_socket->flush();
                            $idle_sent = 1;
                        }
                    } elsif ($target_failed && !$work_in_progress) {
                        my $exit_code = $failed_targets{$target} || 1;
                        print $master_socket "JOB_COMPLETE $target $exit_code\n" if $master_socket && defined fileno($master_socket);
                        print STDERR "Target '$target' already failed, notified client (exit $exit_code)\n" if $ENV{SMAK_DEBUG};
                        # Send IDLE since no work is pending
                        if (!$idle_sent && $master_socket) {
                            my $idle_time = Time::HiRes::time();
                            print $master_socket "IDLE $exit_code $idle_time\n";
                            $master_socket->flush();
                            $idle_sent = 1;
                        }
                    }
                    # Otherwise, work is in progress - JOB_COMPLETE will be sent when work finishes

                } elsif ($line =~ /^COMMAND\s+(.*)/) {
		    print STDERR "Command: $1\n";
		    interactive_debug($master_socket,$1);
		    print $master_socket "END_COMMAND\n";
		    
                } elsif ($line =~ /^IN_PROGRESS(\s(.*))*$/) {
		    my $op = $2;
		    my $clear = ($op =~ /clear/i);
		    foreach my $target (keys %in_progress)  {
			my $status = $in_progress{$target};
			my $message = $status;
			if (! defined $message) {
			    $message = "unknown";
			}
			# If it's a socket reference, query the worker for actual status
			if (ref($status) eq 'IO::Socket::INET') {
			    eval {
				local $SIG{ALRM} = sub { die "timeout\n" };
				alarm(1);  # 1 second timeout
				print $status "STATUS\n";
				$message = <$status>;
				alarm(0);
				if (defined $message) {
				    chomp $message;
				    # Response format: "RUNNING task_id" or "READY"
				    if ("" eq $message) {
					$message = "with worker(?)";
				    }
				}
			    };
			    if ($@) {
				$message = "worker unresponsive";
			    }
			}

			# When clearing, skip printing 'done' entries and remove them
			if ('done' eq $status && $clear) {
			    delete $in_progress{$target};
			    next;  # Skip printing this entry
			}

			print $master_socket "$target\t$message\n";
		    }
		    print $master_socket "PROGRESS_END\n";

                } elsif ($line =~ /^STATUS$/) {
                    # Send status information
                    send_status($master_socket);

                } elsif ($line =~ /^LIST_TASKS$/) {
                    # Send task list to master
                    print $master_socket "Queued tasks: " . scalar(@job_queue) . "\n";
                    for my $job (@job_queue) {
                        print $master_socket "  [QUEUED] $job->{target}\n";
                    }
                    print $master_socket "Running tasks: " . scalar(keys %running_jobs) . "\n";
                    for my $task_id (sort { $a <=> $b } keys %running_jobs) {
                        my $job = $running_jobs{$task_id};
                        my $state = $job->{started} ? 'RUNNING' : 'DISPATCHED';
                        print $master_socket "  [$state] Task $task_id: $job->{target}\n";
                    }
                    print $master_socket "TASKS_END\n";

                } elsif ($line =~ /^KILL_WORKERS$/) {
                    # Cancel all running jobs but keep workers alive
                    print STDERR "Cancelling all running jobs\n";
                    my $cancelled_count = 0;
                    for my $worker (@workers) {
                        if (!$worker_status{$worker}{ready}) {
                            # Worker is busy - send cancel
                            print $worker "CANCEL\n";
                            $cancelled_count++;
                        }
                    }
                    # Clear all build state so next build can start fresh
                    my $queue_cleared = scalar(@job_queue);
                    @job_queue = ();
                    %running_jobs = ();
                    %in_progress = ();
                    print $master_socket "Cancelled $cancelled_count job(s), cleared $queue_cleared queued\n";

                } elsif ($line =~ /^BENCHMARK$/) {
                    # Benchmark worker communication latency
                    use Time::HiRes qw(time);

                    print $master_socket "Benchmarking worker communication...\n";
                    my $num_tests = 100;
                    my $total_time = 0;

                    # Find a ready worker
                    my $test_worker;
                    for my $w (@workers) {
                        if ($worker_status{$w}{ready}) {
                            $test_worker = $w;
                            last;
                        }
                    }

                    if (!$test_worker) {
                        print $master_socket "ERROR: No ready workers available\n";
                    } else {
                        # Send test tasks
                        for my $i (1..$num_tests) {
                            my $start = time();

                            # Send dummy task
                            print $test_worker "TASK $i\n";
                            print $test_worker "DIR /tmp\n";
                            print $test_worker "CMD true\n";

                            # Read responses until READY
                            while (1) {
                                my $resp = <$test_worker>;
                                last unless defined $resp;
                                chomp $resp;
                                last if $resp eq 'READY';
                            }

                            $total_time += (time() - $start);
                        }

                        my $avg_ms = ($total_time / $num_tests) * 1000;
                        my $throughput = $num_tests / $total_time;

                        print $master_socket sprintf("Completed %d round-trips in %.3fs\n", $num_tests, $total_time);
                        print $master_socket sprintf("Average latency: %.2f ms/command\n", $avg_ms);
                        print $master_socket sprintf("Throughput: %.1f commands/sec\n", $throughput);
                    }

                } elsif ($line =~ /^ADD_WORKER (\d+)$/) {
                    my $count = $1;
                    print STDERR "Adding $count worker(s)\n";

                    # Spawn new workers
                    my $worker_port = $worker_server->sockport();
                    for (my $i = 0; $i < $count; $i++) {
                        my $worker_pid = fork();
                        if ($worker_pid == 0) {
                            if ($ssh_host) {
                                my $local_path = getcwd();
                                $local_path =~ s=^$fuse_mountpoint/== if $fuse_mountpoint;
                                # SSH mode: launch worker on remote host with reverse port forwarding
                                # Use -R to tunnel remote port back to local worker_port
                                my $remote_port = 30000 + int(rand(10000));  # Random port 30000-39999
                                my @ssh_cmd = ('ssh', '-n', '-R', "$remote_port:127.0.0.1:$worker_port", $ssh_host);
                                if ($remote_cd) {
                                    push @ssh_cmd, "smak-worker -cd $remote_cd/$local_path 127.0.0.1:$remote_port";
                                } else {
                                    push @ssh_cmd, "smak-worker 127.0.0.1:$remote_port";
                                }
                                exec(@ssh_cmd);
                                die "Failed to exec SSH worker: $!\n";
                            } else {
                                # Local mode
                                exec($worker_script, "127.0.0.1:$worker_port");
                                die "Failed to exec worker: $!\n";
                            }
                        }
                    }
		    my $w = 1 + $#workers;
                    print $master_socket "Added $count worker(s), total is $w. Workers will connect asynchronously.\n";

                } elsif ($line =~ /^REMOVE_WORKER (\d+)$/) {
                    my $count = $1;
                    my $removed = 0;

                    # Remove idle workers (ready workers first, to avoid interrupting running jobs)
                    for my $worker (@workers) {
                        last if $removed >= $count;
                        if ($worker_status{$worker}{ready}) {
                            print STDERR "Removing ready worker\n";
                            print $worker "SHUTDOWN\n";
                            close($worker);
                            $select->remove($worker);
                            delete $worker_status{$worker};
                            $removed++;
                        }
                    }

                    # Update workers array
                    @workers = grep { exists $worker_status{$_} } @workers;
		    my $w_count = 1 + $#workers;

                    if ($removed < $count) {
                        print $master_socket "Removed $removed, now have $w_count worker(s) (only $removed idle workers available)\n";
                    } else {
                        print $master_socket "Removed $count worker(s), $w_count remain\n";
                    }

                } elsif ($line =~ /^RESTART_WORKERS (\d+)$/) {
                    my $new_count = $1;
                    # Kill existing workers
                    print STDERR "Restarting workers ($new_count)\n";
                    for my $worker (@workers) {
                        print $worker "SHUTDOWN\n";
                        close($worker);
                        $select->remove($worker);
                    }
                    @workers = ();
                    %worker_status = ();
                    %running_jobs = ();

                    # Spawn new workers
                    my $worker_port = $worker_server->sockport();
                    for (my $i = 0; $i < $new_count; $i++) {
                        my $worker_pid = fork();
                        if ($worker_pid == 0) {
                            if ($ssh_host) {
                                my $local_path = getcwd();
                                $local_path =~ s=^$fuse_mountpoint/== if $fuse_mountpoint;
                                # SSH mode: launch worker on remote host with reverse port forwarding
                                # Use -R to tunnel remote port back to local worker_port
                                my $remote_port = 30000 + int(rand(10000));  # Random port 30000-39999
                                my @ssh_cmd = ('ssh', '-n', '-R', "$remote_port:127.0.0.1:$worker_port", $ssh_host);
                                if ($remote_cd) {
                                    push @ssh_cmd, "smak-worker -cd $remote_cd/$local_path 127.0.0.1:$remote_port";
                                } else {
                                    push @ssh_cmd, "smak-worker 127.0.0.1:$remote_port";
                                }
                                exec(@ssh_cmd);
                                die "Failed to exec SSH worker: $!\n";
                            } else {
                                # Local mode
                                exec($worker_script, "127.0.0.1:$worker_port");
                                die "Failed to exec worker: $!\n";
                            }
                        }
                    }
                    print $master_socket "Restarting $new_count workers...\n";

                } elsif ($line =~ /^RESET$/) {
                    # Clear build state to allow rebuilding after clean
                    print STDERR "Resetting build state...\n";
                    %completed_targets = ();
                    %failed_targets = ();
                    %in_progress = ();
                    %pending_composite = ();
                    %retry_counts = ();
                    @job_queue = ();
                    %stale_targets_cache = ();
                    print STDERR "Build state cleared: all targets will be re-evaluated\n";
                    print $master_socket "Build state reset. All targets will be re-evaluated on next build.\n";

                } elsif ($line =~ /^RESCAN(_AUTO|_NOAUTO)?$/) {
                    # Rescan timestamps and mark stale targets
                    my $mode = $1 || '';
                    my $auto = ($mode eq '_AUTO');
                    my $noauto = ($mode eq '_NOAUTO');
                    my $stale_count = 0;

                    if ($noauto) {
                        # Disable auto-rescan
                        $auto_rescan = 0;
                        print $master_socket "Auto-rescan disabled.\n";
                    } else {
                        print STDERR "Rescanning file timestamps...\n" if $ENV{SMAK_DEBUG};

                        # Get makefile directory for relative path resolution
                        my $makefile_dir = $makefile;
                        $makefile_dir =~ s{/[^/]*$}{};  # Remove filename
                        $makefile_dir = '.' if $makefile_dir eq $makefile;  # No dir separator found

                        # Check all completed targets to see if they need rebuilding
                        for my $target (keys %completed_targets) {
                            # Get full path to target
                            my $target_path = $target =~ m{^/} ? $target : "$makefile_dir/$target";

                            # If target was deleted, mark as stale
                            if (!-e $target_path) {
                                delete $completed_targets{$target};
                                delete $in_progress{$target};
                                $stale_targets_cache{$target} = time();
                                $stale_count++;
                                print STDERR "  Marked stale (deleted): $target\n" if $ENV{SMAK_DEBUG};
                                next;
                            }

                            # Check if existing target needs rebuilding based on dependencies
                            if (needs_rebuild($target)) {
                                delete $completed_targets{$target};
                                delete $in_progress{$target};  # Also clear from in_progress
                                $stale_targets_cache{$target} = time();
                                $stale_count++;
                                print STDERR "  Marked stale (modified): $target\n" if $ENV{SMAK_DEBUG};
                            }
                        }

                        # Also check failed targets - if their dependencies are now stale, clear the failed status
                        for my $target (keys %failed_targets) {
                            if (needs_rebuild($target)) {
                                delete $failed_targets{$target};
                                delete $in_progress{$target};
                                $stale_targets_cache{$target} = time();
                                $stale_count++;
                                print STDERR "  Cleared failed status (dependencies changed): $target\n" if $ENV{SMAK_DEBUG};
                            }
                        }

                        # Clear failed composite targets if any of their dependencies became stale
                        for my $target (keys %in_progress) {
                            if ($in_progress{$target} eq 'failed') {
                                # Check if this is a composite target (has dependencies)
                                my $target_key = "$makefile\t$target";
                                if (exists $fixed_deps{$target_key} || exists $pattern_deps{$target_key}) {
                                    my @deps = exists $fixed_deps{$target_key} ? @{$fixed_deps{$target_key}} :
                                               exists $pattern_deps{$target_key} ? @{$pattern_deps{$target_key}} : ();

                                    # Check if any dependency is now stale
                                    my $has_stale_dep = 0;
                                    for my $dep (@deps) {
                                        if (exists $stale_targets_cache{$dep} ||
                                            (!exists $completed_targets{$dep} && !exists $phony_ran_this_session{$dep} && !exists $failed_targets{$dep})) {
                                            $has_stale_dep = 1;
                                            last;
                                        }
                                    }

                                    if ($has_stale_dep) {
                                        delete $in_progress{$target};
                                        delete $failed_targets{$target};
                                        print STDERR "  Cleared failed composite target (dependencies changed): $target\n" if $ENV{SMAK_DEBUG};
                                        $stale_count++;
                                    }
                                }
                            }
                        }

                        if ($auto) {
                            # Check if FUSE watch mode is active
                            if ($fuse_auto_clear) {
                                print $master_socket "rescan -auto can't be activated unless you do 'unwatch' first.\n";
                            } else {
                                # Enable periodic rescanning in check_queue_state
                                $auto_rescan = 1;
                                print $master_socket "Auto-rescan enabled. Found $stale_count stale target(s).\n";
                            }
                        } else {
                            print $master_socket "Rescan complete. Marked $stale_count target(s) as stale.\n";
                        }
                    }

                } elsif ($line =~ /^LIST_FILES$/) {
                    # List tracked file modifications
                    if ($fuse_socket) {
                        print $master_socket "Tracked file modifications:\n";
                        for my $path (sort keys %file_modifications) {
                            my $info = $file_modifications{$path};
                            my $pids = join(', ', @{$info->{workers}});
                            print $master_socket "  $path (PIDs: $pids)\n";
                        }
                        print $master_socket "FILES_END\n";
                    } else {
                        print $master_socket "FUSE monitoring not available\n";
                        print $master_socket "FILES_END\n";
                    }

                } elsif ($line =~ /^MARK_DIRTY:(.+)$/) {
                    # Mark a file as dirty (out-of-date)
                    my $file = $1;
                    $dirty_files{$file} = 1;

                    # Clear from completed targets and in_progress so it will be rebuilt
                    # This handles both direct removal (rm command) and FUSE events
                    delete $completed_targets{$file};
                    delete $in_progress{$file};

                    # Also try with absolute path in case it was tracked that way
                    my $abs_path = File::Spec->rel2abs($file);
                    delete $completed_targets{$abs_path};
                    delete $in_progress{$abs_path};

                    print STDERR "Marked file as dirty: $file\n" if $ENV{SMAK_DEBUG};

                } elsif ($line =~ /^BUILD:(.+)$/) {
                    # Build a target in the job server context (has access to dirty_files)
                    my $target = $1;
                    eval {
                        build_target($target);
                    };
                    if ($@) {
                        my $error = $@;
                        chomp $error;
                        print $master_socket "BUILD_ERROR:$error\n";
                    } else {
                        print $master_socket "BUILD_SUCCESS\n";
                    }
                    print $master_socket "BUILD_END\n";

                } elsif ($line =~ /^LIST_STALE$/) {
                    # List targets that need rebuilding based on tracked modifications and dirty files
                    eval {
                        my %stale_targets;

                        # First, include targets from the stale cache (populated during initial pass/dry-run)
                        for my $target (keys %stale_targets_cache) {
                            $stale_targets{$target} = 1;
                        }

                        # Get current working directory to create relative paths
                        my $cwd = abs_path('.');

                        # Combine FUSE-tracked modifications and manually marked dirty files
                        my @all_modified_files = (keys %file_modifications, keys %dirty_files);

                        # For each modified file, find targets that depend on it
                        for my $modified_file (@all_modified_files) {
                        # Try multiple path variations for matching
                        my @path_variations;

                        # Original path
                        push @path_variations, $modified_file;

                        # Just filename
                        my $basename = $modified_file;
                        $basename =~ s{^.*/}{};
                        push @path_variations, $basename;

                        # Relative to CWD
                        if ($modified_file =~ /^\Q$cwd\E\/(.+)$/) {
                            push @path_variations, $1;
                        }

                        # Check all dependency hashes for this file
                        for my $key (keys %fixed_deps) {
                            my $deps_ref = $fixed_deps{$key};
                            next unless defined $deps_ref && ref($deps_ref) eq 'ARRAY';

                            # Extract target name from key (format: "makefile\ttarget")
                            my ($mf, $target) = split(/\t/, $key, 2);

                            # Check each dependency
                            my @deps = @$deps_ref;
                            for my $dep (@deps) {
                                for my $path_var (@path_variations) {
                                    if ($dep eq $path_var || $dep =~ /\Q$path_var\E$/) {
                                        $stale_targets{$target} = 1;
                                        last;
                                    }
                                }
                            }
                        }

                        # Also check pattern deps
                        for my $pattern_key (keys %pattern_deps) {
                            my $deps_ref = $pattern_deps{$pattern_key};
                            next unless defined $deps_ref && ref($deps_ref) eq 'ARRAY';

                            # Extract pattern from key (format: "makefile\tpattern")
                            my ($mf, $pattern) = split(/\t/, $pattern_key, 2);

                            my @deps = @$deps_ref;
                            for my $dep (@deps) {
                                for my $path_var (@path_variations) {
                                    if ($dep eq $path_var || $dep =~ /\Q$path_var\E$/) {
                                        # Find targets matching this pattern
                                        for my $target_key (keys %fixed_deps) {
                                            my ($target_mf, $target) = split(/\t/, $target_key, 2);
                                            if ($target =~ /$pattern/) {
                                                $stale_targets{$target} = 1;
                                            }
                                        }
                                        last;
                                    }
                                }
                            }
                        }
                    }

                    # Check for .d dependency files
                    # .d files are generated by compiler (e.g., gcc -MMD) and contain
                    # explicit target: dependency mappings
                    for my $modified_file (@all_modified_files) {
                        # For source files, look for corresponding .d files
                        # Pattern: foo.C -> foo.C.o.d or foo.o.d
                        next unless $modified_file =~ /\.(c|cc|cpp|C|cxx|c\+\+)$/;

                        my $basename = $modified_file;
                        $basename =~ s{^.*/}{};  # Remove directory path

                        # Generate potential .d file names
                        my @potential_d_files;

                        # Try: foo.C.o.d (source.ext.o.d pattern)
                        push @potential_d_files, `find . -name '$basename.o.d' 2>/dev/null`;

                        # Try: foo.o.d (base.o.d pattern)
                        if ($basename =~ /^(.+)\.(c|cc|cpp|C|cxx|c\+\+)$/) {
                            my $base = $1;
                            push @potential_d_files, `find . -name '$base.o.d' 2>/dev/null`;
                        }

                        chomp @potential_d_files;

                        for my $d_file (@potential_d_files) {
                            next unless -f $d_file;

                            # Parse the .d file to extract target
                            open(my $fh, '<', $d_file) or next;
                            my $content = do { local $/; <$fh> };
                            close($fh);

                            # .d file format: target: dep1 dep2 \
                            #                  dep3 dep4
                            if ($content =~ /^([^:]+):/) {
                                my $target = $1;
                                $target =~ s/^\s+|\s+$//g;
                                $stale_targets{$target} = 1;
                                print STDERR "Found stale target via .d file: $target (depends on $modified_file)\n" if $ENV{SMAK_DEBUG};
                            }
                        }
                    }

                    # Send stale targets
                    for my $target (sort keys %stale_targets) {
                        print $master_socket "STALE:$target\n";
                    }
                    };  # Close eval block

                    if ($@) {
                        print STDERR "Error in LIST_STALE: $@\n" if $ENV{SMAK_DEBUG};
                    }

                    # Always send end marker, even if there was an error
                    print $master_socket "STALE_END\n";

                } elsif ($line =~ /^NEEDS:(.+)$/) {
                    # Show which targets depend on a specific file
                    # Wrap in eval to catch any errors
                    eval {
                        my $query_file = $1;
                        my %matching_targets;

                        warn "DEBUG: NEEDS query for '$query_file'\n" if $ENV{SMAK_DEBUG};

                        # Get current working directory for relative path handling
                        my $cwd = abs_path('.') || '.';

                        # Generate path variations for the query file
                        my @path_variations;
                        push @path_variations, $query_file;

                        # Add absolute path if query is relative
                        if ($query_file !~ /^\//) {
                            push @path_variations, "$cwd/$query_file";
                        }

                        # Add just basename
                        my $basename = $query_file;
                        $basename =~ s{^.*/}{};
                        push @path_variations, $basename unless $basename eq $query_file;

                        # Check all dependency hashes
                        if (%fixed_deps) {
                            for my $target (keys %fixed_deps) {
                                my $deps_ref = $fixed_deps{$target};
                                next unless defined $deps_ref;

                                # fixed_deps stores arrayrefs, not strings
                                my @deps = ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ();
                                @deps = map {
                                    my $dep = $_;
                                    # Expand $MV{VAR} references
                                    while ($dep =~ /\$MV\{([^}]+)\}/) {
                                        my $var = $1;
                                        my $val = $MV{$var} // '';
                                        $dep =~ s/\$MV\{\Q$var\E\}/$val/;
                                    }
                                    # If expansion resulted in multiple space-separated values, split them
                                    if ($dep =~ /\s/) {
                                        split /\s+/, $dep;
                                    } else {
                                        $dep;
                                    }
                                } @deps;
                                # Flatten and filter empty strings
                                @deps = grep { $_ ne '' } @deps;

                                # Check each dependency
                                for my $dep (@deps) {
                                    for my $path_var (@path_variations) {
                                        if ($dep eq $path_var || $dep =~ /\Q$path_var\E$/) {
                                            $matching_targets{$target} = 1;
                                            last;
                                        }
                                    }
                                }
                            }
                        }

                        # Also check pattern deps
                        if (%pattern_deps) {
                            for my $pattern (keys %pattern_deps) {
                                my $deps_ref = $pattern_deps{$pattern};
                                next unless defined $deps_ref;

                                # pattern_deps stores arrayrefs, not strings
                                my @deps = ref($deps_ref) eq 'ARRAY' ? @$deps_ref : ();
                                @deps = map {
                                    my $dep = $_;
                                    # Expand $MV{VAR} references
                                    while ($dep =~ /\$MV\{([^}]+)\}/) {
                                        my $var = $1;
                                        my $val = $MV{$var} // '';
                                        $dep =~ s/\$MV\{\Q$var\E\}/$val/;
                                    }
                                    # If expansion resulted in multiple space-separated values, split them
                                    if ($dep =~ /\s/) {
                                        split /\s+/, $dep;
                                    } else {
                                        $dep;
                                    }
                                } @deps;
                                # Flatten and filter empty strings
                                @deps = grep { $_ ne '' } @deps;

                                # Check each dependency
                                for my $dep (@deps) {
                                    for my $path_var (@path_variations) {
                                        if ($dep eq $path_var || $dep =~ /\Q$path_var\E$/) {
                                            # Find targets matching this pattern
                                            for my $target (keys %fixed_deps) {
                                                if ($target =~ /$pattern/) {
                                                    $matching_targets{$target} = 1;
                                                }
                                            }
                                            last;
                                        }
                                    }
                                }
                            }
                        }

                        # Send matching targets (strip makefile prefix from keys)
                        for my $key (sort keys %matching_targets) {
                            # Extract just the target name from "makefile\ttarget" format
                            my ($mf, $target) = split(/\t/, $key, 2);
                            $target = $key unless defined $target;  # Fallback if no tab
                            print $master_socket "NEEDS:$target\n";
                        }
                    };
                    if ($@) {
                        print STDERR "Error processing NEEDS request: $@\n" if $ENV{SMAK_DEBUG};
                    }
                    # Always send end marker even if there was an error
                    print $master_socket "NEEDS_END\n";
                    $master_socket->flush();

                } elsif ($line =~ /^WATCH_START$/) {
                    # Enable watch mode - send file change notifications to this client
                    if ($fuse_socket) {
                        $watch_client = $master_socket;
                        $fuse_auto_clear = 1;  # Enable auto-clear (like rescan -auto)
                        print $master_socket "WATCH_STARTED\n";
                        print STDERR "Watch mode enabled (FUSE auto-clear active)\n" if $ENV{SMAK_DEBUG};
                    } else {
                        print $master_socket "WATCH_UNAVAILABLE (no FUSE)\n";
                    }

                } elsif ($line =~ /^WATCH_STOP$/) {
                    # Disable watch mode
                    if ($watch_client && $watch_client == $master_socket) {
                        $watch_client = undef;
                        $fuse_auto_clear = 0;  # Disable auto-clear, events still collected
                        print $master_socket "WATCH_STOPPED\n";
                        print STDERR "Watch mode disabled (FUSE events saved for manual rescan)\n" if $ENV{SMAK_DEBUG};
                    } else {
                        print $master_socket "WATCH_NOT_ACTIVE\n";
                    }

                } elsif ($line =~ /^ENV (\w+)=(.*)$/) {
                    # Update environment variable in job-master and workers
                    my ($var, $value) = ($1, $2);
                    $ENV{$var} = $value;
                    $worker_env{$var} = $value;

                    # Send update to all connected workers
                    for my $worker (@workers) {
                        print $worker "ENV_START\n";
                        print $worker "ENV $var=$value\n";
                        print $worker "ENV_END\n";
                    }

                    print STDERR "Updated environment: $var=$value\n" if $ENV{SMAK_DEBUG};
                }

            } elsif ($socket == $worker_server) {
                # New worker connecting
                my $worker = $worker_server->accept();
                if ($worker) {
                    $worker->autoflush(1);
                    # Disable Nagle's algorithm for low latency
                    use Socket qw(IPPROTO_TCP TCP_NODELAY);
                    setsockopt($worker, IPPROTO_TCP, TCP_NODELAY, 1);

                    # Read READY signal from worker
                    my $ready_msg = <$worker>;
                    chomp $ready_msg if defined $ready_msg;
                    if ($ready_msg eq 'READY') {
                        $select->add($worker);
                        push @workers, $worker;
                        $worker_status{$worker} = {ready => 0, task_id => 0};
                        warn "Worker connected during runtime\n";

                        # Send environment to new worker
                        print $worker "ENV_START\n";
                        for my $key (keys %worker_env) {
                            print $worker "ENV $key=$worker_env{$key}\n";
                        }
                        print $worker "ENV_END\n";

                        # Now worker is ready
                        $worker_status{$worker}{ready} = 1;
                        vprint "Runtime worker environment sent, now ready\n";
                    } else {
                        warn "Worker connected but didn't send READY, got: $ready_msg\n";
                        close($worker);
                    }
                }

            } elsif ($socket == $observer_server) {
                # New observer connecting
                my $observer = $observer_server->accept();
                if ($observer) {
                    $observer->autoflush(1);
                    $select->add($observer);
                    push @observers, $observer;
                    print STDERR "Observer connected\n";
                    # Send current status
                    send_status($observer);
                }

            } elsif (grep { $_ == $socket } @observers) {
                # Observer sent command
                my $line = <$socket>;
                unless (defined $line) {
                    # Observer disconnected
                    print STDERR "Observer disconnected\n";
                    $select->remove($socket);
                    @observers = grep { $_ != $socket } @observers;
                    next;
                }
                chomp $line;

                if ($line eq 'STATUS') {
                    send_status($socket);
                } elsif ($line eq 'QUIT') {
                    close($socket);
                    $select->remove($socket);
                    @observers = grep { $_ != $socket } @observers;
                }

            } elsif ($scanner_socket && $socket == $scanner_socket) {
                # Scanner (smak-scan) event - same protocol as FUSE but with paths directly
                my $line = <$socket>;
                unless (defined $line) {
                    # Scanner disconnected (normal at shutdown, only log in debug mode)
                    print STDERR "Scanner disconnected\n" if $ENV{SMAK_DEBUG};
                    $select->remove($scanner_socket);
                    $scanner_socket = undef;
                    next;
                }
                chomp $line;

                # Parse scanner event: OP:PID:path
                if ($line =~ /^(DELETE|CREATE|MODIFY):(\d+):(.+)$/) {
                    my ($op, $pid, $path) = ($1, $2, $3);
                    print STDERR "Scanner: $op $path\n" if $ENV{SMAK_DEBUG};

                    # Get basename for matching
                    my $basename = $path;
                    $basename =~ s{^.*/}{};

                    if ($op eq 'DELETE') {
                        # File was deleted - mark as stale
                        delete $completed_targets{$basename};
                        delete $completed_targets{$path};
                        delete $in_progress{$basename};
                        delete $in_progress{$path};
                        $stale_targets_cache{$basename} = time();
                    }
                    # CREATE and MODIFY are tracked but don't need special handling
                    # (the file exists now, needs_rebuild check will happen at build time)
                }

            } elsif ($fuse_socket && $socket == $fuse_socket) {
                # FUSE filesystem event
                my $line = <$socket>;
                unless (defined $line) {
                    # FUSE monitor disconnected
                    vprint "FUSE monitor disconnected\n";
                    $select->remove($fuse_socket);
                    $fuse_socket = undef;
                    next;
                }
                chomp $line;

                # Parse FUSE event: OP:PID:INODE or INO:INODE:PATH
                if ($line =~ /^(\w+):(\d+):(.+)$/) {
                    my ($op, $arg1, $arg2) = ($1, $2, $3);

                    if ($op eq 'INO') {
                        # Path resolution response: INO:inode:path
                        # Path from FUSE is relative to mount root, convert to full path
                        my ($inode, $fuse_path) = ($arg1, $arg2);

                        # Convert mount-relative path to full path
                        my $full_path = $fuse_path;
                        if ($fuse_mountpoint && $fuse_path =~ m{^/}) {
                            # Remove leading slash and prepend mountpoint
                            $fuse_path =~ s{^/}{};
                            $full_path = "$fuse_mountpoint/$fuse_path";
                        }

                        $inode_cache{$inode} = $full_path;
                        delete $pending_path_requests{$inode};

                        # Track modification with full path
                        $file_modifications{$full_path} ||= {workers => [], last_op => time()};
                        print STDERR "FUSE: $full_path (inode $inode, mount-relative: $fuse_path)\n" if $ENV{SMAK_DEBUG};

                        # Send watch notification if client is watching AND file is build-relevant
                        if ($watch_client && is_build_relevant($full_path)) {
                            print $watch_client "WATCH:$full_path\n";
                        }

                    } else {
                        # File operation: OP:pid:inode
                        my ($pid, $inode) = ($arg1, $arg2);

                        # Request path if we don't have it cached
                        if (!exists $inode_cache{$inode} && !exists $pending_path_requests{$inode}) {
                            print $fuse_socket "PATH:$inode\n";
                            $pending_path_requests{$inode} = 1;
                        }

                        # Track operation (path will be resolved asynchronously)
                        if (exists $inode_cache{$inode}) {
                            my $path = $inode_cache{$inode};
                            $file_modifications{$path} ||= {workers => [], last_op => time()};
                            push @{$file_modifications{$path}{workers}}, $pid
                                unless grep { $_ == $pid } @{$file_modifications{$path}{workers}};
                            $file_modifications{$path}{last_op} = time();

                            # Print debug message only if different from last one (suppress consecutive duplicates)
                            if ($ENV{SMAK_DEBUG}) {
                                my $debug_msg = "FUSE: $op $path by PID $pid";
                                if ($debug_msg ne $last_fuse_debug_msg) {
                                    print STDERR "$debug_msg\n";
                                    $last_fuse_debug_msg = $debug_msg;
                                }
                            }

                            # Send watch notification if client is watching AND file is build-relevant
                            if ($watch_client && is_build_relevant($path)) {
                                print $watch_client "WATCH:$path\n";
                            }

                            # For DELETE, RENAME, or WRITE operations, handle stale targets
                            if ($op eq 'DELETE' || $op eq 'RENAME' || $op eq 'WRITE') {
                                # Get basename for matching
                                my $basename = $path;
                                $basename =~ s{^.*/}{};  # Get just the filename

                                # Clear the file from completed targets if it was deleted or renamed
                                # RENAME happens when 'rm' command moves file to .prev backup
                                if ($op eq 'DELETE' || $op eq 'RENAME') {
                                    delete $completed_targets{$basename};
                                    delete $completed_targets{$path};
                                    delete $in_progress{$basename};
                                    delete $in_progress{$path};
                                    $stale_targets_cache{$basename} = time();
                                }

                                # Only auto-clear failed targets if fuse_auto_clear is enabled
                                # (disabled with 'unwatch', events still collected for manual rescan)
                                if ($fuse_auto_clear) {
                                    # Clear failed targets that now need rebuilding due to this file change
                                    for my $target (keys %failed_targets) {
                                        # Check if target needs rebuilding (considers all dependencies recursively)
                                        if (needs_rebuild($target)) {
                                            delete $failed_targets{$target};
                                            delete $in_progress{$target};
                                            print STDERR "FUSE: Cleared failed target '$target' (affected by $op on '$path')\n" if $ENV{SMAK_DEBUG};
                                        }
                                    }

                                    # Clear failed composite targets in in_progress
                                    for my $target (keys %in_progress) {
                                        if ($in_progress{$target} eq 'failed') {
                                            # Check if target needs rebuilding (considers all dependencies recursively)
                                            if (needs_rebuild($target)) {
                                                delete $in_progress{$target};
                                                delete $failed_targets{$target};
                                                print STDERR "FUSE: Cleared failed composite target '$target' (affected by $op on '$path')\n" if $ENV{SMAK_DEBUG};
                                            }
                                        }
                                    }

                                    # Clear completed targets that now need rebuilding due to this file change
                                    # This handles cases like: main.o deleted -> ivl needs rebuilding
                                    for my $target (keys %completed_targets) {
                                        # Check if target needs rebuilding (considers all dependencies recursively)
                                        if (needs_rebuild($target)) {
                                            delete $completed_targets{$target};
                                            delete $in_progress{$target};
                                            print STDERR "FUSE: Cleared completed target '$target' (affected by $op on '$path')\n" if $ENV{SMAK_DEBUG};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            } else {
                # Worker sent us something - drain all available messages
                # (Perl's buffered I/O may have multiple lines ready but select only sees kernel buffer)
                $socket->blocking(0);
                while (my $line = <$socket>) {
                    chomp $line;
                    print STDERR "DEBUG: Worker read line: '$line'\n" if $ENV{SMAK_DEBUG};

                if ($line eq 'READY') {
                    # Worker is ready for a job
                    $worker_status{$socket}{ready} = 1;
                    my $dispatched = dispatch_jobs(1);  # Try to dispatch one job
                    if ($dispatched) {
                        vprint "Worker received next job\n";
                    } else {
                        vprint "Worker ready (no jobs)\n";
                    }

                } elsif ($line =~ /^TASK_START (\d+)$/) {
                    my $task_id = $1;
                    # Mark task as actually running (not just dispatched)
                    if (exists $running_jobs{$task_id}) {
                        $running_jobs{$task_id}{started} = 1;
                    }
                    print STDERR "Task $task_id started\n" if $ENV{SMAK_DEBUG};

                } elsif ($line =~ /^OUTPUT (.*)$/) {
                    my $output = $1;
                    # Capture output for the task running on this worker
                    if (exists $worker_status{$socket}{task_id}) {
                        my $task_id = $worker_status{$socket}{task_id};
                        if (exists $running_jobs{$task_id}) {
                            push @{$running_jobs{$task_id}{output}}, $output;
                        }
                    }
                    # Forward to attached master client, or print locally if standalone
                    if ($master_socket) {
                        # Master client connected - forward output and let it handle display
                        print $master_socket "OUTPUT $output\n";
                    } else {
                        # Standalone job master - print to stdout directly
                        # Skip stomp_prompt in dry-run mode (no spinner to clear)
                        if ($dry_run_mode) {
                            print "$output\n";
                        } else {
                            print $stomp_prompt . "$output\n";
                        }
                    }

                } elsif ($line =~ /^ERROR (.*)$/) {
                    my $error = $1;
                    my $task_id = $worker_status{$socket}{task_id} || 'NONE';
                    # Capture error for the task running on this worker
                    if (exists $worker_status{$socket}{task_id}) {
                        my $tid = $worker_status{$socket}{task_id};
                        if (exists $running_jobs{$tid}) {
                            push @{$running_jobs{$tid}{output}}, "ERROR: $error";
                        }
                    }
                    # Always print to stderr (job master's stderr is inherited from parent)
                    print STDERR "ERROR: $error\n";
                    print STDERR "  [DEBUG: from task_id=$task_id, socket=$socket]\n" if $ENV{SMAK_DEBUG};
                    # Also forward to attached clients if any
                    print $master_socket "ERROR $error\n" if $master_socket;

                } elsif ($line =~ /^WARN (.*)$/) {
                    my $warning = $1;
                    # Always print to stderr (job master's stderr is inherited from parent)
                    print STDERR "WARN: $warning\n";
                    # Also forward to attached clients if any
                    print $master_socket "WARN $warning\n" if $master_socket;

                } elsif ($line =~ /^TASK_RETURN (\d+)(.*)$/) {
                    my $task_id = $1;
                    my $reason = $2 || '';
                    $reason =~ s/^\s+//;  # Trim leading whitespace

		    if ($reason =~ /not\s+ready/i) {
			send_env($socket);
		    }
		    
                    # Worker is returning a task (doesn't want to execute it)
                    if (exists $running_jobs{$task_id}) {
                        my $job = $running_jobs{$task_id};
                        vprint "Worker returning task $task_id ($job->{target}): $reason\n";

                        # Re-queue the job
                        unshift @job_queue, $job;  # Add to front of queue

                        # Remove from running jobs
                        delete $running_jobs{$task_id};

                        # Mark worker as ready
                        $worker_status{$socket}{ready} = 7;

                        # Try to dispatch to another worker
                        dispatch_jobs();
                    }

                } elsif ($line =~ /^TASK_DECOMPOSE (\d+)$/) {
                    my $task_id = $1;

                    # Worker wants to decompose this task into subtasks
                    if (exists $running_jobs{$task_id}) {
                        my $job = $running_jobs{$task_id};
                        my $target = $job->{target};

                        vprint "Worker decomposing task $task_id ($target)\n";

                        # Read subtargets from worker
                        my @subtargets;
                        while (my $sub_line = <$socket>) {
                            chomp $sub_line;
                            last if $sub_line eq 'DECOMPOSE_END';
                            push @subtargets, $sub_line;
                        }

                        if (@subtargets) {
                            print STDERR "  Decomposed into " . scalar(@subtargets) . " subtargets\n";

                            # Queue each subtarget
                            for my $subtarget (@subtargets) {
                                # Get build command for subtarget
                                my $sub_key = "$makefile\t$subtarget";
                                my $sub_cmd;
                                if (exists $pseudo_rule{$sub_key}) {
                                    $sub_cmd = $pseudo_rule{$sub_key};
                                } elsif (exists $fixed_rule{$sub_key}) {
                                    $sub_cmd = $fixed_rule{$sub_key};
                                } elsif (exists $pattern_rule{$sub_key}) {
                                    $sub_cmd = $pattern_rule{$sub_key};
                                } else {
                                    $sub_cmd = "cd $job->{dir} && make $subtarget";
                                }

                                # Check if any command line has @ prefix
                                my $sub_silent = 0;
                                for my $line (split /\n/, $sub_cmd) {
                                    next unless $line =~ /\S/;
                                    my $trimmed = $line;
                                    $trimmed =~ s/^\s+//;
                                    if ($trimmed =~ /^@/) {
                                        $sub_silent = 1;
                                        last;
                                    }
                                }

                                # Subtasks inherit parent's layer
                                my $sub_layer = $job->{layer} // 0;
                                my $sub_job = {
                                    target => $subtarget,
                                    dir => $job->{dir},
                                    exec_dir => $job->{exec_dir} || $job->{dir},
                                    command => $sub_cmd,
                                    silent => $sub_silent,
                                    layer => $sub_layer,
                                };
                                add_job_to_layer($sub_job, $sub_layer);
                                print STDERR "    Queued: $subtarget (layer $sub_layer)\n";
                            }

                            # Remove original task from running jobs
                            delete $running_jobs{$task_id};

                            # Mark worker as ready
                            $worker_status{$socket}{ready} = 7;

                            # Dispatch the new subtasks
                            dispatch_jobs();
                        } else {
                            print STDERR "  Warning: No subtargets provided, task will continue\n";
                        }
                    }

                } elsif ($line =~ /^TASK_END (\d+) (\d+)$/) {
                    my ($task_id, $exit_code) = ($1, $2);
                    my $job = $running_jobs{$task_id};

                    # Don't mark ready here - wait for READY message
                    delete $running_jobs{$task_id};

                    # If job was already removed (e.g., by cancel), skip processing
                    unless ($job) {
                        print STDERR "Task $task_id ended but already removed (cancelled?)\n" if $ENV{SMAK_DEBUG};
                        next;
                    }

                    # Track successfully completed targets to avoid rebuilding
                    if ($exit_code == 0 && $job->{target}) {
                        # If this is a clean-like target, detect rm commands and mark removed files as stale
                        if ($job->{command} && $job->{command} =~ /\brm\b/) {
                            # Extract rm commands and expand wildcards
                            my $cmd = $job->{command};
                            my $dir = $job->{dir} || '.';

                            # Find all rm commands (handle both "rm file" and "rm -rf file")
                            while ($cmd =~ /\brm\s+(?:-[a-z]+\s+)*([^\s;&|]+(?:\s+[^\s;&|]+)*)/g) {
                                my $args = $1;
                                # Split arguments and expand each one
                                for my $arg (split /\s+/, $args) {
                                    next if $arg =~ /^-/;  # Skip flags

                                    # Expand wildcards using glob
                                    my @expanded;
                                    if ($arg =~ /[*?\[]/) {
                                        # Has wildcards - expand them
                                        my $full_pattern = $arg =~ m{^/} ? $arg : "$dir/$arg";
                                        @expanded = glob($full_pattern);
                                    } else {
                                        # No wildcards - use as-is
                                        @expanded = ($arg =~ m{^/} ? $arg : "$dir/$arg");
                                    }

                                    # Mark each expanded file as removed
                                    for my $file (@expanded) {
                                        # Extract just the filename for target matching
                                        my $target_name = $file;
                                        $target_name =~ s{^\Q$dir\E/}{};  # Remove dir prefix

                                        if (exists $completed_targets{$target_name}) {
                                            delete $completed_targets{$target_name};
                                            delete $in_progress{$target_name};  # Also clear from in_progress
                                            $stale_targets_cache{$target_name} = time();
                                            print STDERR "Detected rm of '$target_name' - marked as stale\n" if $ENV{SMAK_DEBUG};
                                        }
                                    }
                                }
                            }
                        }

                        # Check if this looks like a phony target (doesn't produce a file)
                        # Phony targets typically have no extension or are common make targets
                        my $target = $job->{target};
                        my $looks_like_file = $target =~ /\.[a-zA-Z0-9]+$/ ||  # has extension
                                              $target =~ /\// ||                # has path separator
                                              $target =~ /^lib.*\.a$/ ||        # library file
                                              $target =~ /^.*\.so(\.\d+)*$/;    # shared library

                        # Common phony targets that don't produce files
                        my $is_common_phony = $target =~ /^(all|clean|install|test|check|depend|dist|
                                                            distclean|maintainer-clean|mostlyclean|
                                                            cmake_check_build_system|help|list|
                                                            package|preinstall|rebuild_cache|edit_cache)$/x;

                        # Only verify file existence for targets that look like real files
                        # Skip verification in dry-run mode since files aren't actually created
                        my $should_verify = $looks_like_file && !$is_common_phony && !$dry_run_mode;

                        if (!$should_verify || verify_target_exists($job->{target}, $job->{dir})) {
                            $completed_targets{$job->{target}} = 1;
                            $in_progress{$job->{target}} = "done";
                            print STDERR "Task $task_id completed successfully: $job->{target}\n" if $ENV{SMAK_DEBUG};

                            # Execute post-build hook if defined for this target
                            if (exists $post_build{$job->{target}}) {
                                my $post_cmd = $post_build{$job->{target}};
                                warn "DEBUG: Running post-build for '$job->{target}': $post_cmd\n" if $ENV{SMAK_DEBUG};
                                my $post_exit = execute_builtin($post_cmd);
                                if (!defined $post_exit) {
                                    # Not a builtin, run as shell command
                                    $post_exit = system($post_cmd);
                                }
                                if ($post_exit != 0) {
                                    warn "Post-build hook failed for $job->{target}: $post_cmd\n";
                                }
                            }

                            # If this job has siblings (multi-output pattern rule), mark them as complete too
                            # Siblings can come from $job->{siblings} OR from compound target name (a&b format)
                            my @siblings_to_mark;
                            if ($job->{siblings} && @{$job->{siblings}} > 1) {
                                @siblings_to_mark = @{$job->{siblings}};
                            } elsif ($job->{target} =~ /&/) {
                                # Compound target name encodes siblings: parse.cc&parse.h
                                @siblings_to_mark = split(/&/, $job->{target});
                            }
                            if (@siblings_to_mark > 1) {
                                for my $sibling (@siblings_to_mark) {
                                    next if $sibling eq $job->{target};  # Don't double-mark self
                                    $completed_targets{$sibling} = 1;
                                    $in_progress{$sibling} = "done";
                                    print STDERR "DEBUG: Marking sibling '$sibling' as complete (created with '$job->{target}')\n" if $ENV{SMAK_DEBUG};
                                }
                            }
                        } else {
                            # File doesn't exist even after retries - treat as failure
                            $in_progress{$job->{target}} = "failed";
                            print STDERR "Task $task_id FAILED: $job->{target} - output file not found\n";
                            $exit_code = 1;  # Mark as failed for composite target handling below
                        }
                    }

                    # Handle successful completion
                    if ($exit_code == 0 && $job->{target} && $completed_targets{$job->{target}}) {
                        # ASSERTION: Verify successful job produced a valid target
                        # Only run expensive checks when debugging enabled (to avoid performance impact)
                        if (ASSERTIONS_ENABLED && $ENV{SMAK_DEBUG}) {
                            my $target = $job->{target};

                            # Check if this is a phony target
                            my $is_phony_target = 0;

                            # 1. Check .PHONY declarations in pseudo_deps
                            my $phony_key = "$makefile\t.PHONY";
                            if (exists $pseudo_deps{$phony_key}) {
                                my @phony_targets = @{$pseudo_deps{$phony_key}};
                                $is_phony_target = 1 if grep { $_ eq $target } @phony_targets;
                            }

                            # 2. Check for common phony target names
                            if (!$is_phony_target && $target =~ /^(clean|distclean|mostlyclean|maintainer-clean|realclean|clobber|install|uninstall|check|test|tests|all|help|info|dvi|pdf|ps|dist|tags|ctags|etags|TAGS)$/) {
                                $is_phony_target = 1;
                            }

                            # 3. Check for automake-style phony targets (clean-*, install-*, mostlyclean-*, etc.)
                            if (!$is_phony_target && $target =~ /^(clean|install|uninstall|mostlyclean|distclean|maintainer-clean)-/) {
                                $is_phony_target = 1;
                            }

                            # 4. Check pseudo_rule as fallback
                            if (!$is_phony_target) {
                                for my $key (keys %pseudo_rule) {
                                    if ($key =~ /\t\Q$target\E$/) {
                                        $is_phony_target = 1;
                                        last;
                                    }
                                }
                            }

                            if (!$is_phony_target && !$dry_run_mode) {
                                # Target file must exist (skip in dry-run since files aren't created)
                                # Use verify_target_exists which handles compound targets (x&y)
                                if (!verify_target_exists($target, $job->{dir})) {
                                    assert_or_die(0, "Target '$target' marked as successfully built but file(s) do not exist");
                                }

                                # Skip mtime checking for compound targets - too complex
                                next if $target =~ /&/;

                                # Get all dependencies for this target (excluding order-only deps)
                                # Since we don't have makefile in job hash, search all keys that end with this target
                                my @deps;

                                # Check fixed deps - search all keys
                                for my $key (keys %fixed_deps) {
                                    if ($key =~ /\t\Q$target\E$/) {
                                        my $deps_ref = $fixed_deps{$key};
                                        if (ref($deps_ref) eq 'ARRAY') {
                                            push @deps, @$deps_ref;
                                        } else {
                                            push @deps, split /\s+/, $deps_ref;
                                        }
                                    }
                                }

                                # Check pseudo deps - search all keys
                                for my $key (keys %pseudo_deps) {
                                    if ($key =~ /\t\Q$target\E$/) {
                                        my $deps_ref = $pseudo_deps{$key};
                                        if (ref($deps_ref) eq 'ARRAY') {
                                            push @deps, @$deps_ref;
                                        } else {
                                            push @deps, split /\s+/, $deps_ref;
                                        }
                                    }
                                }

                                # Verify target is newer than all dependencies
                                my $target_path = $target =~ m{^/} ? $target : "$job->{dir}/$target";
                                my $target_mtime = (stat($target_path))[9];
                                for my $dep (@deps) {
                                    next if $dep eq '';  # Skip empty deps
                                    my $dep_path = $dep =~ m{^/} ? $dep : "$job->{dir}/$dep";
                                    if (-e $dep_path) {
                                        my $dep_mtime = (stat($dep_path))[9];
                                        if ($target_mtime < $dep_mtime) {
                                            assert_or_die(0,
                                                "Target '$target' (mtime=$target_mtime) is older than dependency '$dep' (mtime=$dep_mtime) after successful build"
                                            );
                                        }
                                    }
                                }
                            }
                        }

                        # Clear from stale cache after successful build
                        if (exists $stale_targets_cache{$job->{target}}) {
                            delete $stale_targets_cache{$job->{target}};
                            warn "DEBUG[" . __LINE__ . "]: Cleared '$job->{target}' from stale cache after successful build\n" if $ENV{SMAK_DEBUG};
                        }

                        # Check if any pending composite targets can now complete
                        for my $comp_target (keys %pending_composite) {
                            my $comp = $pending_composite{$comp_target};
                            # Remove this completed target from pending deps
                            $comp->{deps} = [grep { $_ ne $job->{target} } @{$comp->{deps}}];

                            # If all dependencies done, complete the composite target
                            if (@{$comp->{deps}} == 0) {
                                vprint "All dependencies complete for composite target '$comp_target'\n";
                                $completed_targets{$comp_target} = 1;
                                $in_progress{$comp_target} = "done";
                                if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                                    print {$comp->{master_socket}} "JOB_COMPLETE $comp_target 0\n";
                                }
                                delete $pending_composite{$comp_target};
                            }
                        }
                    } else {
                        # Check if we should auto-retry this target
                        my $should_retry = 0;
                        my $retry_reason = "";

                        my $retry_count = $retry_counts{$job->{target}} || 0;
                        if ($job->{target} && $retry_count < $max_retries) {  # Check against max_retries
                            # Analyze captured output for retryable errors
                            my @output = $job->{output} ? @{$job->{output}} : ();

                            for my $line (@output) {
                                # Strip "ERROR: " prefix if present (we add this when capturing)
                                my $clean_line = $line;
                                $clean_line =~ s/^ERROR:\s*//;

                                # Strip ANSI color codes and formatting (bold, underline, etc.)
                                # Remove all ANSI escape sequences: \x1b[...m or \033[...m
                                $clean_line =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;  # \x1b format
                                $clean_line =~ s/\033\[[0-9;]*[a-zA-Z]//g;  # \033 format (octal)

                                # Check for "No such file or directory" errors
                                if ($clean_line =~ /(fatal error|error):\s+(.+?):\s+No such file or directory/i) {
                                    my $missing_file = $2;
                                    $missing_file =~ s/^\s+|\s+$//g;  # Trim whitespace

                                    print STDERR "Auto-retry: detected missing file '$missing_file' for target '$job->{target}'\n" if $ENV{SMAK_DEBUG};

                                    # Check if file exists now (race condition resolved)
                                    my $file_path = $missing_file =~ m{^/} ? $missing_file : "$job->{dir}/$missing_file";
                                    if (-f $file_path) {
                                        $should_retry = 1;
                                        $retry_reason = "file '$missing_file' exists now (race condition)";
                                        print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                        last;
                                    }

                                    # Check if the missing file matches auto-retry patterns
                                    if (!$should_retry && @auto_retry_patterns) {
                                        for my $pattern (@auto_retry_patterns) {
                                            # Convert glob pattern to regex
                                            my $regex = $pattern;
                                            $regex =~ s/\./\\./g;  # Escape dots
                                            $regex =~ s/\*/[^\/]*/g;  # * matches non-slash chars
                                            $regex =~ s/\?/./g;     # ? matches single char
                                            if ($missing_file =~ /^$regex$/ || $missing_file =~ /$regex$/) {
                                                $should_retry = 1;
                                                $retry_reason = "missing file '$missing_file' matches pattern '$pattern'";
                                                print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                                last;
                                            }
                                        }
                                    }

                                    last if $should_retry;  # Found a retryable error
                                }

                                # Check for linker "cannot find" errors (e.g., "ld: cannot find parse.o")
                                if (!$should_retry && $clean_line =~ /(?:ld|collect2|link).*:\s*cannot find\s+(.+?)(?:\s*:|$)/i) {
                                    my $missing_file = $1;
                                    $missing_file =~ s/^\s+|\s+$//g;  # Trim whitespace
                                    $missing_file =~ s/^-l//;  # Remove -l prefix if it's a library

                                    print STDERR "Auto-retry: detected linker missing file '$missing_file' for target '$job->{target}'\n" if $ENV{SMAK_DEBUG};

                                    # Try to unblock the missing file if it's stuck in queue
                                    # Clear it from failed state and in_progress so it can be retried
                                    my $was_blocked = 0;
                                    if (exists $failed_targets{$missing_file}) {
                                        print STDERR "Auto-retry: clearing failed state for '$missing_file' to allow rebuild\n" if $ENV{SMAK_DEBUG};
                                        delete $failed_targets{$missing_file};
                                        $was_blocked = 1;
                                    }
                                    if (exists $in_progress{$missing_file}) {
                                        print STDERR "Auto-retry: clearing in_progress state for '$missing_file' (was: $in_progress{$missing_file})\n" if $ENV{SMAK_DEBUG};
                                        delete $in_progress{$missing_file};
                                        $was_blocked = 1;
                                    }

                                    # Also check if the source file (.cc for .o) is stuck
                                    if ($missing_file =~ /^(.+)\.o$/) {
                                        my $base = $1;
                                        for my $ext ('.cc', '.cpp', '.c', '.C') {
                                            my $source = "$base$ext";
                                            if (exists $in_progress{$source}) {
                                                print STDERR "Auto-retry: clearing in_progress state for source '$source' (was: $in_progress{$source})\n" if $ENV{SMAK_DEBUG};
                                                delete $in_progress{$source};
                                                $was_blocked = 1;
                                            }
                                            if (exists $failed_targets{$source}) {
                                                print STDERR "Auto-retry: clearing failed state for source '$source'\n" if $ENV{SMAK_DEBUG};
                                                delete $failed_targets{$source};
                                                $was_blocked = 1;
                                            }
                                        }
                                    }

                                    # Don't dispatch immediately - this can cause race conditions
                                    # Instead, mark that we need to build this dependency after all jobs complete
                                    if ($was_blocked) {
                                        print STDERR "Auto-retry: unblocked '$missing_file', will build after current jobs complete\n" if $ENV{SMAK_DEBUG};
                                    }

                                    # Retry for linker errors - likely a parallel build race condition
                                    # The missing file might be queued or building in another worker
                                    $should_retry = 1;
                                    $retry_reason = "linker missing file '$missing_file' (likely parallel build race)";
                                    print STDERR "Auto-retry: will retry because $retry_reason\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }

                            # If no intelligent retry detected, fall back to target pattern matching
                            if (!$should_retry && @auto_retry_patterns) {
                                for my $pattern (@auto_retry_patterns) {
                                    # Convert glob pattern to regex
                                    my $regex = $pattern;
                                    $regex =~ s/\./\\./g;  # Escape dots
                                    $regex =~ s/\*/[^\/]*/g;  # * matches non-slash chars
                                    $regex =~ s/\?/./g;     # ? matches single char
                                    if ($job->{target} =~ /^$regex$/ || $job->{target} =~ /$regex$/) {
                                        $should_retry = 1;
                                        $retry_reason = "matches pattern '$pattern'";
                                        last;
                                    }
                                }
                            }
                        }

                        if ($should_retry) {
                            # Retry this target
                            $retry_counts{$job->{target}}++;
                            print STDERR "Task $task_id FAILED: $job->{target} (exit code $exit_code) - AUTO-RETRYING ($retry_reason, attempt " . $retry_counts{$job->{target}} . ")\n";

                            # Clear from failed targets so it can be rebuilt
                            delete $failed_targets{$job->{target}};
                            delete $in_progress{$job->{target}};

                            # Check if target is already queued to prevent duplicates
                            my $already_queued = 0;
                            for my $queued_job (@job_queue) {
                                if ($queued_job->{target} eq $job->{target}) {
                                    $already_queued = 1;
                                    print STDERR "Auto-retry: target '$job->{target}' already in queue, skipping duplicate\n" if $ENV{SMAK_DEBUG};
                                    last;
                                }
                            }

                            # Re-queue the target only if not already queued
                            if (!$already_queued) {
                                # Use original layer for retry
                                my $retry_layer = $job->{layer} // 0;
                                my $retry_job = {
                                    target => $job->{target},
                                    dir => $job->{dir},
                                    exec_dir => $job->{exec_dir} || $job->{dir},
                                    command => $job->{command},
                                    silent => $job->{silent} || 0,
                                    layer => $retry_layer,
                                };
                                add_job_to_layer($retry_job, $retry_layer);
                                print STDERR "Auto-retry: re-queued '$job->{target}' to layer $retry_layer for retry\n" if $ENV{SMAK_DEBUG};
                            }

                            # Don't dispatch immediately - let dependencies build first
                            # The normal job dispatch cycle will handle it when dependencies are ready
                        } else {
                            # Mark as failed (no retry or retry exhausted)
                            if ($job->{target}) {
                                $in_progress{$job->{target}} = "failed";
                                $failed_targets{$job->{target}} = $exit_code;
                            }
                            print STDERR "Task $task_id FAILED: $job->{target} (exit code $exit_code)\n";

                            # Check if this failed task is a dependency of any composite target
                            for my $comp_target (keys %pending_composite) {
                                my $comp = $pending_composite{$comp_target};
                                # Check if this failed target is in the composite's dependencies
                                if (grep { $_ eq $job->{target} } @{$comp->{deps}}) {
                                    print STDERR "Composite target '$comp_target' FAILED because dependency '$job->{target}' failed (exit code $exit_code)\n";
                                    $in_progress{$comp_target} = "failed";
                                    if ($comp->{master_socket} && defined fileno($comp->{master_socket})) {
                                        print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                                    }
                                    delete $pending_composite{$comp_target};
                                }
                            }
                        }
                    }

                    # Report to master
                    print $master_socket "JOB_COMPLETE $job->{target} $exit_code\n" if $master_socket;

                    # Clean up dispatch tracking
                    delete $currently_dispatched{$job->{target}} if exists $currently_dispatched{$job->{target}};
                }
                } # end while loop for worker messages
                $socket->blocking(1);
            }
        }
    }
}

sub wait_for_jobs
{
    my $sts = 0;

    # Use pstree to find child processes, but handle failures gracefully
    if (!open(TREE, "pstree -p $$ 2>/dev/null |")) {
        # If pstree fails, just return - no children to wait for
        return 0;
    }

    while (defined(my $line = <TREE>)) {
        my $p=0;
        my @pid;
        while ($line =~ s/\((\d+)\)//) {
            if ($$ != $1) { $pid[$p++] = $1; }
        }
        for $p (@pid) {
            # Skip if this PID doesn't exist or isn't our child
            next unless kill(0, $p);  # Check if process exists

            my $msg = "process: $p";
            if (open(CMD,"cat /proc/$p/cmdline 2>/dev/null | tr '\\0' ' ' |")) {
                my $cmd = <CMD>;
                close(CMD);
                if (defined $cmd) {
                    $msg = " command: $cmd [$p]";
                }
            }
            warn "Waiting for $msg\n" if $ENV{SMAK_DEBUG};

            # Use non-blocking wait first to check if child exists
            my $s = waitpid($p, 1);  # WNOHANG = 1
            if ($s == 0) {
                # Process still running, do blocking wait
                $s = waitpid($p, 0);
            }
            if ($s > 0) {
                $sts = $?;
            }
        }
    }
    close(TREE);

    return $sts;
}

# Signal handlers - Ctrl-C just sets a flag
sub cancel_handler {
    warn "DEBUG: cancel_handler called, interactive=$interactive\n" if $ENV{SMAK_DEBUG};
    $SmakCli::cancel_requested = 2; # 1 if read Ctrl-C
    if (! $interactive) {
	cmd_kill();
	exit;
    }
};

$SIG{INT}  = sub { cancel_handler };
$SIG{USR1} = sub { interactive_debug };
$SIG{USR2} = sub { print STDERR Carp::confess( @_ ) };

1;  # Return true to indicate successful module load
