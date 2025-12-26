package Smak;

use strict;
use warnings;
use Exporter qw(import);
use POSIX ":sys_wait_h";
use Term::ReadLine;
use SmakCli qw(:all);

use Carp 'verbose'; # for debug trace
	            # print STDERR Carp::confess( @_ ) if $ENV{SMAK_DEBUG};

our $VERSION = '1.0';

# Helper function to print verbose messages (smak-specific, not GNU make compatible)
# If SMAK_VERBOSE='w', shows a spinning wheel instead of printing
my @wheel_chars = qw(/ - \\);
my $wheel_pos = 0;

sub vprint {
    my $mode;

    return if (! defined ($mode = $ENV{SMAK_VERBOSE}));
    
    if ($mode eq 'w') {
        # Spinning wheel mode - update in place
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
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

# Separate hashes for different rule types
our %fixed_rule;
our %fixed_deps;
our %pattern_rule;
our %pattern_deps;
our %pseudo_rule;
our %pseudo_deps;

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

    # Check for source control file extensions (,v)
    for my $ext (keys %source_control_extensions) {
        return 1 if $dep =~ /\Q$ext\E/;
    }

    # Check for source control directory recursion
    return 1 if has_source_control_recursion($dep);

    # Check for inactive patterns
    return 1 if is_inactive_pattern($dep);

    return 0;
}

our @job_queue;

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
our %parsed_file_mtimes;  # Track mtimes of all parsed makefiles for cache validation
our $CACHE_VERSION = 9;  # Increment to invalidate old caches

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

# Job server state
our $jobs = 1;  # Number of parallel jobs
our $ssh_host = '';  # SSH host for remote workers
our $remote_cd = '';  # Remote directory for SSH workers
our $job_server_socket;  # Socket to job-master
our $job_server_pid;  # PID of job-master process
our $job_server_master_port;  # Master port for reconnection

# Output control
our $stomp_prompt = "\r";

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

sub start_job_server {
    my ($wait) = @_;
    $wait //= 0;  # Default to not waiting for workers

    use IO::Socket::INET;
    use IO::Select;
    use FindBin qw($RealBin);

    return if $jobs < 1;  # Need at least 1 worker for job server (enables FUSE monitoring)

    $SmakCli::cli_owner = $$; # parent not server or workers

    $job_server_pid = fork();
    die "Cannot fork job-master: $!\n" unless defined $job_server_pid;

    if ($job_server_pid == 0) {
        # Child - run job-master with full access to parsed Makefile data
        # This allows job-master to understand dependencies and parallelize intelligently
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

    if (my $prog = $in_progress{$target}) {
	if ("queued" eq $prog) {
	    dispatch_jobs(1);
	    $prog = $in_progress{$target};
	    return 1 if ("queued" ne $prog);
	}
	return 2;
    }

    $in_progress{$target} = "queued";

    warn "Submitting job: $target\n" if $ENV{SMAK_DEBUG};

    # Send job to job-master via socket protocol
    print $job_server_socket "SUBMIT_JOB\n";
    print $job_server_socket "$target\n";
    print $job_server_socket "$dir\n";
    print $job_server_socket "$command\n";

    return 0;
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

    # Execute command
    warn "DEBUG[" . __LINE__ . "]: About to execute command\n" if $ENV{SMAK_DEBUG};

    # Execute command as a pipe to stream output in real-time
    # Redirect stderr to stdout and append exit status marker
    my $pid = open(my $cmd_fh, '-|', "$command 2>&1 ; echo EXIT_STATUS=\$?");
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
        print STDOUT $line;
        print $log_fh $line if $report_mode && $log_fh;
    }

    close($cmd_fh);

    warn "DEBUG[" . __LINE__ . "]: Command executed, exit_code=$exit_code\n" if $ENV{SMAK_DEBUG};

    if ($exit_code != 0) {
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

    # Prevent infinite loops from unsupported functions
    my $max_iterations = 100;
    my $iterations = 0;

    # Expand $(function args) and $(VAR) references
    while ($text =~ /\$\(/) {
        if (++$iterations > $max_iterations) {
            warn "Warning: expand_vars hit iteration limit, stopping expansion\n";
            warn "         Remaining unexpanded: " . substr($text, 0, 200) . "...\n" if length($text) > 200;
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
            if ($char eq '(' && substr($text, $pos-1, 1) eq '$') {
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

            # Split arguments by comma, but not within nested $()
            my @args;
            my $depth = 0;
            my $current = '';
            for my $char (split //, $args_str) {
                if ($char eq '(' && substr($current, -1) eq '$') {
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
            if ($char eq '(' && substr($text, $scan_pos-1, 1) eq '$') {
                $depth++;
            } elsif ($char eq ')') {
                $depth--;
            }
            $scan_pos++;
        }

        if ($depth == 0) {
            # Found balanced parentheses, extract content
            my $content = substr($text, $start + 2, $scan_pos - $start - 3);
            $result .= '$MV{' . $content . '}';
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

    # Try to load from cache if available and valid
    if (load_state_cache($makefile_path)) {
        warn "DEBUG: Using cached state, skipping parse\n" if $ENV{SMAK_DEBUG};

        # Ensure inactive patterns are detected even if cache didn't have them
        # (handles old caches created before this feature)
        if (!%inactive_patterns) {
            warn "DEBUG: Cache missing inactive patterns, detecting now\n" if $ENV{SMAK_DEBUG};
            detect_inactive_patterns();
        }

        # Always initialize ignore_dirs from environment (not saved in cache)
        # This ensures SMAK_IGNORE_DIRS is respected even when using cached state
        init_ignore_dirs();

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

    # Track file mtime for cache validation
    use Cwd 'abs_path';
    my $abs_makefile = abs_path($makefile) || $makefile;
    $parsed_file_mtimes{$abs_makefile} = (stat($makefile))[9];

    my @current_targets;  # Array to handle multiple targets (e.g., "target1 target2:")
    my $current_rule = '';
    my $current_type;  # 'fixed', 'pattern', or 'pseudo'

    my $save_current_rule = sub {
        return unless @current_targets;

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
                $fixed_rule{$key} = $current_rule;
            } elsif ($type eq 'pattern') {
                $pattern_rule{$key} = $current_rule;
            } elsif ($type eq 'pseudo') {
                $pseudo_rule{$key} = $current_rule;
            }
        }

        @current_targets = ();
        $current_rule = '';
        $current_type = undef;
    };

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

        # Skip comments and empty lines (but not inside rules)
        if (!@current_targets && ($line =~ /^\s*#/ || $line =~ /^\s*$/)) {
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
        if ($line =~ /^-?include\s+(.+)$/) {
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
            } else {
                # := ? or = operators all do simple assignment
                $MV{$var} = $value;
            }
            next;
        }

        # Rule definition (target: dependencies)
        # Must not start with whitespace (tabs are recipe lines, spaces might be command output)
        if ($line =~ /^(\S[^:]*?):\s*(.*)$/) {
            $save_current_rule->();

            my $targets_str = $1;
            my $deps_str = $2;

            # Trim whitespace
            $targets_str =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;

            # Transform $(VAR) and $X to $MV{VAR} and $MV{X} in dependencies
            $deps_str = transform_make_vars($deps_str);

            my @deps = split /\s+/, $deps_str;
            @deps = grep { $_ ne '' } @deps;

            # Handle multiple targets (e.g., "target1 target2: deps")
            # Make creates the same rule for each target
            my @targets = split /\s+/, $targets_str;
            @targets = grep { $_ ne '' } @targets;

            # Store all targets for rule accumulation
            @current_targets = @targets;
            $current_type = classify_target($current_targets[0]) if @current_targets;
            $current_rule = '';

            # For pattern rules, check if ALL dependencies would be filtered
            # If so, discard the entire rule by clearing @current_targets
            if ($current_type eq 'pattern' && @deps) {
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
                } elsif ($type eq 'pattern') {
                    # Append dependencies if target already exists (like gmake)
                    if (exists $pattern_deps{$key}) {
                        push @{$pattern_deps{$key}}, @deps;
                    } else {
                        $pattern_deps{$key} = \@deps;
                    }
                } elsif ($type eq 'pseudo') {
                    # Append dependencies if target already exists (like gmake)
                    if (exists $pseudo_deps{$key}) {
                        push @{$pseudo_deps{$key}}, @deps;
                    } else {
                        $pseudo_deps{$key} = \@deps;
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
        }

        # Rule command (starts with tab)
        if ($line =~ /^\t(.*)$/ && @current_targets) {
            my $cmd = $1;
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

    close($fh);
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

    my $save_current_rule = sub {
        return unless @current_targets;

        # Save rule for all targets in the current rule
        for my $target (@current_targets) {
            my $key = "$saved_makefile\t$target";  # Use original makefile for keys
            my $type = classify_target($target);

            if ($type eq 'fixed') {
                $fixed_rule{$key} = $current_rule;
            } elsif ($type eq 'pattern') {
                $pattern_rule{$key} = $current_rule;
            } elsif ($type eq 'pseudo') {
                $pseudo_rule{$key} = $current_rule;
            }
        }

        @current_targets = ();
        $current_rule = '';
        $current_type = undef;
    };

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

        # Skip comments and empty lines
        if (!@current_targets && ($line =~ /^\s*#/ || $line =~ /^\s*$/)) {
            next;
        }

        # Handle include directives (nested includes)
        if ($line =~ /^-?include\s+(.+)$/) {
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
            } else {
                # := ? or = operators all do simple assignment
                $MV{$var} = $value;
            }
            next;
        }

        # Rule definition (included files might have rules too)
        # Must not start with whitespace (tabs are recipe lines)
        if ($line =~ /^(\S[^:]*?):\s*(.*)$/) {
            $save_current_rule->();

            my $targets_str = $1;
            my $deps_str = $2;

            $targets_str =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;
            $deps_str = transform_make_vars($deps_str);

            my @deps = split /\s+/, $deps_str;
            @deps = grep { $_ ne '' } @deps;

            # Handle multiple targets
            my @targets = split /\s+/, $targets_str;
            @targets = grep { $_ ne '' } @targets;

            @current_targets = @targets;
            $current_type = classify_target($current_targets[0]) if @current_targets;
            $current_rule = '';

            # Store dependencies for all targets
            for my $target (@targets) {
                my $key = "$saved_makefile\t$target";
                my $type = classify_target($target);

                if ($type eq 'fixed') {
                    if (exists $fixed_deps{$key}) {
                        push @{$fixed_deps{$key}}, @deps;
                    } else {
                        $fixed_deps{$key} = \@deps;
                    }
                } elsif ($type eq 'pattern') {
                    if (exists $pattern_deps{$key}) {
                        push @{$pattern_deps{$key}}, @deps;
                    } else {
                        $pattern_deps{$key} = \@deps;
                    }
                } elsif ($type eq 'pseudo') {
                    if (exists $pseudo_deps{$key}) {
                        push @{$pseudo_deps{$key}}, @deps;
                    } else {
                        $pseudo_deps{$key} = \@deps;
                    }
                }
            }

            next;
        }

        # Rule command
        if ($line =~ /^\t(.*)$/ && @current_targets) {
            my $cmd = $1;
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

    # Initialize optimizations once (first time any makefile is parsed)
    warn "DEBUG: Checking if init needed - inactive_patterns has " . scalar(keys %inactive_patterns) . " entries\n" if $ENV{SMAK_DEBUG};
    if (!%inactive_patterns) {
        warn "DEBUG: Initializing ignore dirs and inactive patterns\n" if $ENV{SMAK_DEBUG};
        init_ignore_dirs();
        detect_inactive_patterns();
    } else {
        warn "DEBUG: Skipping pattern detection - inactive_patterns already populated\n" if $ENV{SMAK_DEBUG};
        # Still need to init ignore_dirs even if patterns are cached
        init_ignore_dirs();
    }

    # Save state to cache for faster startup next time
    save_state_cache($makefile);
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

    # Check if caching is enabled (automatic in debug mode, or via SMAK_CACHE_DIR)
    return undef unless ($ENV{SMAK_DEBUG} || $ENV{SMAK_CACHE_DIR});

    # Determine cache directory
    my $cdir = $ENV{SMAK_CACHE_DIR};
    if (defined $cdir) {
        # Disable caching for "off" or "0"
        return undef if ($cdir eq "off" || $cdir eq "0" || $cdir == 0);
        # Use default location for "default" or "1"
        # (fall through to default calculation below)
        unless ($cdir eq "default" || $cdir eq "1" || $cdir == 1) {
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

    # Save file mtimes for validation
    print $fh "# File mtimes for cache validation\n";
    print $fh "\%Smak::parsed_file_mtimes = (\n";
    for my $file (sort keys %parsed_file_mtimes) {
        my $mtime = $parsed_file_mtimes{$file};
        print $fh "    " . _quote_string($file) . " => $mtime,\n";
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
    _save_hash($fh, "pattern_rule", \%pattern_rule);
    _save_hash($fh, "pattern_deps", \%pattern_deps);
    _save_hash($fh, "pseudo_rule", \%pseudo_rule);
    _save_hash($fh, "pseudo_deps", \%pseudo_deps);

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

    # Validate cache - check if any makefile is newer than cache
    my $cache_mtime = (stat($cache_file))[9];
    for my $file (keys %parsed_file_mtimes) {
        if (-f $file) {
            my $file_mtime = (stat($file))[9];
            if ($file_mtime != $parsed_file_mtimes{$file} || $file_mtime > $cache_mtime) {
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
            print $fh "    " . _quote_string($key) . " => [" . join(", ", map { _quote_string($_) } @$val) . "],\n";
        } else {
            print $fh "    " . _quote_string($key) . " => " . _quote_string($val) . ",\n";
        }
    }
    print $fh ");\n\n";
}

# Helper: quote a string for Perl code
sub _quote_string {
    my ($str) = @_;
    return 'undef' unless defined $str;
    $str =~ s/\\/\\\\/g;  # Escape backslashes
    $str =~ s/'/\\'/g;    # Escape single quotes
    return "'$str'";
}

# Resolve a file through vpath directories
sub resolve_vpath {
    my ($file, $dir) = @_;

    # Skip inactive implicit rule patterns (e.g., RCS/SCCS if not present in project)
    # This avoids unnecessary vpath resolution and debug spam for patterns that don't exist
    if (is_inactive_pattern($file)) {
        warn "DEBUG vpath: Skipping inactive pattern file '$file'\n" if ($ENV{SMAK_DEBUG} || 0) >= 2;
        return $file;  # Return as-is without vpath resolution
    }

    # Skip files in ignored directories (e.g., /usr/include, /usr/local/include)
    # These are system directories that won't change, so no need for vpath resolution
    if (is_ignored_dir($file)) {
        return $file;  # Return as-is, system files don't need vpath resolution
    }

    # Early exit if no vpath patterns are defined - no point in checking
    unless (keys %vpath) {
        return $file;  # No vpath to search, return original
    }

    # Check if file exists in current directory first
    my $file_path = $file =~ m{^/} ? $file : "$dir/$file";
    if (-e $file_path) {
        # File found in current directory (common case, no debug needed)
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
                    return $candidate;
                }
            }
        }
    }

    # Not found via vpath, return original
    print STDERR "DEBUG vpath: '$file' not found via vpath, returning as-is\n" if $ENV{SMAK_DEBUG};
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

    my $makefile = '';
    my @targets;

    # Split command line into tokens (simple split, doesn't handle quoted strings)
    my @parts = split /\s+/, $cmd;

    # Skip the command itself (make/smak/path)
    shift @parts;

    # Parse arguments
    for (my $i = 0; $i < @parts; $i++) {
        if ($parts[$i] eq '-f' && $i + 1 < @parts) {
            $makefile = $parts[$i + 1];
            $i++;  # Skip next arg
        } elsif ($parts[$i] =~ /^-/) {
            # Skip other options
            # Handle options that take arguments
            if ($parts[$i] =~ /^-(C|I|j|l|o|W)$/ && $i + 1 < @parts) {
                $i++;  # Skip option argument
            }
        } else {
            # It's a target
            push @targets, $parts[$i];
        }
    }

    return ($makefile, @targets);
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

    # Track visited targets per makefile to handle same target names in different makefiles
    my $visit_key = "$makefile\t$target";
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
                        $rule = $pattern_rule{$pkey} || '';
                        # Add pattern rule's dependencies to fixed dependencies
                        my @pattern_deps = @{$pattern_deps{$pkey} || []};
                        $stem = $1;  # Save stem for $* expansion
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
    } elsif (exists $pattern_deps{$key}) {
        @deps = @{$pattern_deps{$key} || []};
        $rule = $pattern_rule{$key} || '';
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try to find pattern rule match
        for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    @deps = @{$pattern_deps{$pkey} || []};
                    $rule = $pattern_rule{$pkey} || '';
                    # Expand % in dependencies
                    $stem = $1;  # Save stem for $* expansion
                    @deps = map { s/%/$stem/g; $_ } @deps;
                    # Resolve dependencies through vpath
                    use Cwd 'getcwd';
                    my $cwd = getcwd();
                    @deps = map { resolve_vpath($_, $cwd) } @deps;
                    last;
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

    # Apply vpath resolution to all dependencies
    use Cwd 'getcwd';
    my $cwd = getcwd();
    @deps = map { resolve_vpath($_, $cwd) } @deps;

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

    # If not .PHONY and target is up-to-date, skip building
    unless ($is_phony) {
        warn "DEBUG[" . __LINE__ . "]:   Checking if target exists and is up-to-date...\n" if $ENV{SMAK_DEBUG};
        if (-e $target && !needs_rebuild($target)) {
            warn "DEBUG:   Target '$target' is up-to-date, skipping\n" if $ENV{SMAK_DEBUG};
            # Remove from stale cache if it was there
            delete $stale_targets_cache{$target};
            return;
        }
        warn "DEBUG[" . __LINE__ . "]:   Target needs rebuilding\n" if $ENV{SMAK_DEBUG};
        # Track this target as stale (needs rebuilding)
        $stale_targets_cache{$target} = time();
    }

    # Recursively build dependencies
    # In parallel mode, skip this - let job-master handle dependency expansion
    warn "DEBUG[" . __LINE__ . "]:   Checking job_server_socket: " . (defined $job_server_socket ? "SET (fd=" . fileno($job_server_socket) . ")" : "NOT SET") . "\n" if $ENV{SMAK_DEBUG};
    unless ($job_server_socket) {
        warn "DEBUG[" . __LINE__ . "]:   Building " . scalar(@deps) . " dependencies sequentially (no job server)...\n" if $ENV{SMAK_DEBUG};
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

    # Execute rule if it exists (submit_job is blocking, so no need to wait)
    if ($rule && $rule =~ /\S/) {
        warn "DEBUG[" . __LINE__ . "]:   Executing rule for target '$target'\n" if $ENV{SMAK_DEBUG};
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        warn "DEBUG[" . __LINE__ . "]:   After format_output\n" if $ENV{SMAK_DEBUG};
        # Expand variables
        my $expanded = expand_vars($converted);
        warn "DEBUG[" . __LINE__ . "]:   After expand_vars\n" if $ENV{SMAK_DEBUG};

        # Expand automatic variables
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$deps[0] || ''/ge;            # $< = first prerequisite
        $expanded =~ s/\$\^/join(' ', @deps)/ge;         # $^ = all prerequisites
        $expanded =~ s/\$\*/$stem/g;                     # $* = stem (part matching %)

        warn "DEBUG[" . __LINE__ . "]:   About to execute commands\n" if $ENV{SMAK_DEBUG};
        # Execute each command line
        for my $cmd_line (split /\n/, $expanded) {
            warn "DEBUG[" . __LINE__ . "]:     Processing command line\n" if $ENV{SMAK_DEBUG};
            next unless $cmd_line =~ /\S/;  # Skip empty lines

            warn "DEBUG[" . __LINE__ . "]:     Command: $cmd_line\n" if $ENV{SMAK_DEBUG};
            # Check if command starts with @ (silent mode)
            my $silent = ($cmd_line =~ s/^\s*@//);

            # In dry-run mode, handle recursive make invocations or print commands
            if ($dry_run_mode) {
                warn "DEBUG[" . __LINE__ . "]:     In dry-run mode\n" if $ENV{SMAK_DEBUG};
                # Check if this is a recursive make/smak invocation
                if ($cmd_line =~ /\b(make|smak)\s/ || $cmd_line =~ m{/smak(?:\s|$)}) {
                    # Debug: show what we detected
                    warn "DEBUG[" . __LINE__ . "]: Detected recursive make/smak: $cmd_line\n" if $ENV{SMAK_DEBUG};

                    # Parse the make/smak command line to extract -f and targets
                    my ($sub_makefile, @sub_targets) = parse_make_command($cmd_line);

                    warn "DEBUG[" . __LINE__ . "]: Parsed makefile='$sub_makefile' targets=(" . join(',', @sub_targets) . ")\n" if $ENV{SMAK_DEBUG};

                    if ($sub_makefile) {
                        # Save current makefile state
                        my $saved_makefile = $makefile;

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
                                # Restore state and fall back to just printing the command
                                $makefile = $saved_makefile;
                                print "$cmd_line\n";
                                next;
                            }
                        }

                        # Build sub-targets recursively in dry-run mode
                        if (@sub_targets) {
                            for my $sub_target (@sub_targets) {
                                build_target($sub_target, $visited, $depth + 1);
                            }
                        } else {
                            # No targets specified, build first target
                            my $first_target = get_first_target($makefile);
                            build_target($first_target, $visited, $depth + 1) if $first_target;
                        }

                        # Restore makefile state
                        $makefile = $saved_makefile;
                        next;
                    }
                }

                # Not a recursive make, just print the command
                print "$cmd_line\n";
                next;
            }

            # Execute command - use job system if available, otherwise sequential
            use Cwd 'getcwd';
            my $cwd = getcwd();
            if ($job_server_socket && 0 != $jobs) {
                warn "DEBUG[" . __LINE__ . "]:     Using job server ($jobs)\n" if $ENV{SMAK_DEBUG};
                # Parallel mode - submit to job server (job master will echo the command)
                submit_job($target, $cmd_line, $cwd);
            } else {
                warn "DEBUG[" . __LINE__ . "]:     Sequential execution\n" if $ENV{SMAK_DEBUG};
                # Sequential mode - echo command here, then execute directly
                unless ($silent_mode) {
                    print "$cmd_line\n";
                }
                execute_command_sequential($target, $cmd_line, $cwd);
                warn "DEBUG[" . __LINE__ . "]:     Command completed\n" if $ENV{SMAK_DEBUG};
            }
        }
    } elsif ($job_server_socket && @deps > 0) {
        # In parallel mode with no rule but has dependencies
        # Submit to job-master for dependency expansion
        use Cwd 'getcwd';
        my $cwd = getcwd();
        warn "DEBUG: Submitting composite target '$target' to job-master\n" if $ENV{SMAK_DEBUG};
        submit_job($target, "true", $cwd);
    }
}

sub dry_run_target {
    my ($target, $visited, $depth) = @_;
    $visited ||= {};
    $depth ||= 0;

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
    print "${indent}Building: $target\n";

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
                        $rule = $pattern_rule{$pkey} || '';
                        # Add pattern rule's dependencies to fixed dependencies
                        my @pattern_deps = @{$pattern_deps{$pkey} || []};
                        $stem = $1;  # Save stem for $* expansion
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
    } elsif (exists $pattern_deps{$key}) {
        @deps = @{$pattern_deps{$key} || []};
        $rule = $pattern_rule{$key} || '';
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try to find pattern rule match
        for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    @deps = @{$pattern_deps{$pkey} || []};
                    $rule = $pattern_rule{$pkey} || '';
                    # Expand % in dependencies
                    $stem = $1;  # Save stem for $* expansion
                    @deps = map { s/%/$stem/g; $_ } @deps;
                    # Resolve dependencies through vpath
                    use Cwd 'getcwd';
                    my $cwd = getcwd();
                    @deps = map { resolve_vpath($_, $cwd) } @deps;
                    last;
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

    # Apply vpath resolution to all dependencies
    use Cwd 'getcwd';
    my $cwd = getcwd();
    @deps = map { resolve_vpath($_, $cwd) } @deps;

    # Print dependencies
    if (@deps) {
        print "${indent}  Dependencies: ", join(', ', @deps), "\n";
    }

    # Recursively dry-run dependencies
    for my $dep (@deps) {
        dry_run_target($dep, $visited, $depth + 1);
    }

    # Print rule if it exists
    if ($rule && $rule =~ /\S/) {
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        # Expand variables
        my $expanded = expand_vars($converted);
        print $expanded;
    }
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
    }

    # Helper: check for asynchronous notifications and job output
    my %recent_file_notifications;  # Track recent file notifications to avoid spam
    my $check_notifications = sub {
        return -1 unless defined $socket;

        # Handle cancel request from signal handler
        if ($SmakCli::cancel_requested) {
	    warn "DEBUG: cancel requested ($SmakCli::cancel_requested)\n" if $ENV{SMAK_DEBUG};
            eval {
                print $socket "KILL_WORKERS\n";
		# response checked in main loop
            };
            print "\n^C - Cancelling ongoing builds...\n";
            STDOUT->flush();
            return -2;  # Had output, will trigger prompt redraw
        }

        my $select = IO::Select->new($socket);
        my $had_output = 0;
        my $now = time();

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
        });

        # Check for async notifications that arrived during command execution
        $check_notifications->();

        # If reprompt was requested, show prompt before next readline
        if ($SmakCli::reprompt_requested) {
            $SmakCli::reprompt_requested = 0;
            print $prompt;
            STDOUT->flush();
        }
    }

    $interactive = 0;

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

our $busy = 0; # more to do, not just waiting.
our $rp_pending = 0;

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
        cmd_rescan($words, $socket);

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

    } else {
        print "Unknown command: $cmd (try 'help')\n";
    }

    return 0;
}

sub show_unified_help {
    print <<'HELP';
Available commands:
  build <target>      Build the specified target (or default if none given)
  rebuild <target>    Rebuild only if tracked files changed (FUSE)
  watch, w            Monitor file changes from FUSE filesystem
  unwatch             Stop monitoring file changes
  tasks, t            List pending and active tasks
  status              Show job server status
  progress            Show detailed job progress
  files, f            List tracked file modifications (FUSE)
  stale               Show targets that need rebuilding (FUSE)
  dirty <file>        Mark a file as out-of-date (dirty)
  touch <file>        Update file timestamp and mark dirty
  rm <file>           Remove file (saves to .{file}.prev) and mark dirty
  ignore <file>       Ignore a file for dependency checking
  ignore -none        Clear all ignored files
  ignore              List ignored files and directories
  needs <file>        Show which targets depend on a file
  list [pattern]      List all targets (optionally matching pattern)
  vars [pattern]      Show all variables (optionally matching pattern)
  deps <target>       Show dependencies for target
  vpath <file>        Test vpath resolution for a file
  add-rule <t> <d> <r> Add a new rule (rule text can use \n and \t)
  mod-rule <t> <r>    Modify the rule for a target
  mod-deps <t> <d>    Modify the dependencies for a target
  del-rule <t>        Delete a rule for a target
  start [N]           Start job server with N workers (if not running)
  kill                Kill all workers
  restart [N]         Restart workers (optionally specify count)
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

Examples:
  build all           Build the 'all' target
  build               Build the default target
  list task           List targets matching 'task'
  deps foo.o          Show dependencies for foo.o
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
            return;
        }
    }

    if ($socket) {
        # Job server mode - submit jobs and wait for results
        my $exit_req = ${$state->{exit_requested}};
        for my $target (@targets) {
            print $socket "SUBMIT_JOB\n";
            print $socket "$target\n";
            print $socket ".\n";
            print $socket "cd . && make $target\n";

            # Wait for completion
            my $select = IO::Select->new($socket);
            my $job_done = 0;
            while (!$exit_req && !$job_done) {
                if ($select->can_read(0.1)) {
                    my $response = <$socket>;
                    last unless defined $response;
                    chomp $response;
                    if ($response =~ /^OUTPUT (.*)$/) {
                        print "$1\n";
                        reprompt();
                    } elsif ($response =~ /^ERROR (.*)$/) {
                        print "ERROR: $1\n";
                        reprompt();
                    } elsif ($response =~ /^WARN (.*)$/) {
                        print "WARN: $1\n";
                        reprompt();
                    } elsif ($response =~ /^JOB_COMPLETE (.+?) (\d+)$/) {
                        my ($completed_target, $exit_code) = ($1, $2);
                        if ($exit_code == 0) {
                            print "✓ Build succeeded: $completed_target\n";
                        } else {
                            print "✗ Build failed: $completed_target (exit code $exit_code)\n";
                        }
                        $job_done = 1;
			reprompt();
                    }
                }
            }

            last if $exit_req;
        }
    } else {
        # No job server - build sequentially
        print "(Building in sequential mode - use 'start' for parallel builds)\n";
        for my $target (@targets) {
            eval {
                build_target($target);
            };
            if ($@) {
                print "✗ Build failed: $target\n";
                print STDERR $@;
                reprompt();
                last;
            } else {
                print "✓ Build succeeded: $target\n";
                reprompt();
            }
        }
    }

    $busy = 0;
    if ($rp_pending) {
	reprompt();
    }
}

sub cmd_rebuild {
    my ($words, $socket, $opts) = @_;

    if (!$socket) {
        print "Job server not running. Use 'start' to enable.\n";
        return;
    }

    if (@$words == 0) {
        print "Usage: rebuild <target>\n";
        return;
    }

    # Check if target is stale first
    my $target = $words->[0];
    print $socket "IS_STALE:$target\n";
    my $response = <$socket>;
    if ($response && $response =~ /^STALE:yes/) {
        print "Target '$target' is stale, rebuilding...\n";
        cmd_build($words, $socket, $opts, {exit_requested => \0});
    } elsif ($response && $response =~ /^STALE:no/) {
        print "Target '$target' is up-to-date, skipping rebuild.\n";
    } else {
        print "Could not determine if target is stale.\n";
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
    my ($words, $socket) = @_;

    my $auto = 0;
    if (@$words > 0 && $words->[0] eq '-auto') {
        $auto = 1;
        print "Auto-rescan enabled (will check timestamps periodically)\n";
    }

    if ($socket) {
        # Job server running - send rescan command
        print "Rescanning timestamps...\n" unless $auto;
        my $cmd = $auto ? "RESCAN_AUTO\n" : "RESCAN\n";
        print $socket $cmd;
        my $response = <$socket>;
        chomp $response if $response;
        print "$response\n" if $response && !$auto;
    } else {
        print "Job server not running. Rescan requires active job server.\n";
    }
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


sub interactive_debug {
    my ($OUT,$input) = @_ ;
    my $term = Term::ReadLine->new('smak');
    my $do1 = defined $OUT;
    if (! $do1) {
	$OUT = $term->OUT || \*STDOUT;
    }
    
    print $OUT "Interactive smak debugger. Type 'help' for commands.\n";

    while ((1 == $do1++) ||
	   defined($input = $term->readline($echo ? $prompt : $prompt))) {

        chomp $input;

        # Echo the line if echo mode is enabled
        if ($echo && $input ne '') {
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
  build <target>       - Build a target
  progress	       - Show work in progress
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
        elsif ($cmd eq 'build') {
            if (@parts < 2) {
                print $OUT "Usage: build <target>\n";
            } else {
                my $target = $parts[1];
                eval { build_target($target); };
                if ($@) {
                    print $OUT "Error building target: $@\n";
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

	last if $do1;
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

# Get FUSE remote server information from df output
# Returns (server, remote_path) or (undef, undef) if not FUSE
sub get_fuse_remote_info {
    my ($path) = @_;
    $path //= '.';

    # Run df to get filesystem info
    my $df_output = `df '$path' 2>/dev/null`;
    return (undef, undef) unless $df_output;

    # Parse df output - look for sshfs format: user@host:/remote/path
    # Example: dkc@workhorse:/home/dkc/src-00/iverilog
    my @lines = split(/\n/, $df_output);
    return (undef, undef) unless @lines >= 2;

    my $fs_line = $lines[1];  # First line is header
    my ($filesystem) = split(/\s+/, $fs_line);

    # Check if it matches FUSE/sshfs format: [user@]host:path
    if ($filesystem =~ /^(.+?):(.+)$/) {
        my ($server, $remote_path) = ($1, $2);
        return ($server, $remote_path);
    }

    return (undef, undef);
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
    use Cwd 'abs_path';

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
    my $worker_script = "$bin_dir/smak-worker";
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
    open(my $port_fh, '>', "$port_dir/smak-jobserver-$$.port") or warn "Cannot write port file: $!\n";
    if ($port_fh) {
        print $port_fh "$observer_port\n";
        print $port_fh "$master_port\n";
        close($port_fh);
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
    
    sub detect_fuse_monitor {
        # Check if we're in a FUSE filesystem
        my $cwd = abs_path('.');

        # Use df to get the mountpoint for current directory
        my $df_output = `df . 2>/dev/null | tail -1`;
        my $mountpoint;
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
                $is_fuse = 1;
                $fstype = $2;
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
                return ($mountpoint, $port);
            }
        }

        return ();
    }

    my $fuse_mountpoint;
    if (my ($mountpoint, $fuse_port) = detect_fuse_monitor()) {
        $fuse_mountpoint = $mountpoint;
        print STDERR "Detected FUSE filesystem at $mountpoint, port $fuse_port\n" if $ENV{SMAK_DEBUG};
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

    # Spawn workers
    for (my $i = 0; $i < $num_workers; $i++) {
        my $pid = fork();
        die "Cannot fork worker: $!\n" unless defined $pid;

        if ($pid == 0) {	    
            # Child - exec worker
            if ($ssh_host) {
		my $local_path = getcwd();
		$local_path =~ s=^$fuse_mountpoint/==;
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
    our %failed_targets;  # target => exit_code (failed targets)
    our %pending_composite;  # composite targets waiting for dependencies
                            # target => {deps => [list], master_socket => socket}
    our $next_task_id = 1;
    my $auto_rescan = 0;  # Flag for automatic periodic rescanning

    # Helper functions
    sub process_command {
        my ($cmd) = @_;
        return '' unless defined $cmd;

        # Process each line of multi-line commands
        my @lines;
        for my $line (split /\n/, $cmd) {
            next unless $line =~ /\S/;  # Skip empty lines

            # Strip @ (silent) and - (ignore errors) prefixes
            $line =~ s/^\s*[@-]+//;

            push @lines, $line if $line =~ /\S/;
        }

        # Join multiple commands with && so they execute as one line
        return join(" && ", @lines);
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

        # Expand automatic variables
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$deps[0] || ''/ge;             # $< = first prerequisite
        $expanded =~ s/\$\^/join(' ', @deps)/ge;          # $^ = all prerequisites

        return $expanded;
    }

    sub is_target_pending {
        my ($target) = @_;

        # Check if already completed
        return 1 if exists $completed_targets{$target};

        # Check if in progress (includes queued, running, and pending composite targets)
        return 1 if exists $in_progress{$target};

        # Check if already in queue
        for my $job (@job_queue) {
            return 1 if $job->{target} eq $target;
        }

        # Check if currently running
        for my $task_id (keys %running_jobs) {
            return 1 if $running_jobs{$task_id}{target} eq $target;
        }

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
    sub verify_target_exists {
        my ($target, $dir) = @_;

        # Construct full path
        my $target_path = $dir ? "$dir/$target" : $target;

        # First quick check
        return 1 if -e $target_path;

        # If not found, try syncing the directory and retry
        # This handles cases where the file is buffered but not yet visible
        for my $attempt (1..3) {
            # Sync the directory to flush filesystem buffers
            if ($dir && -d $dir) {
                # Open and sync the directory
                if (opendir(my $dh, $dir)) {
                    # On Linux, we can't fsync a directory handle directly in Perl
                    # But closing will flush some buffers
                    closedir($dh);
                }
            }

            # Small delay to allow filesystem to catch up
            select(undef, undef, undef, 0.01 * $attempt);  # 10ms, 20ms, 30ms

            return 1 if -e $target_path;

            vprint "Warning: Target '$target' not found at '$target_path', retry $attempt/3\n";
        }

        # Final check
        if (-e $target_path) {
            print STDERR "Target '$target' found after retries\n";
            return 1;
        }

        vprint "ERROR: Target '$target' does not exist at '$target_path' after task completion\n";
        return 0;
    }

    # Recursively queue a target and all its dependencies
    our @recurse_log; # for debug
    our $recurse_limit = 20;
    sub queue_target_recursive {
        my ($target, $dir, $msocket, $depth) = @_;
        $msocket ||= $master_socket;  # Use provided or fall back to global

        # Skip if already handled
        return if is_target_pending($target);

        # Check if target is assumed (marked as already built)
        if (exists $assumed_targets{$target}) {
            $completed_targets{$target} = 1;
            $in_progress{$target} = "done";
            warn "Target '$target' is assumed (marked as already built), skipping\n" if $ENV{SMAK_DEBUG};
            return;
        }

	$recurse_log[$depth] = "${dir}:$target";
	
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
            @deps = @{$pattern_deps{$key} || []};
            $rule = $pattern_rule{$key} || '';
        } elsif (exists $pseudo_deps{$key}) {
            @deps = @{$pseudo_deps{$key} || []};
            $rule = $pseudo_rule{$key} || '';
        }

        # If we have fixed deps but no rule, try to find a matching pattern rule
        if ($has_fixed_deps && !($rule && $rule =~ /\S/)) {
            print STDERR "Target '$target' in fixed_deps but no rule, checking for pattern rules\n" if $ENV{SMAK_DEBUG};
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        # Found matching pattern rule - use its rule, keep fixed deps
                        $rule = $pattern_rule{$pkey} || '';
                        $stem = $1;  # Save stem for $* expansion
                        print STDERR "Found pattern rule '$pattern' for target '$target' (stem='$stem')\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }

        # If still no deps/rule, try to find pattern rule match
        if (!$has_fixed_deps && !@deps) {
            for my $pkey (keys %pattern_rule) {
                if ($pkey =~ /^[^\t]+\t(.+)$/) {
                    my $pattern = $1;
                    my $pattern_re = $pattern;
                    $pattern_re =~ s/%/(.+)/g;
                    if ($target =~ /^$pattern_re$/) {
                        @deps = @{$pattern_deps{$pkey} || []};
                        $rule = $pattern_rule{$pkey} || '';
                        # Expand % in dependencies
                        $stem = $1;  # Save stem for $* expansion
                        @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @deps;
                        # Resolve dependencies through vpath
                        my @orig_deps = @deps;
                        @deps = map { resolve_vpath($_, $dir) } @deps;
                        if ($ENV{SMAK_DEBUG} && "@orig_deps" ne "@deps") {
                            print STDERR "  Deps after vpath: " . join(", ", @deps) . "\n";
                        }
                        print STDERR "Matched pattern rule '$pattern' for target '$target' (stem='$stem')\n" if $ENV{SMAK_DEBUG};
                        last;
                    }
                }
            }
        }

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
                my @pending_deps = grep { !exists $completed_targets{$_} && !exists $failed_targets{$_} } @deps;
                if (@pending_deps) {
                    $in_progress{$target} = "pending";
                    $pending_composite{$target} = {
                        deps => \@pending_deps,
                        master_socket => $msocket,
                    };
                    print STDERR "Pre-registering composite target '$target' with " . scalar(@pending_deps) . " pending deps\n" if $ENV{SMAK_DEBUG};
                }
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
                    $completed_targets{$single_dep} = 1;
                    print STDERR "Dependency '$single_dep' exists at '$dep_path', marking complete\n" if $ENV{SMAK_DEBUG};
                    next;
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
		    queue_target_recursive($single_dep, $dir, $msocket, $depth+1);
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
                        $stale_targets_cache{$target} = time();
                        warn "Target '$target' needs rebuilding\n" if $ENV{SMAK_DEBUG};
                    } else {
                        # Target is up-to-date
                        $completed_targets{$target} = 1;
                        $in_progress{$target} = "done";
                        warn "Target '$target' is up-to-date, skipping\n" if $ENV{SMAK_DEBUG};
                        delete $stale_targets_cache{$target} if exists $stale_targets_cache{$target};
                        return;
                    }
                } else {
                    # Target doesn't exist - needs building
                    $needs_build = 1;
                    $stale_targets_cache{$target} = time();
                    warn "Target '$target' doesn't exist, needs building\n" if $ENV{SMAK_DEBUG};
                }
            }

            # Expand $* with stem if we matched a pattern rule
            if ($stem) {
                $rule =~ s/\$\*/$stem/g;
            }
            my $processed_rule = process_command($rule);
            $processed_rule = expand_job_command($processed_rule, $target, \@deps);

            push @job_queue, {
                target => $target,
                dir => $dir,
                command => $processed_rule,
            };
            $in_progress{$target} = "queued";
            vprint "Queued target: $target\n";
        } elsif (@deps > 0) {
            # Composite target or target with dependencies but no rule
            if ($ENV{SMAK_DEBUG}) {
                print STDERR "Target '$target' has " . scalar(@deps) . " dependencies but no rule\n";
                print STDERR "  Dependencies: " . join(", ", @deps) . "\n";
            }
            # If file exists (relative to working directory), consider it satisfied
            my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
            if (-e $target_path) {
                $completed_targets{$target} = 1;
                $in_progress{$target} = "done";
                print STDERR "Target '$target' exists at '$target_path', marking complete (no rule found)\n" if $ENV{SMAK_DEBUG};
            } else {
                # Update or finalize composite target registration
                # Check if any dependencies failed during recursive queuing
                my @failed_deps = grep { exists $failed_targets{$_} } @deps;
                if (@failed_deps) {
                    # One or more dependencies failed - this should have been caught already
                    # but handle it here as a safety net
                    if (exists $pending_composite{$target}) {
                        delete $pending_composite{$target};
                    }
                    $in_progress{$target} = "failed";
                    $failed_targets{$target} = $failed_targets{$failed_deps[0]};
                    print STDERR "Composite target '$target' FAILED due to failed dependency '$failed_deps[0]'\n";
		    reprompt();
                } else {
                    my @pending_deps = grep { !exists $completed_targets{$_} } @deps;
                    if (@pending_deps) {
                        # Update the composite target (may have been pre-registered)
                        $in_progress{$target} = "pending";
                        $pending_composite{$target} = {
                            deps => \@pending_deps,
                            master_socket => $msocket,
                        };
                        vprint "Composite target $target waiting for " . scalar(@pending_deps) . " dependencies\n";
                        print STDERR "  Pending: " . join(", ", @pending_deps) . "\n" if $ENV{SMAK_DEBUG};
                    } else {
                        # All deps already complete
                        if (exists $pending_composite{$target}) {
                            delete $pending_composite{$target};
                        }
                        $completed_targets{$target} = 1;
                        $in_progress{$target} = "done";
                        print $msocket "JOB_COMPLETE $target 0\n" if $msocket;
                    }
                }
            }
        } else {
            # No command and no deps - check if file exists
            my $target_path = $target =~ m{^/} ? $target : "$dir/$target";
            if (-e $target_path) {
                $completed_targets{$target} = 1;
                $in_progress{$target} = "done";
                print STDERR "Target '$target' exists at '$target_path', marking complete (no rule or deps)\n" if $ENV{SMAK_DEBUG};
            } else {
                # Target doesn't exist and has no rule to build it - this is an error
                print STDERR "ERROR: No rule to make target '$target' (needed by other targets)\n";
                $in_progress{$target} = "failed";
                $failed_targets{$target} = 1;
                # Send completion message to master socket if this was a submitted job
                print $msocket "JOB_COMPLETE $target 1\n" if $msocket;
                # Fail any composite targets waiting for this
                fail_dependent_composite_targets($target, 1);
            }
        }
    }

    sub check_queue_state {
        my ($label) = @_;

        my $ready_workers = 0;
        for my $w (@workers) {
            $ready_workers++ if $worker_status{$w}{ready};
        }

	if (scalar(@workers) != $ready_workers || scalar(@job_queue)
	                                       || scalar(keys %running_jobs)) {
	    vprint "[$label] Queue state: " . scalar(@job_queue) . " queued, ";
	    vprint "$ready_workers/" . scalar(@workers) . " ready, ";
	    vprint scalar(keys %running_jobs) . " running";

	    # Show running targets (up to 5)
	    # For each job, try to extract the actual file being built from the command
	    if (keys %running_jobs) {
	        my @running;
	        for my $task_id (keys %running_jobs) {
	            my $job = $running_jobs{$task_id};
	            my $display_name = $job->{target};

	            # Try to extract output filename from command (look for -o argument)
	            my $cmd = $job->{command};
	            if ($cmd =~ /-o\s+(\S+)/) {
	                # Found -o outputfile
	                my $output = $1;
	                # Strip directory path, just show filename
	                $output =~ s{.*/}{};
	                $display_name = $output if $output;
	            } elsif ($job->{target} =~ /\.(o|a|so|exe|out)$/) {
	                # Target looks like a file, use it as-is
	                $display_name = $job->{target};
	            }

	            push @running, $display_name;
	        }

	        @running = sort @running;
	        if (@running <= 5) {
	            vprint " (" . join(", ", @running) . ")";
	        } else {
	            vprint " (" . join(", ", @running[0..4]) . ", ... " . (@running - 5) . " more)";
	        }
	    }
	    vprint "\n";
	}
	
	if (@job_queue > 0 && @job_queue <= 5) {
	    for my $job (@job_queue) {
		vprint "  queued: $job->{target}\n";
	    }
	} elsif (@job_queue > 5) {
	    for my $i (0..4) {
		vprint "  queued: $job_queue[$i]{target}\n";
	    }
	    vprint "  ... and " . (@job_queue - 5) . " more\n";
        }

	# can abort here if things are bad
    }

    # Check if a target can be built (has a rule or exists as a source file)
    sub can_build_target {
        my ($target, $target_dir) = @_;
        $target_dir //= '.';

        # Check if file exists in current directory or via vpath
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
            @deps = @{$pattern_deps{$key}};
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
                        @deps = @{$pattern_deps{$pkey} || []};
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
                if ($comp->{master_socket}) {
                    print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                }
                delete $pending_composite{$comp_target};
            }
        }
    }

    sub dispatch_jobs {
	my ($do,$block) = @_;
	my $j = 0;

        check_queue_state("dispatch_jobs start");

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
   	        warn "No workers\n" if $ENV{SMAK_DEBUG};
		last; # No workers available
	    }

            # Find next job whose dependencies are all satisfied
            my $job_index = -1;
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

                print STDERR "\n=== DEBUG dispatch: Checking job [$i] '$target' ===\n" if $ENV{SMAK_DEBUG};

                # Check if this job's dependencies are satisfied
                my $key = "$makefile\t$target";
                my @deps;
                my $stem;  # For pattern expansion
                if (exists $fixed_deps{$key}) {
                    @deps = @{$fixed_deps{$key} || []};
                } elsif (exists $pattern_deps{$key}) {
                    @deps = @{$pattern_deps{$key} || []};
                } elsif (exists $pseudo_deps{$key}) {
                    @deps = @{$pseudo_deps{$key} || []};
                }

                # If no deps found by exact match, try pattern matching (like queue_target_recursive does)
                if (!@deps) {
                    for my $pkey (keys %pattern_rule) {
                        if ($pkey =~ /^[^\t]+\t(.+)$/) {
                            my $pattern = $1;
                            my $pattern_re = $pattern;
                            $pattern_re =~ s/%/(.+)/g;
                            if ($target =~ /^$pattern_re$/) {
                                @deps = @{$pattern_deps{$pkey} || []};
                                # Expand % in dependencies using the stem
                                $stem = $1;
                                @deps = map { my $d = $_; $d =~ s/%/$stem/g; $d } @deps;
                                print STDERR "DEBUG dispatch: Matched pattern '$pattern' for '$target', stem='$stem', expanded deps: [" . join(", ", @deps) . "]\n" if $ENV{SMAK_DEBUG};
                                last;
                            }
                        }
                    }
                }

                print STDERR "DEBUG dispatch: Checking job '$target', deps: [" . join(", ", @deps) . "]\n" if $ENV{SMAK_DEBUG};

                # Check if any dependency has failed - if so, fail this job too
                my $has_failed_dep = 0;
                for my $dep (@deps) {
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

                    # Split on whitespace in case multiple dependencies are in one string
                    for my $single_dep (split /\s+/, $expanded_dep) {
                        next unless $single_dep =~ /\S/;

                        # Check if dependency is completed or exists as file (relative to job dir)
                        my $dep_path = $single_dep =~ m{^/} ? $single_dep : "$job->{dir}/$single_dep";

                        print STDERR "DEBUG dispatch:   Checking dep '$single_dep' for target '$target'\n" if $ENV{SMAK_DEBUG};
                        print STDERR "DEBUG dispatch:     completed_targets: " . (exists $completed_targets{$single_dep} ? "YES" : "NO") . "\n" if $ENV{SMAK_DEBUG};
                        print STDERR "DEBUG dispatch:     file exists (-e $dep_path): " . (-e $dep_path ? "YES" : "NO") . "\n" if $ENV{SMAK_DEBUG};
                        print STDERR "DEBUG dispatch:     in_progress: " . (exists $in_progress{$single_dep} ? $in_progress{$single_dep} : "NO") . "\n" if $ENV{SMAK_DEBUG};

                        # If the dependency was recently completed, verify it actually exists on disk
                        # to avoid race conditions where the file isn't visible yet due to filesystem buffering
                        if ($completed_targets{$single_dep}) {
                            # First check if file exists - fast path
                            if (-e $dep_path) {
                                # File exists, dependency satisfied
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
                                print STDERR "  Job '$target' waiting for dependency '$single_dep' (being rebuilt)\n";
                                last;
                            }
                            # Pre-existing source file or already built, OK to proceed
                        } elsif (exists $in_progress{$single_dep} &&
                                 $in_progress{$single_dep} ne "done" &&
                                 $in_progress{$single_dep} ne "failed") {
                            # Dependency is queued or currently building - wait for it
                            $deps_satisfied = 0;
                            print STDERR "  Job '$target' waiting for dependency '$single_dep' (queued/building)\n";
                            print STDERR "DEBUG dispatch:     Set deps_satisfied=0 for '$target' due to '$single_dep' in_progress\n" if $ENV{SMAK_DEBUG};
                            last;
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
                                print STDERR "  Job '$target' waiting for dependency '$single_dep'\n";
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
                print STDERR "No jobs with satisfied dependencies (stuck!)\n";
                print STDERR "Job queue has " . scalar(@job_queue) . " jobs:\n";
                my $max_show = @job_queue < 10 ? $#job_queue : 9;
                for my $i (0 .. $max_show) {
                    my $job = $job_queue[$i];
                    print STDERR "  [$i] $job->{target}\n";
                }
                print STDERR "  ...\n" if @job_queue > 10;
                last;
            }

            # Dispatch the job
            my $job = splice(@job_queue, $job_index, 1);
            my $task_id = $next_task_id++;

            $worker_status{$ready_worker}{ready} = 0;
            $worker_status{$ready_worker}{task_id} = $task_id;

            $running_jobs{$task_id} = {
                target => $job->{target},
                worker => $ready_worker,
                dir => $job->{dir},
                command => $job->{command},
                started => 0,
                output => [],  # Capture output for error analysis
            };
	    
	    $j++;

	    $in_progress{$job->{target}} = $ready_worker;
	    
            # Send task to worker
            print $ready_worker "TASK $task_id\n";
            print $ready_worker "DIR $job->{dir}\n";
            print $ready_worker "CMD $job->{command}\n";

            vprint "Dispatched task $task_id to worker\n";

	    if (! $silent_mode) {
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
    my $last_consistency_check = time();
    my $jobs_received = 0;  # Track if we've received any job submissions

    while (1) {
        # Check if all work is complete AND master has disconnected
        # (In interactive mode, stay running even when idle)
        if ($jobs_received && @job_queue == 0 && keys(%running_jobs) == 0 && keys(%pending_composite) == 0 && !defined($master_socket)) {
            vprint "All jobs complete and master disconnected. Job-master exiting.\n";
            last;
        }

        my @ready = $select->can_read(0.1);

        # Periodic consistency check - run every 2 seconds
        my $now = time();
        if ($now - $last_consistency_check >= 2) {
            $last_consistency_check = $now;

            # Check all worker sockets for pending messages
            for my $worker (@workers) {
                $worker->blocking(0);
                while (my $line = <$worker>) {
                    chomp $line;
                    vprint "Consistency check: processing pending message: $line\n";

                    # Process the message inline (same logic as main event loop)
                    if ($line eq 'READY') {
                        $worker_status{$worker}{ready} |= 2;
                        vprint "Worker ready
";
                        dispatch_jobs();

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

                            # Only verify file existence for targets that look like real files
                            my $should_verify = $looks_like_file && !$is_common_phony;

                            if (!$should_verify || verify_target_exists($job->{target}, $job->{dir})) {
                                $completed_targets{$job->{target}} = 1;
                                $in_progress{$job->{target}} = "done";
                                print STDERR "Task $task_id completed successfully: $job->{target}\n" if $ENV{SMAK_DEBUG};
                            } else {
                                # File doesn't exist even after retries - treat as failure
                                $in_progress{$job->{target}} = "failed";
                                print STDERR "Task $task_id FAILED: $job->{target} - output file not found\n";
                                $exit_code = 1;  # Mark as failed for composite target handling below
                            }
                        }

                        # Handle successful completion
                        if ($exit_code == 0 && $job->{target} && $completed_targets{$job->{target}}) {
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
                                    if ($comp->{master_socket}) {
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
                            if ($job->{target} && $retry_count < 1) {  # Max 1 retry
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

                                # Re-queue the target
                                push @job_queue, {
                                    target => $job->{target},
                                    dir => $job->{dir},
                                    command => $job->{command},
                                };

                                # Try to dispatch immediately
                                dispatch_jobs();
                            } else {
                                # No retry - mark as failed
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
                                        if ($comp->{master_socket}) {
                                            print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                                        }
                                        delete $pending_composite{$comp_target};
                                    }
                                }
                            }
                        }

                        print $master_socket "JOB_COMPLETE $job->{target} $exit_code\n" if $master_socket;

                    } elsif ($line =~ /^OUTPUT (.*)$/) {
                        print $master_socket "OUTPUT $1\n" if $master_socket;
                    } elsif ($line =~ /^ERROR (.*)$/) {
                        print $master_socket "ERROR $1\n" if $master_socket;
                    } elsif ($line =~ /^WARN (.*)$/) {
                        print $master_socket "WARN $1\n" if $master_socket;
                    }
                }
                $worker->blocking(1);
            }

	    check_queue_state("intermittent check");

            # Perform auto-rescan if enabled
            if ($auto_rescan) {
                my $stale_count = 0;
                # Get makefile directory for relative path resolution
                my $makefile_dir = $makefile;
                $makefile_dir =~ s{/[^/]*$}{};  # Remove filename
                $makefile_dir = '.' if $makefile_dir eq $makefile;  # No dir separator found

                for my $target (keys %completed_targets) {
                    my $target_path = $target =~ m{^/} ? $target : "$makefile_dir/$target";
                    next unless -e $target_path;
                    if (needs_rebuild($target)) {
                        delete $completed_targets{$target};
                        delete $in_progress{$target};  # Also clear from in_progress
                        $stale_targets_cache{$target} = time();
                        $stale_count++;
                        print STDERR "Auto-rescan: marked stale '$target'\n" if $ENV{SMAK_DEBUG};
                    }
                }
                if ($stale_count > 0) {
                    print STDERR "[auto-rescan] Found $stale_count stale target(s)\n";
                    dispatch_jobs();  # Try to dispatch new jobs for stale targets
                }
            }
        }

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
                    print STDERR "Shutdown requested by master.\n";
                    shutdown_workers();
                    print $master_socket "SHUTDOWN_ACK\n";
                    exit 0;

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

                } elsif ($line =~ /^SUBMIT_JOB$/) {
                    # Read job details
                    my $target = <$socket>; chomp $target if defined $target;
                    my $dir = <$socket>; chomp $dir if defined $dir;
                    my $cmd = <$socket>; chomp $cmd if defined $cmd;

                    vprint "Received job request for target: $target\n";
                    $jobs_received = 1;  # Mark that we've received at least one job

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
                    queue_target_recursive($target, $dir, $master_socket, 0);

                    vprint "Job queue now has " . scalar(@job_queue) . " jobs\n";
                    broadcast_observers("QUEUED $target");

                    # Try to dispatch
                    dispatch_jobs();

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
                    # Kill all workers
                    print STDERR "Killing all workers\n";
                    for my $worker (@workers) {
                        print $worker "SHUTDOWN\n";
                        close($worker);
                        $select->remove($worker);
                    }
                    @workers = ();
                    %worker_status = ();
                    %running_jobs = ();
                    print $master_socket "All workers killed\n";

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
                    print $master_socket "Added $count worker(s). Workers will connect asynchronously.\n";

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

                    if ($removed < $count) {
                        print $master_socket "Removed $removed worker(s) (only $removed idle workers available)\n";
                    } else {
                        print $master_socket "Removed $count worker(s)\n";
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

                } elsif ($line =~ /^RESCAN(_AUTO)?$/) {
                    # Rescan timestamps and mark stale targets
                    my $auto = defined $1;
                    my $stale_count = 0;

                    print STDERR "Rescanning file timestamps...\n" if $ENV{SMAK_DEBUG};

                    # Get makefile directory for relative path resolution
                    my $makefile_dir = $makefile;
                    $makefile_dir =~ s{/[^/]*$}{};  # Remove filename
                    $makefile_dir = '.' if $makefile_dir eq $makefile;  # No dir separator found

                    # Check all completed targets to see if they need rebuilding
                    for my $target (keys %completed_targets) {
                        # Skip if target doesn't exist anymore (was deleted)
                        my $target_path = $target =~ m{^/} ? $target : "$makefile_dir/$target";
                        next unless -e $target_path;

                        # Check if this target needs rebuilding
                        if (needs_rebuild($target)) {
                            delete $completed_targets{$target};
                            delete $in_progress{$target};  # Also clear from in_progress
                            $stale_targets_cache{$target} = time();
                            $stale_count++;
                            print STDERR "  Marked stale: $target\n" if $ENV{SMAK_DEBUG};
                        }
                    }

                    if ($auto) {
                        # Enable periodic rescanning in check_queue_state
                        $auto_rescan = 1;
                        print $master_socket "Auto-rescan enabled. Found $stale_count stale target(s).\n";
                    } else {
                        print $master_socket "Rescan complete. Marked $stale_count target(s) as stale.\n";
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
                        print $master_socket "WATCH_STARTED\n";
                        print STDERR "Watch mode enabled for client\n" if $ENV{SMAK_DEBUG};
                    } else {
                        print $master_socket "WATCH_UNAVAILABLE (no FUSE)\n";
                    }

                } elsif ($line =~ /^WATCH_STOP$/) {
                    # Disable watch mode
                    if ($watch_client && $watch_client == $master_socket) {
                        $watch_client = undef;
                        print $master_socket "WATCH_STOPPED\n";
                        print STDERR "Watch mode disabled\n" if $ENV{SMAK_DEBUG};
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
                            print STDERR "FUSE: $op $path by PID $pid\n" if $ENV{SMAK_DEBUG};

                            # Send watch notification if client is watching AND file is build-relevant
                            if ($watch_client && is_build_relevant($path)) {
                                print $watch_client "WATCH:$path\n";
                            }
                        }
                    }
                }

            } else {
                # Worker sent us something
                my $line = <$socket>;
                unless (defined $line) {
                    # Worker disconnected
                    vprint "Worker disconnected\n";
                    $select->remove($socket);
                    next;
                }
                chomp $line;

                if ($line eq 'READY') {
                    # Worker is ready for a job
                    $worker_status{$socket}{ready} |= 2;
                    vprint "Worker ready\n";
                    # Try to dispatch queued jobs
                    dispatch_jobs();

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
                    # Always print to stdout (job master's stdout is inherited from parent)
                    print $stomp_prompt,"$output\n";
                    # Also forward to attached clients if any
                    print $master_socket "OUTPUT $output\n" if $master_socket;

                } elsif ($line =~ /^ERROR (.*)$/) {
                    my $error = $1;
                    # Capture error for the task running on this worker
                    if (exists $worker_status{$socket}{task_id}) {
                        my $task_id = $worker_status{$socket}{task_id};
                        if (exists $running_jobs{$task_id}) {
                            push @{$running_jobs{$task_id}{output}}, "ERROR: $error";
                        }
                    }
                    # Always print to stderr (job master's stderr is inherited from parent)
                    print STDERR "ERROR: $error\n";
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

                                push @job_queue, {
                                    target => $subtarget,
                                    dir => $job->{dir},
                                    command => $sub_cmd,
                                };
                                print STDERR "    Queued: $subtarget\n";
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
                        my $should_verify = $looks_like_file && !$is_common_phony;

                        if (!$should_verify || verify_target_exists($job->{target}, $job->{dir})) {
                            $completed_targets{$job->{target}} = 1;
                            $in_progress{$job->{target}} = "done";
                            print STDERR "Task $task_id completed successfully: $job->{target}\n" if $ENV{SMAK_DEBUG};
                        } else {
                            # File doesn't exist even after retries - treat as failure
                            $in_progress{$job->{target}} = "failed";
                            print STDERR "Task $task_id FAILED: $job->{target} - output file not found\n";
                            $exit_code = 1;  # Mark as failed for composite target handling below
                        }
                    }

                    # Handle successful completion
                    if ($exit_code == 0 && $job->{target} && $completed_targets{$job->{target}}) {
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
                                if ($comp->{master_socket}) {
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
                        if ($job->{target} && $retry_count < 1) {  # Max 1 retry
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

                            # Re-queue the target
                            push @job_queue, {
                                target => $job->{target},
                                dir => $job->{dir},
                                command => $job->{command},
                            };

                            # Try to dispatch immediately
                            dispatch_jobs();
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
                                    if ($comp->{master_socket}) {
                                        print {$comp->{master_socket}} "JOB_COMPLETE $comp_target $exit_code\n";
                                    }
                                    delete $pending_composite{$comp_target};
                                }
                            }
                        }
                    }

                    # Report to master
                    print $master_socket "JOB_COMPLETE $job->{target} $exit_code\n" if $master_socket;
                }
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
