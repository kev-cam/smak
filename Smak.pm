package Smak;

use strict;
use warnings;
use Exporter qw(import);
use POSIX ":sys_wait_h";
use Term::ReadLine;

use Carp 'verbose'; # for debug trace
	            # print STDERR Carp::confess( @_ ) if $ENV{SMAK_DEBUG};

our $VERSION = '1.0';

our @EXPORT_OK = qw(
    parse_makefile
    build_target
    dry_run_target
    server_cli
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
    modify_rule
    modify_deps
    delete_rule
    save_modifications
    list_targets
    list_variables
    get_variable
    show_dependencies
    wait_for_jobs
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

our @job_queue;

# Hash for Makefile variables
our %MV;

# Command-line variable overrides (VAR=VALUE from command line)
our %cmd_vars;

# Track phony targets (from ninja builds)
our %phony_targets;

# Track modifications for saving
our @modifications;

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
our $job_server_socket;  # Socket to job-master
our $job_server_pid;  # PID of job-master process
our $job_server_master_port;  # Master port for reconnection

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
    $jobs = $num_jobs || 1;
}

sub start_job_server {
    use IO::Socket::INET;
    use IO::Select;
    use FindBin qw($RealBin);

    return if $jobs <= 1;  # No job server needed for sequential builds

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
    my $port_file = "/tmp/smak-jobserver-$job_server_pid.port";
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

    # Wait for workers to be ready
    my $workers_ready = <$job_server_socket>;
    chomp $workers_ready if defined $workers_ready;
    die "Job-master workers not ready\n" unless $workers_ready eq 'JOBSERVER_WORKERS_READY';

    warn "Job-master and all workers ready\n" if $ENV{SMAK_DEBUG};
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

sub submit_job {
    my ($target, $command, $dir) = @_;

    return unless $job_server_socket;  # No job server

    if ($in_progress{$target}) {
	warn "In progress: $target\n";
	return;
    }

    $in_progress{$target} = "queued";

    warn "Submitting job: $target\n" if $ENV{SMAK_DEBUG};

    # Send job to job-master via socket protocol
    print $job_server_socket "SUBMIT_JOB\n";
    print $job_server_socket "$target\n";
    print $job_server_socket "$dir\n";
    print $job_server_socket "$command\n";
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

    # Echo command unless silent
    unless ($silent_mode) {
        warn "DEBUG[" . __LINE__ . "]: About to tee_print command\n" if $ENV{SMAK_DEBUG};
        tee_print("$command\n");
        warn "DEBUG[" . __LINE__ . "]: After tee_print\n" if $ENV{SMAK_DEBUG};
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
            @args = map { s/^\s+|\s+$//gr } @args;

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

sub parse_makefile {
    my ($makefile_path) = @_;

    $makefile = $makefile_path;
    undef $default_target;

    # Reset state
    %fixed_rule = ();
    %fixed_deps = ();
    %pattern_rule = ();
    %pattern_deps = ();
    %pseudo_rule = ();
    %pseudo_deps = ();
    %MV = ();
    @modifications = ();

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

    my @current_targets;  # Array to handle multiple targets (e.g., "target1 target2:")
    my $current_rule = '';
    my $current_type;  # 'fixed', 'pattern', or 'pseudo'

    my $save_current_rule = sub {
        return unless @current_targets;

        # Save rule for all targets in the current rule
        for my $target (@current_targets) {
            my $key = "$makefile\t$target";
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
                    warn "Warning: included file not found: $include_path\n";
                } elsif ($ENV{SMAK_DEBUG}) {
                    print STDERR "DEBUG: optional include not found (ignored): $include_path\n";
                }
            }
            next;
        }

        # Variable assignment
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $value) = ($1, $2);
            # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
            $value = transform_make_vars($value);
            $MV{$var} = $value;
            next;
        }

        # Rule definition (target: dependencies)
        if ($line =~ /^([^:]+):\s*(.*)$/) {
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

            # Store dependencies for all targets
            for my $target (@targets) {
                my $key = "$makefile\t$target";
                my $type = classify_target($target);

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

                # Set default target to first non-pseudo target (like gmake)
                if (!defined $default_target && $type ne 'pseudo') {
                    $default_target = $target;
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
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $value) = ($1, $2);
            $value = transform_make_vars($value);
            $MV{$var} = $value;
            next;
        }

        # Rule definition (included files might have rules too)
        if ($line =~ /^([^:]+):\s*(.*)$/) {
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
}

sub get_default_target {
    return $default_target;
}

# Resolve a file through vpath directories
sub resolve_vpath {
    my ($file, $dir) = @_;

    # Check if file exists in current directory first
    my $file_path = $file =~ m{^/} ? $file : "$dir/$file";
    if (-e $file_path) {
        print STDERR "DEBUG vpath: '$file' found in current directory\n" if $ENV{SMAK_DEBUG};
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

    # Set default target
    if (!defined $default_target) {
        $default_target = $output;
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

sub get_all_ninja_outputs {
    # Collect all output files from parsed ninja file
    my @outputs;
    my %seen;

    # Collect from fixed_deps (most common for ninja builds)
    for my $key (keys %fixed_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        # Skip special/meta targets
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /^\.DEFAULT_GOAL/;
        # Skip targets that look like variables or directives
        next if $target =~ /^\$/;
        # Skip targets with spaces (multi-file targets from meson)
        next if $target =~ /\s/;
        # Skip paths that point outside the build directory
        next if $target =~ /^\.\./;
        # Skip the ninja file itself and meson internals
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
        # Add if not seen before
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pattern_deps (rare for ninja, but check anyway)
    for my $key (keys %pattern_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /\s/;
        next if $target =~ /^\.\./;
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pseudo_deps
    for my $key (keys %pseudo_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /\s/;
        next if $target =~ /^\.\./;
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
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
    my ($target) = @_;

    # If target doesn't exist, it needs to be built
    return 1 unless -e $target;

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

    # Check if any dependency is newer than target
    for my $dep (@deps) {
        # Skip .PHONY and other special targets
        next if $dep =~ /^\.PHONY$/;

        # If dependency doesn't exist, target needs rebuild
        return 1 unless -e $dep;

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

    # Skip RCS/SCCS implicit rule patterns (these create infinite loops)
    # Make's built-in rules try: RCS/file,v, SCCS/s.file, etc.
    if ($target =~ m{(?:^|/)(?:RCS|SCCS)/} ||
        $target =~ /^s\./ ||
        $target =~ /,v+$/) {
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

    # Debug: show what we're building
    warn "DEBUG[" . __LINE__ . "]: Building target '$target' (depth=$depth, makefile=$makefile)\n" if $ENV{SMAK_DEBUG};

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

    # Debug: show dependencies and rule status
    if ($ENV{SMAK_DEBUG}) {
        if (@deps) {
            warn "DEBUG[" . __LINE__ . "]:   Dependencies: " . join(', ', @deps) . "\n";
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
            return;
        }
        warn "DEBUG[" . __LINE__ . "]:   Target needs rebuilding\n" if $ENV{SMAK_DEBUG};
    }

    # Recursively build dependencies
    # In parallel mode, skip this - let job-master handle dependency expansion
    unless ($job_server_socket) {
        warn "DEBUG[" . __LINE__ . "]:   Building " . scalar(@deps) . " dependencies...\n" if $ENV{SMAK_DEBUG};
        for my $dep (@deps) {
            warn "DEBUG[" . __LINE__ . "]:     Building dependency: $dep\n" if $ENV{SMAK_DEBUG};
            build_target($dep, $visited, $depth + 1);
        }
        warn "DEBUG[" . __LINE__ . "]:   Finished building dependencies\n" if $ENV{SMAK_DEBUG};
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
            if ($job_server_socket) {
                warn "DEBUG[" . __LINE__ . "]:     Using job server\n" if $ENV{SMAK_DEBUG};
                # Parallel mode - submit to job server
                submit_job($target, $cmd_line, $cwd);
            } else {
                warn "DEBUG[" . __LINE__ . "]:     Sequential execution\n" if $ENV{SMAK_DEBUG};
                # Sequential mode - execute directly
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

sub execute_script {
    my ($filename) = @_;

    open(my $script_fh, '<', $filename) or die "Cannot open script file '$filename': $!\n";

    while (my $line = <$script_fh>) {
        chomp $line;

        # Skip empty lines and comments
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;

        # Process commands (simplified version of interactive_debug command processing)
        if ($line =~ /^\s*add-rule\s+(.+?)\s*:\s*(.+?)\s*:\s*(.+)$/i) {
            my ($target, $deps, $rule_text) = ($1, $2, $3);

            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;

            # Ensure each line starts with a tab (Makefile requirement)
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

            add_rule($target, $deps, $rule_text);
        }
        elsif ($line =~ /^\s*mod-rule\s+(.+?)\s*:\s*(.+)$/i) {
            my ($target, $rule_text) = ($1, $2);

            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;

            # Ensure each line starts with a tab
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

            modify_rule($target, $rule_text);
        }
        elsif ($line =~ /^\s*mod-deps\s+(.+?)\s*:\s*(.+)$/i) {
            my ($target, $deps) = ($1, $2);
            modify_deps($target, $deps);
        }
        elsif ($line =~ /^\s*del-rule\s+(.+)$/i) {
            my $target = $1;
            delete_rule($target);
        }
        else {
            warn "Unknown command in script: $line\n";
        }
    }

    close($script_fh);
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

sub server_cli
{
    my ($jobserver_pid,$socket,$prompt,$term,$selected_js) = @_;
    # Enter CLI mode
    use Term::ReadLine;
    
    # Set up signal handler for graceful exit
    my $exit_requested = 0;
    local $SIG{INT} = sub { $exit_requested = 1; };
    
    my $line;
    while (!$exit_requested && defined($line = $term->readline($prompt))) {
	chomp $line;
	$line =~ s/^\s+|\s+$//g;
	
	next if $line eq '';
	$term->addhistory($line) if $line =~ /\S/;
	
	my @words = split(/\s+/, $line);
	my $cmd = shift @words;

	if ($cmd eq 'quit' || $cmd eq 'exit' || $cmd eq 'q') {
	    print "Shutting down job server...\n";
	    print $socket "SHUTDOWN\n";
	    my $ack = <$socket>;
	    last;
	    
	} elsif ($cmd eq 'detach') {
	    print "Detaching from job server...\n";
	    last;
	    
	} elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
	    print <<'HELP';
Available commands:
  build <target>      Build the specified target
  tasks, t            List pending and active tasks
  status              Show job server status
  progress            Show job status
  vpath <file>        Test vpath resolution for a file
  files, f            List tracked file modifications (FUSE)
  list [pattern]      List all targets (optionally matching pattern)
  vars [pattern]      Show all variables (optionally matching pattern)
  deps <target>       Show dependencies for target
  kill                Kill all workers
  restart [N]         Restart workers (optionally specify count)
  detach              Detach from job server (leave it running)
  help, h, ?          Show this help
  quit, exit, q       Shut down job server and exit

Keyboard shortcuts:
  Ctrl-C              Detach from job server

HELP

	} elsif ($cmd eq 'build' || $cmd eq 'b') {
	    if (@words == 0) {
		print "Usage: build <target>\n";
	    } else {
		for my $target (@words) {
		    print $socket "SUBMIT_JOB\n";
		    print $socket "$target\n";
		    print $socket ".\n";
		    print $socket "cd . && make $target\n";
		    
		    # Wait for completion with interruptible reads
		    my $select = IO::Select->new($socket);
		    my $job_done = 0;
		    while (!$exit_requested && !$job_done) {
			if ($select->can_read(0.1)) {
			    my $response = <$socket>;
			    last unless defined $response;
			    chomp $response;
			    if ($response =~ /^OUTPUT (.*)$/) {
				print "$1\n";
			    } elsif ($response =~ /^ERROR (.*)$/) {
				print "❌ ERROR: $1\n";
			    } elsif ($response =~ /^WARN (.*)$/) {
				print "⚠️  WARN: $1\n";
			    } elsif ($response =~ /^JOB_COMPLETE (.+?) (\d+)$/) {
				my ($completed_target, $exit_code) = ($1, $2);
				if ($exit_code == 0) {
				    print "✓ Build succeeded: $completed_target\n";
				} else {
				    print "✗ Build failed: $completed_target (exit code $exit_code)\n";
				}
				$job_done = 1;
			    }
			}
		    }
		    
		    if ($exit_requested) {
			print "\nBuild interrupted.\n";
			last;
		    }
		}
	    }
	    
	} elsif ($cmd eq 'progress') {
	    my $op = join(' ',@words);
	    print $socket "IN_PROGRESS $op\n";
	    while (my $response = <$socket>) {
		chomp $response;
		last if $response eq 'END_PROGRESS';
		print "$response\n";
	    }

	} elsif ($cmd eq 'vpath') {
	    if (@words == 0) {
		print "Usage: vpath <file>\n";
	    } else {
		my $file = $words[0];
		use Cwd 'getcwd';
		my $cwd = getcwd();

		# Show vpath patterns
		print "Available vpath patterns:\n";
		if (keys %vpath) {
		    for my $p (keys %vpath) {
			print "  '$p' => [" . join(", ", @{$vpath{$p}}) . "]\n";
		    }
		} else {
		    print "  (none)\n";
		}

		# Test resolution
		print "\nResolving '$file':\n";
		my $resolved = resolve_vpath($file, $cwd);
		if ($resolved ne $file) {
		    print "  ✓ Resolved to: $resolved\n";
		} else {
		    print "  ✗ Not resolved (returned as-is)\n";
		}
	    }

	} elsif ($cmd eq 'tasks' || $cmd eq 't') {
	    print $socket "LIST_TASKS\n";
	    while (my $response = <$socket>) {
		chomp $response;
		last if $response eq 'TASKS_END';
		print "$response\n";
	    }
	    
	} elsif ($cmd eq 'status' || $cmd eq 'st') {
	    print "Our PID: $$\n";
	    print "Job server PID: $jobserver_pid $socket\n";
	    if (defined $selected_js->{workers}) {
		print "Workers: $selected_js->{workers}\n";
	    }
	    print "Working directory: $selected_js->{cwd}\n" if $selected_js->{cwd};
	    
	} elsif ($cmd eq 'kill') {
	    print "Killing all workers...\n";
	    print $socket "KILL_WORKERS\n";
	    my $response = <$socket>;
            chomp $response if $response;
	    print "$response\n" if $response;
	    
	} elsif ($cmd eq 'restart') {
	    my $count = @words > 0 ? $words[0] : $selected_js->{workers};
	    print "Restarting workers ($count workers)...\n";
	    print $socket "RESTART_WORKERS $count\n";
	    my $response = <$socket>;
	    chomp $response if $response;
	    print "$response\n" if $response;
	    
	} elsif ($cmd eq 'files' || $cmd eq 'f') {
	    print $socket "LIST_FILES\n";
	    while (my $response = <$socket>) {
		chomp $response;
		last if $response eq 'FILES_END';
		print "$response\n";
	    }
	    
	} elsif ($cmd eq 'list' || $cmd eq 'ls' || $cmd eq 'l') {
	    print "list command not yet implemented in attach mode\n";
	    
	} elsif ($cmd eq 'vars' || $cmd eq 'v') {
	    print "vars command not yet implemented in attach mode\n";
	    
	} elsif ($cmd eq 'deps' || $cmd eq 'd') {
	    print "deps command not yet implemented in attach mode\n";
	    
	} else {
	    print "Unknown command: $cmd\n";
	    print "Type 'help' for available commands.\n";
	}
	
	# Check for exit request from Ctrl-C
	if ($exit_requested) {
	    last;
	}
    }

    if ($exit_requested || !defined($line)) {
	print "\nDetaching from job server.\n";
	print "Job server still running (PID $jobserver_pid).\n";
	print "To reattach: smak-attach\n";
    }
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
            if (@deps) {
                print "Dependencies:\n";
                foreach my $dep (@deps) {
                    print "  $dep\n";
                }
            } else {
                print "No dependencies\n";
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

    our @workers;
    our %worker_status;  # socket => {ready => 0/1, task_id => N}
    my $worker_script = "$bin_dir/smak-worker";
    die "Worker script not found: $worker_script\n" unless -x $worker_script;

    # Create socket server for master connections
    my $master_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => 1,
        Reuse     => 1,
    ) or die "Cannot create master server: $!\n";

    my $master_port = $master_server->sockport();
    print STDERR "Job-master master server on port $master_port\n";

    # Create socket server for workers
    my $worker_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => $num_workers,
        Reuse     => 1,
    ) or die "Cannot create worker server: $!\n";

    my $worker_port = $worker_server->sockport();
    print STDERR "Job-master worker server on port $worker_port\n";

    # Create socket server for observers (monitoring/attach)
    my $observer_server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,  # Let OS assign port
        Proto     => 'tcp',
        Listen    => 5,  # Allow multiple observers
        Reuse     => 1,
    ) or die "Cannot create observer server: $!\n";

    my $observer_port = $observer_server->sockport();
    print STDERR "Job-master observer server on port $observer_port\n";

    # Write ports to file for smak-attach to find
    open(my $port_fh, '>', "/tmp/smak-jobserver-$$.port") or warn "Cannot write port file: $!\n";
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

    our %worker_env;

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

        # Read /proc/mounts to find FUSE filesystems
        open(my $mounts, '<', '/proc/mounts') or return undef;
        my $fuse_pid;
        while (my $line = <$mounts>) {
            # Look for fuse.sshfs or similar
            if ($line =~ /^(\S+)\s+(\S+)\s+fuse\.(\S+)/) {
                my ($dev, $mountpoint, $fstype) = ($1, $2, $3);
                # Check if our CWD is under this mount
                if ($cwd =~ /^\Q$mountpoint\E/) {
                    print STDERR "Detected FUSE filesystem: $fstype at $mountpoint\n";
                    # Try to find the FUSE process - look for sshfs process
                    my $ps_output = `ps aux | grep -E '(sshfs|smak-fuse)' | grep -v grep`;
                    for my $ps_line (split /\n/, $ps_output) {
                        if ($ps_line =~ /^\S+\s+(\d+).*$mountpoint/) {
                            $fuse_pid = $1;
                            last;
                        }
                    }
                    last if $fuse_pid;
                }
            }
        }
        close($mounts);

        return undef unless $fuse_pid;

        # Find the listening port using lsof
        my $lsof_output = `lsof -Pan -p $fuse_pid -i TCP -s TCP:LISTEN 2>/dev/null`;
        for my $line (split /\n/, $lsof_output) {
            if ($line =~ /:(\d+)\s+\(LISTEN\)/) {
                my $port = $1;
                print STDERR "Found FUSE monitor on port $port (PID $fuse_pid)\n";
                return $port;
            }
        }

        return undef;
    }

    if (my $fuse_port = detect_fuse_monitor()) {
        # Connect to FUSE monitor
        $fuse_socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $fuse_port,
            Proto    => 'tcp',
            Timeout  => 5,
        );
        if ($fuse_socket) {
            $fuse_socket->autoflush(1);
            print STDERR "Connected to FUSE monitor\n";
        } else {
            print STDERR "Failed to connect to FUSE monitor: $!\n";
        }
    } else {
        print STDERR "No FUSE filesystem monitor detected\n";
    }

    # Wait for initial master connection
    print STDERR "Waiting for master connection...\n";
    our $master_socket = $master_server->accept();
    die "Failed to accept master connection\n" unless $master_socket;
    $master_socket->autoflush(1);
    print STDERR "Master connected\n";

    # Receive environment from master
    while (my $line = <$master_socket>) {
        chomp $line;
        last if $line eq 'ENV_END';
        if ($line =~ /^ENV (\w+)=(.*)$/) {
            $worker_env{$1} = $2;
        }
    }
    print STDERR "Job-master received environment\n";

    # Spawn workers
    for (my $i = 0; $i < $num_workers; $i++) {
        my $pid = fork();
        die "Cannot fork worker: $!\n" unless defined $pid;

        if ($pid == 0) {
            # Child - exec worker
            exec($worker_script, "127.0.0.1:$worker_port");
            die "Failed to exec worker: $!\n";
        }
        print STDERR "Spawned worker $i (PID $pid)\n";
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
                        print STDERR "Worker connected ($workers_connected/$num_workers)\n";

                        # Send environment
			send_env($worker);

                        # Now worker is ready to receive tasks
                        $worker_status{$worker}{ready} = 1;
                        print STDERR "Worker $workers_connected environment sent, now ready\n";
                    }
                }
            }
        }
    }

    print STDERR "All workers ready. Job-master entering listen loop.\n";
    print $master_socket "JOBSERVER_WORKERS_READY\n";

    # Job queue and dependency tracking - use 'our' to avoid closure warnings
    our @job_queue;  # Queue of jobs to dispatch
    our %running_jobs;  # task_id => {target, worker, dir, command, started}
    our %completed_targets;  # target => 1 (successfully built targets)
    our %pending_composite;  # composite targets waiting for dependencies
                            # target => {deps => [list], master_socket => socket}
    our $next_task_id = 1;

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

    # Recursively queue a target and all its dependencies
    sub queue_target_recursive {
        my ($target, $dir, $msocket) = @_;
        $msocket ||= $master_socket;  # Use provided or fall back to global

        # Skip if already handled
        return if is_target_pending($target);

        # Lookup dependencies
        my $key = "$makefile\t$target";
        my @deps;
        my $rule = '';
        my $stem = '';

        if (exists $fixed_deps{$key}) {
            @deps = @{$fixed_deps{$key} || []};
            $rule = $fixed_rule{$key} || '';
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
                queue_target_recursive($single_dep, $dir, $msocket);
            }
        }

        # Now queue this target if it has a command
        if ($rule && $rule =~ /\S/) {
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
            print STDERR "Queued target: $target\n";
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
                # Track pending dependencies
                my @pending_deps = grep { !exists $completed_targets{$_} } @deps;
                if (@pending_deps) {
                    $in_progress{$target} = "pending";
                    $pending_composite{$target} = {
                        deps => \@pending_deps,
                        master_socket => $msocket,
                    };
                    print STDERR "Composite target '$target' waiting for " . scalar(@pending_deps) . " dependencies\n";
                    print STDERR "  Pending: " . join(", ", @pending_deps) . "\n" if $ENV{SMAK_DEBUG};
                } else {
                    # All deps already complete
                    $completed_targets{$target} = 1;
                    $in_progress{$target} = "done";
                    print $msocket "JOB_COMPLETE $target 0\n" if $msocket;
                }
            }
        } else {
            # No command and no deps - just mark complete
            $completed_targets{$target} = 1;
            $in_progress{$target} = "done";
        }
    }

    sub dispatch_jobs {
	my ($do,$block) = @_;
	my $j = 0;
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
                my $job = $job_queue[$i];
                my $target = $job->{target};

                # Check if this job's dependencies are satisfied
                my $key = "$makefile\t$target";
                my @deps;
                if (exists $fixed_deps{$key}) {
                    @deps = @{$fixed_deps{$key} || []};
                } elsif (exists $pattern_deps{$key}) {
                    @deps = @{$pattern_deps{$key} || []};
                } elsif (exists $pseudo_deps{$key}) {
                    @deps = @{$pseudo_deps{$key} || []};
                }

                # Check if all dependencies are completed
                my $deps_satisfied = 1;
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
                        unless ($completed_targets{$single_dep} || -e $dep_path) {
                            $deps_satisfied = 0;
                            print STDERR "Job '$target' waiting for dependency '$single_dep' (checked: $dep_path)\n" if $ENV{SMAK_DEBUG};
                            last;
                        }
                    }

                    last unless $deps_satisfied;
                }

                if ($deps_satisfied) {
                    $job_index = $i;
                    last;
                }
            }

            # No job with satisfied dependencies found
            if ($job_index < 0) {
                if ($ENV{SMAK_DEBUG}) {
                    print STDERR "No jobs with satisfied dependencies\n";
                    print STDERR "Job queue has " . scalar(@job_queue) . " jobs:\n";
                    my $max_show = @job_queue < 10 ? $#job_queue : 9;
                    for my $i (0 .. $max_show) {
                        my $job = $job_queue[$i];
                        print STDERR "  [$i] $job->{target}\n";
                    }
                    print STDERR "  ...\n" if @job_queue > 10;
                }
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
            };
	    
	    $j++;

	    $in_progress{$job->{target}} = $ready_worker;
	    
            # Send task to worker
            print $ready_worker "TASK $task_id\n";
            print $ready_worker "DIR $job->{dir}\n";
            print $ready_worker "CMD $job->{command}\n";

            print STDERR "Dispatched task $task_id to worker\n";
            broadcast_observers("DISPATCHED $task_id $job->{target}");

            if ($block) {
		wait_for_worker_done($ready_worker);
	    }

	    if (defined $do) {
		last if (1 == $do); # done for now
	    }
        }

	return $j;
    }

    # Main event loop
    my $last_consistency_check = time();
    while (1) {
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
                    print STDERR "Consistency check: processing pending message: $line\n";

                    # Process the message inline (same logic as main event loop)
                    if ($line eq 'READY') {
                        $worker_status{$worker}{ready} |= 2;
                        print STDERR "Worker ready\n";
                        dispatch_jobs();

                    } elsif ($line =~ /^TASK_START (\d+)$/) {
                        my $task_id = $1;
                        if (exists $running_jobs{$task_id}) {
                            $running_jobs{$task_id}{started} = 1;
                        }
                        print STDERR "Task $task_id started\n";

                    } elsif ($line =~ /^TASK_END (\d+) (\d+)$/) {
                        my ($task_id, $exit_code) = ($1, $2);
                        my $job = $running_jobs{$task_id};

                        delete $running_jobs{$task_id};

                        if ($exit_code == 0 && $job->{target}) {
                            $completed_targets{$job->{target}} = 1;
                            $in_progress{$job->{target}} = "done";
                            print STDERR "Task $task_id completed successfully: $job->{target}\n";

                            # Check composite targets
                            for my $comp_target (keys %pending_composite) {
                                my $comp = $pending_composite{$comp_target};
                                $comp->{deps} = [grep { $_ ne $job->{target} } @{$comp->{deps}}];

                                if (@{$comp->{deps}} == 0) {
                                    print STDERR "All dependencies complete for composite target '$comp_target'\n";
                                    $completed_targets{$comp_target} = 1;
                                    $in_progress{$comp_target} = "done";
                                    if ($comp->{master_socket}) {
                                        print {$comp->{master_socket}} "JOB_COMPLETE $comp_target 0\n";
                                    }
                                    delete $pending_composite{$comp_target};
                                }
                            }
                        } else {
                            if ($job->{target}) {
                                $in_progress{$job->{target}} = "failed";
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
                }

            } elsif (defined $master_socket && $socket == $master_socket) {
                # Master sent us something
                my $line = <$socket>;
                unless (defined $line) {
                    print STDERR "Master disconnected. Waiting for reconnection...\n";
                    $select->remove($master_socket);
                    close($master_socket);
                    $master_socket = undef;
                    next;
                }
                chomp $line;

                if ($line eq 'SHUTDOWN') {
                    print STDERR "Shutdown requested by master.\n";
                    shutdown_workers();
                    print $master_socket "SHUTDOWN_ACK\n";
                    exit 0;
		    
                } elsif ($line =~ /^SUBMIT_JOB$/) {
                    # Read job details
                    my $target = <$socket>; chomp $target if defined $target;
                    my $dir = <$socket>; chomp $dir if defined $dir;
                    my $cmd = <$socket>; chomp $cmd if defined $cmd;

                    print STDERR "Received job request for target: $target\n";

                    # Lookup dependencies using the key format "makefile\ttarget"
                    my $key = "$makefile\t$target";
                    my @deps;
                    my $rule = '';

                    # Find target in fixed, pattern, or pseudo rules
                    if (exists $fixed_deps{$key}) {
                        @deps = @{$fixed_deps{$key} || []};
                        $rule = $fixed_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in fixed_deps\n";
                    } elsif (exists $pattern_deps{$key}) {
                        @deps = @{$pattern_deps{$key} || []};
                        $rule = $pattern_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in pattern_deps\n";
                    } elsif (exists $pseudo_deps{$key}) {
                        @deps = @{$pseudo_deps{$key} || []};
                        $rule = $pseudo_rule{$key} || '';
                        print STDERR "DEBUG: Found '$target' in pseudo_deps\n";
                    } else {
                        print STDERR "DEBUG: '$target' NOT found in any dependency tables\n";
                    }

                    print STDERR "DEBUG: Target '$target' has " . scalar(@deps) . " dependencies\n";
                    print STDERR "DEBUG: Dependencies: " . join(', ', @deps) . "\n" if @deps;

                    # Use recursive queuing to handle dependencies
                    queue_target_recursive($target, $dir, $master_socket);

                    print STDERR "Job queue now has " . scalar(@job_queue) . " jobs\n";
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
			} elsif ('done' eq $status && $clear) {
			    delete $in_progress{$target};
			}

			print $master_socket "$target\t$message\n";
		    }
		    print $master_socket "END_PROGRESS\n";
		    
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
                            exec($worker_script, "127.0.0.1:$worker_port");
                            die "Failed to exec worker: $!\n";
                        }
                    }
                    print $master_socket "Restarting $new_count workers...\n";

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
                        print STDERR "Worker connected during runtime\n";

                        # Send environment to new worker
                        print $worker "ENV_START\n";
                        for my $key (keys %worker_env) {
                            print $worker "ENV $key=$worker_env{$key}\n";
                        }
                        print $worker "ENV_END\n";

                        # Now worker is ready
                        $worker_status{$worker}{ready} = 1;
                        print STDERR "Runtime worker environment sent, now ready\n";
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
                    print STDERR "FUSE monitor disconnected\n";
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
                        my ($inode, $path) = ($arg1, $arg2);
                        $inode_cache{$inode} = $path;
                        delete $pending_path_requests{$inode};

                        # Track modification
                        $file_modifications{$path} ||= {workers => [], last_op => time()};
                        print STDERR "FUSE: $path (inode $inode)\n";

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
                            print STDERR "FUSE: $op $path by PID $pid\n";
                        }
                    }
                }

            } else {
                # Worker sent us something
                my $line = <$socket>;
                unless (defined $line) {
                    # Worker disconnected
                    print STDERR "Worker disconnected\n";
                    $select->remove($socket);
                    next;
                }
                chomp $line;

                if ($line eq 'READY') {
                    # Worker is ready for a job
                    $worker_status{$socket}{ready} |= 2;
                    print STDERR "Worker ready\n";
                    # Try to dispatch queued jobs
                    dispatch_jobs();

                } elsif ($line =~ /^TASK_START (\d+)$/) {
                    my $task_id = $1;
                    # Mark task as actually running (not just dispatched)
                    if (exists $running_jobs{$task_id}) {
                        $running_jobs{$task_id}{started} = 1;
                    }
                    print STDERR "Task $task_id started\n";

                } elsif ($line =~ /^OUTPUT (.*)$/) {
                    my $output = $1;
                    # Forward to master
                    print $master_socket "OUTPUT $output\n" if $master_socket;

                } elsif ($line =~ /^ERROR (.*)$/) {
                    my $error = $1;
                    # Forward error to master
                    print $master_socket "ERROR $error\n" if $master_socket;

                } elsif ($line =~ /^WARN (.*)$/) {
                    my $warning = $1;
                    # Forward warning to master
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
                        print STDERR "Worker returning task $task_id ($job->{target}): $reason\n";

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

                        print STDERR "Worker decomposing task $task_id ($target)\n";

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
                        $completed_targets{$job->{target}} = 1;
                        $in_progress{$job->{target}} = "done";
                        print STDERR "Task $task_id completed successfully: $job->{target}\n";

                        # Check if any pending composite targets can now complete
                        for my $comp_target (keys %pending_composite) {
                            my $comp = $pending_composite{$comp_target};
                            # Remove this completed target from pending deps
                            $comp->{deps} = [grep { $_ ne $job->{target} } @{$comp->{deps}}];

                            # If all dependencies done, complete the composite target
                            if (@{$comp->{deps}} == 0) {
                                print STDERR "All dependencies complete for composite target '$comp_target'\n";
                                $completed_targets{$comp_target} = 1;
                                $in_progress{$comp_target} = "done";
                                if ($comp->{master_socket}) {
                                    print {$comp->{master_socket}} "JOB_COMPLETE $comp_target 0\n";
                                }
                                delete $pending_composite{$comp_target};
                            }
                        }
                    } else {
                        if ($job->{target}) {
                            $in_progress{$job->{target}} = "failed";
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
    
    open(TREE,"pstree -p $$ 2>&1 |");
    while (defined(my $line = <TREE>)) {
	my $p=0;
	my @pid;
	while ($line =~ s/\((\d+)\)//) {
	    if ($$ != $1) { $pid[$p++] = $1; }
	}
	for $p (@pid) {
	    my $msg = "process: $p";
	    if (open(CMD,"tr \\0 ' ' </proc/$p/cmdline 2>&1 |")) {
		my $cmd = <CMD>;
		if (defined $cmd) {
		    $msg = " command: $cmd [$p]";
		}
	    }
	    warn "Waiting for$msg\n" if $ENV{SMAK_DEBUG};
	    my $s = waitpid($p,0);
	    if (0 != $s) {
		$sts = $s;
	    }
	}
    }

    return $sts;
}

$SIG{USR1} = sub { interactive_debug };
$SIG{USR2} = sub { print STDERR Carp::confess( @_ ) };

1;  # Return true to indicate successful module load
