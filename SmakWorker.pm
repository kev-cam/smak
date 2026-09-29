package SmakWorker;
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use POSIX qw(:sys_wait_h);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy move);
use Cwd;
use IO::Select;
use Time::HiRes qw(sleep);

# Analyze command failures and determine if they're acceptable
sub is_acceptable_failure {
    my ($command, $exit_code, $dir) = @_;

    return 0 if $exit_code == 0;  # Not a failure

    # mkdir: if directory exists after command, treat as success
    if ($command =~ /^\s*mkdir\s+(.+)/) {
        my $target_dir = $1;
        $target_dir =~ s/\s+$//;  # Trim trailing whitespace

        # Check if directory exists
        my $full_path = "$dir/$target_dir";
        $full_path =~ s{/+}{/}g;  # Normalize path

        if (-d $full_path) {
            print STDERR "mkdir failed but directory '$target_dir' exists, treating as success\n";
            return 1;
        }
    }

    return 0;
}

# Determine if an error looks like a transient failure worth retrying
sub is_transient_failure {
    my ($output) = @_;

    # Compiler errors about missing input files (race condition)
    return 1 if $output =~ /fatal error:.*No such file or directory/i;
    return 1 if $output =~ /error:.*No such file or directory/i;
    return 1 if $output =~ /cannot open.*No such file or directory/i;

    # Linker errors about missing object files
    return 1 if $output =~ /cannot find.*\.o\b/i;

    return 0;
}

# Parse a command to see if it can be executed directly without shell
# Returns list of words if direct exec is possible, empty list if shell is needed
sub parse_simple_command {
    my ($cmd) = @_;

    # Strip trailing 2>&1 - we handle stderr redirect in fork
    $cmd =~ s/\s+2>&1\s*$//;

    # Shell metacharacters that require shell interpretation
    return () if $cmd =~ /\|/;                  # Pipes
    return () if $cmd =~ /`/;                   # Backticks
    return () if $cmd =~ /\$/;                  # Variables
    return () if $cmd =~ /;/;                   # Semicolons
    return () if $cmd =~ /[<>](?!&)/;           # Redirections (but not >&)
    return () if $cmd =~ /(?<![\\])[*?]/;       # Unescaped glob wildcards
    return () if $cmd =~ /\{[^}]*,[^}]*\}/;     # Brace expansion {a,b}
    return () if $cmd =~ /\[\[/;                # Bash conditionals
    return () if $cmd =~ /[&]{2}|[|]{2}/;       # && or ||
    return () if $cmd =~ /^\s*\(/;              # Subshell
    return () if $cmd =~ /^\s*[A-Za-z_]\w*=/;   # VAR=value cmd (redis: PROG_SUFFIX='' scripts/build.sh)
    return () if $cmd =~ /(?:^|\s)#/;           # shell comment (redis lua: `$(AR) $@ ...	# DLL ...`)

    # Shell keywords that require shell interpretation
    # These are control flow keywords that can't be exec'd directly
    return () if $cmd =~ /^\s*(if|then|else|elif|fi|while|do|done|for|case|esac|until|select|function)\b/;
    return () if $cmd =~ /\b(then|else|elif|fi|do|done|esac)\b/;  # Also inside the command

    # Shell builtins that cannot be exec'd directly (they're built into the shell, not executables)
    return () if $cmd =~ /^\s*(cd|export|source|\.)\b/;

    # Parse into words, handling quotes
    my @words;
    my $current = '';
    my $quoted = 0;   # the word had quotes: '' is an (empty) argument
    my $in_single = 0;
    my $in_double = 0;
    my $escaped = 0;

    for my $char (split //, $cmd) {
        if ($escaped) {
            $current .= $char;
            $escaped = 0;
        } elsif ($char eq '\\' && !$in_single) {
            $escaped = 1;
        } elsif ($char eq "'" && !$in_double) {
            $in_single = !$in_single;
            $quoted = 1;
        } elsif ($char eq '"' && !$in_single) {
            $in_double = !$in_double;
            $quoted = 1;
        } elsif ($char =~ /\s/ && !$in_single && !$in_double) {
            push @words, $current if $current ne '' || $quoted;
            $current = '';
            $quoted = 0;
        } else {
            $current .= $char;
        }
    }
    push @words, $current if $current ne '' || $quoted;

    # If quotes weren't balanced, fall back to shell
    return () if $in_single || $in_double;

    return @words if @words > 0;
    return ();
}

# Execute a command, using direct exec if possible, otherwise shell
# Returns ($pid, $filehandle, $is_direct)
sub execute_command_direct {
    my ($cmd) = @_;

    my @words = parse_simple_command($cmd);

    if (@words) {
        # Direct execution possible
        my $program = $words[0];
        my @args = @words;

        # Create pipe for stdout/stderr
        pipe(my $read_fh, my $write_fh) or return (undef, undef, 0);

        my $pid = fork();
        if (!defined $pid) {
            close($read_fh);
            close($write_fh);
            return (undef, undef, 0);
        }

        if ($pid == 0) {
            # Child process
            close($read_fh);

            # Redirect stdout and stderr to pipe
            open(STDOUT, '>&', $write_fh) or exit(127);
            open(STDERR, '>&', $write_fh) or exit(127);
            close($write_fh);

            # Execute the command (suppress Perl's "unlikely to reach" warning)
            { no warnings 'exec'; exec { $program } @args; }
            # If exec fails (this code only runs if exec fails)
            print STDERR "Cannot exec '$program': $!\n";
            exit(127);
        }

        # Parent process
        close($write_fh);
        return ($pid, $read_fh, 1);  # 1 = is_direct
    } else {
        # Need shell. Run /bin/sh explicitly: given "cmd 2>&1", Perl handles
        # the 2>&1 itself and, seeing no metacharacter it knows (# is not
        # one), execs the words directly (redis lua: `ar rc x.a *.o	# DLL`
        # passed "#", "DLL", ... to ar).
        my $pid = open(my $cmd_fh, '-|', '/bin/sh', '-c', "{ $cmd\n} 2>&1");
        return ($pid, $cmd_fh, 0) if $pid;  # 0 = is_shell
        return (undef, undef, 0);
    }
}

# Execute a built-in command
# Returns exit code, or undef if not a built-in
sub execute_builtin {
    my ($cmd, $socket) = @_;

    # Strip @ and - prefixes
    my $clean_cmd = $cmd;
    $clean_cmd =~ s/^[@+-]+//;
    $clean_cmd =~ s/^\s+|\s+$//g;

    # Only plain words are handled here; anything the shell would interpret
    # (operators, substitutions, escapes, quoting) goes to the shell.  A
    # builtin that half-understood "mkdir -p src && if ..." created a
    # directory named "src && if test -x ." and skipped the rest.
    return undef if $clean_cmd =~ /[;&|<>`\$(){}\\~#\n]/;
    if ($clean_cmd =~ /^echo\s+(.*)$/s) {
        my $text = $1;
        return undef if $text =~ /^-/;
        if ($text =~ /["']/) {
            return undef unless $text =~ /^"([^"]*)"$/ || $text =~ /^'([^']*)'$/;
            $text = $1;
        } else {
            return undef if $text =~ /[*?\[\]]/;
            $text = join(' ', split(/\s+/, $text));
        }
        print $socket "OUTPUT $text\n" if $socket;
        return 0;
    }
    return undef if $clean_cmd =~ /["']/;
    my ($prog, @args) = split(/\s+/, $clean_cmd);
    return undef unless defined $prog;

    if ($prog eq 'rm') {
        my ($force, $recursive) = (0, 0);
        my @files;
        for my $a (@args) {
            if ($a =~ /^-([rRf]+)$/) {
                my $flags = $1;   # (a successful match below resets $1)
                $force = 1 if $flags =~ /f/;
                $recursive = 1 if $flags =~ /[rR]/;
            } elsif ($a =~ /^-/) {
                return undef;
            } elsif ($a =~ /[*?\[]/) {
                push @files, glob($a);
            } else {
                push @files, $a;
            }
        }
        my $rc = 0;
        for my $f (@files) {
            if (-d $f && !-l $f) {
                if ($recursive) { remove_tree($f); }
                else { print $socket "OUTPUT rm: cannot remove '$f': Is a directory\n" if $socket; $rc = 1; }
            } elsif (-e $f || -l $f) {
                unless (unlink($f)) {
                    print $socket "OUTPUT rm: cannot remove '$f': $!\n" if $socket;
                    $rc = 1;
                }
            } elsif (!$force) {
                print $socket "OUTPUT rm: cannot remove '$f': No such file or directory\n" if $socket;
                $rc = 1;
            }
        }
        return $rc;
    }

    return undef if $clean_cmd =~ /[*?\[\]]/;   # globs: only rm expands them here

    if ($prog eq 'mkdir') {
        my $parents = 0;
        my @dirs;
        for my $a (@args) {
            if ($a eq '-p') { $parents = 1; }
            elsif ($a =~ /^-/) { return undef; }
            else { push @dirs, $a; }
        }
        return undef unless @dirs;
        for my $d (@dirs) {
            if ($parents) {
                make_path($d) unless -d $d;
                next if -d $d;
            } else {
                next if mkdir($d);
            }
            print $socket "OUTPUT mkdir: cannot create directory '$d': $!\n" if $socket;
            return 1;
        }
        return 0;
    }

    if ($prog eq 'mv' && @args == 2 || ($prog eq 'mv' && @args == 3 && $args[0] eq '-f')) {
        my ($src, $dst) = @args[-2, -1];
        if (!move($src, $dst)) {
            print $socket "OUTPUT mv: cannot move '$src' to '$dst': $!\n" if $socket;
            return 1;
        }
        return 0;
    }

    if ($prog eq 'cp' && @args == 2 && $args[0] !~ /^-/) {
        my ($src, $dst) = @args;
        if (!copy($src, $dst)) {
            print $socket "OUTPUT cp: cannot copy '$src' to '$dst': $!\n" if $socket;
            return 1;
        }
        return 0;
    }

    if ($prog eq 'touch' && @args && !grep { /^-/ } @args) {
        for my $file (@args) {
            if (-e $file) {
                utime(undef, undef, $file) or return 1;
            } else {
                open(my $fh, '>', $file) or return 1;
                close($fh);
            }
        }
        return 0;
    }

    return 0 if ($prog eq 'true' || $prog eq ':') && !@args;
    return 1 if $prog eq 'false' && !@args;

    return undef;  # Not a built-in
}

# Worker entry point - to be called after fork()
# Parameters: ($host, $port)
sub run_worker {
    my ($host, $port) = @_;
    
    # Set up connection to job master
    print STDERR "Worker connecting to $host:$port...\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
    my $socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );
    unless ($socket) {
        # An extra worker started for blocked sub-makes may arrive after the
        # build has finished and the job-master has gone: nothing to report.
        exit(0) if $ENV{SMAK_EXTRA_WORKER};
        die "Cannot connect to master at $host:$port: $!\n";
    }

    $socket->autoflush(1);
    # Disable Nagle's algorithm for low latency - always needed for responsive dispatch
    setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);
    print STDERR "Worker connected to master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';

    # Send ready signal
    print $socket "READY\n";
    $socket->flush();

    # Use sysread + manual line buffer throughout to avoid Perl buffered
    # I/O vs select() mismatch (see Gotcha #11/#24).  Buffered <$socket>
    # can over-read into Perl's buffer, making select() blind to data.
    my $sel = IO::Select->new($socket);
    my $last_idle_sent = 0;
    my $read_buf = '';

    # Read one line from socket using sysread + manual buffer.
    # Returns the line (without newline) or undef on EOF/error.
    my $read_line = sub {
        while ($read_buf !~ /\n/) {
            my @ready = $sel->can_read(1.0);
            if (!@ready) {
                # Timeout - send periodic IDLE heartbeat
                my $now = Time::HiRes::time();
                if ($now - $last_idle_sent >= 1.0) {
                    print $socket "IDLE $now\n";
                    $socket->flush();
                    $last_idle_sent = $now;
                }
                next;
            }
            my $n = sysread($socket, $read_buf, 65536, length($read_buf));
            return undef if !$n;  # EOF or error
        }
        $read_buf =~ s/^([^\n]*)\n//;
        return $1;
    };

    # Receive environment from master
    my $env_done = 0;
    while (1) {
        my $line = $read_line->();
        die "Connection closed before environment received\n" unless defined $line;

        if ($line eq 'ENV_START') {
            next;
        } elsif ($line eq 'ENV_END') {
            $env_done = 1;
            print STDERR "Worker received environment\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
            last;
        } elsif ($line =~ /^ENV (\w+)=(.*)$/) {
            $ENV{$1} = $2;
        }
    }

    while (1) {
        my $line = $read_line->();
        last unless defined $line;  # Connection closed

        # Check for shutdown signal
        if ($line eq 'SHUTDOWN') {
            print STDERR "Worker shutting down on master request\n" if $ENV{SMAK_DEBUG} || $ENV{SMAK_VERBOSE};
            last;
        }

        # Job server detached from its client: let go of the client's
        # terminal/pipe (task output travels over the socket anyway).
        if ($line eq 'STDIO_NULL') {
            open(STDIN, '<', '/dev/null');
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>', '/dev/null');
            next;
        }

        # Handle CLI owner change
        if ($line =~ /^CLI_OWNER (\d+)$/) {
            $ENV{SMAK_CLI_PID} = $1;
            next;
        }

        # Handle task
        if ($line =~ /^TASK (\d+)$/) {
            my $task_id = $1;

            # Get directory
            my $dir_line = $read_line->();
            die "Connection closed reading DIR\n" unless defined $dir_line;
            die "Expected DIR line, got: $dir_line\n" unless $dir_line =~ /^DIR (.*)$/;
            my $dir = $1;

            # Get external commands (EXTERNAL_CMDS or EXTERNAL_CMDS_DRY protocol)
            my @external_commands;
            my @trailing_builtins;
            my $command = '';  # For display
            my $is_dry_run = 0;

            my $ext_line = $read_line->();
            die "Connection closed reading EXTERNAL_CMDS\n" unless defined $ext_line;
            if ($ext_line =~ /^EXTERNAL_CMDS(_DRY)? (\d+)$/) {
                $is_dry_run = 1 if $1;
                my $count = $2;
                for (1..$count) {
                    my $cmd = $read_line->();
                    $cmd =~ s/\x00DOLLAR\x00/\$/g if defined $cmd;   # literal $ from $$
                    push @external_commands, $cmd if defined $cmd && $cmd ne '';
                }

                # Get trailing builtins
                my $builtin_line = $read_line->();
                die "Connection closed reading TRAILING_BUILTINS\n" unless defined $builtin_line;
                if ($builtin_line =~ /^TRAILING_BUILTINS (\d+)$/) {
                    my $count = $1;
                    for (1..$count) {
                        my $cmd = $read_line->();
                        $cmd =~ s/\x00DOLLAR\x00/\$/g if defined $cmd;
                        push @trailing_builtins, $cmd if defined $cmd && $cmd ne '';
                    }
                }
                $command = join(' && ', @external_commands, @trailing_builtins);
            } else {
                die "Expected EXTERNAL_CMDS line, got: $ext_line\n";
            }

            # Apply path remapping for remote workers (sshfs mount at different path)
            if ($ENV{SMAK_PATH_REMAP} && $dir =~ m{^/}) {
                my ($from, $to) = split(/:/, $ENV{SMAK_PATH_REMAP}, 2);
                $dir =~ s/^\Q$from\E/$to/ if $from && $to;
            }

            # Change to directory
            my $old_dir = getcwd();
            unless (chdir($dir)) {
                print $socket "TASK_START $task_id\n";
                print $socket "OUTPUT ERROR: Cannot chdir to $dir: $!\n";
                print $socket "TASK_END $task_id 1\n";
                print $socket "READY\n";
                next;
            }

            # Signal task start
            print $socket "TASK_START $task_id\n";
            $socket->flush();

            my $exit_code = 0;

            if ($is_dry_run) {
                # DRY-RUN MODE: Print command
                print $socket "OUTPUT $command\n";
                $socket->flush();
            } else {
                # REGULAR MODE: Execute commands using direct exec where possible

                # Execute each external command
                for my $ext_cmd (@external_commands) {
                    last if $exit_code != 0;

                    # Try built-in execution first (handles mkdir, rm, mv, etc. more efficiently)
                    my $builtin_result = execute_builtin($ext_cmd, $socket);
                    if (defined $builtin_result) {
                        $exit_code = $builtin_result;
                        next;
                    }

                    # Not a built-in, execute externally
                    # Strip @ (silent) and - (ignore errors) prefixes that make understands
                    my $run_cmd = $ext_cmd;
                    $run_cmd =~ s/^[@+-]+//;
                    $run_cmd =~ s/^\s+//;
                    my ($pid, $cmd_fh, $is_direct) = execute_command_direct($run_cmd);
                    if ($pid) {
                        while (my $out_line = <$cmd_fh>) {
                            chomp $out_line;
                            print $socket "OUTPUT $out_line\n";
                        }
                        close($cmd_fh);
                        waitpid($pid, 0) if $is_direct;  # Wait for direct exec child
                        $exit_code = $? >> 8;
                    } else {
                        print $socket "OUTPUT ERROR: Cannot execute command: $!\n";
                        $exit_code = 1;
                    }
                }

                # Execute trailing builtins if externals succeeded
                if ($exit_code == 0) {
                    for my $builtin_cmd (@trailing_builtins) {
                        my $builtin_exit = execute_builtin($builtin_cmd, $socket);
                        if (!defined $builtin_exit) {
                            # Not a built-in, fall back to shell
                            # Strip @ (silent) and - (ignore errors) prefixes
                            my $shell_cmd = $builtin_cmd;
                            $shell_cmd =~ s/^[@+-]+//;
                            $shell_cmd =~ s/^\s+//;
                            my $pid = open(my $cmd_fh, '-|', '/bin/sh', '-c', "{ $shell_cmd\n} 2>&1");
                            if ($pid) {
                                while (my $out_line = <$cmd_fh>) {
                                    chomp $out_line;
                                    print $socket "OUTPUT $out_line\n";
                                }
                                close($cmd_fh);
                                $builtin_exit = $? >> 8;
                            } else {
                                $builtin_exit = 1;
                            }
                        }
                        if ($builtin_exit != 0) {
                            $exit_code = $builtin_exit;
                            last;
                        }
                    }
                }
            }

            # Send completion and ready immediately
            print $socket "TASK_END $task_id $exit_code\n";
            print $socket "READY\n";
            $socket->flush();

            # Restore directory
            chdir($old_dir);
        }
    }
    
    print STDERR "Worker disconnected from master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
    exit 0;
}

1;
