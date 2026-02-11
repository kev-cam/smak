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

    # Shell keywords that require shell interpretation
    # These are control flow keywords that can't be exec'd directly
    return () if $cmd =~ /^\s*(if|then|else|elif|fi|while|do|done|for|case|esac|until|select|function)\b/;
    return () if $cmd =~ /\b(then|else|elif|fi|do|done|esac)\b/;  # Also inside the command

    # Shell builtins that cannot be exec'd directly (they're built into the shell, not executables)
    return () if $cmd =~ /^\s*(cd|export|source|\.)\b/;

    # Parse into words, handling quotes
    my @words;
    my $current = '';
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
        } elsif ($char eq '"' && !$in_single) {
            $in_double = !$in_double;
        } elsif ($char =~ /\s/ && !$in_single && !$in_double) {
            push @words, $current if $current ne '';
            $current = '';
        } else {
            $current .= $char;
        }
    }
    push @words, $current if $current ne '';

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
        # Need shell - use open with shell
        my $pid = open(my $cmd_fh, '-|', "$cmd 2>&1");
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
    $clean_cmd =~ s/^[@-]+//;
    $clean_cmd =~ s/^\s+//;

    if ($clean_cmd =~ /^rm\s+(.*)$/) {
        my $args = $1;
        my $force = ($args =~ s/\s*-[rf]+\s*/ /g);  # Remove -r, -f flags
        $args =~ s/^\s+|\s+$//g;
        my @files = split(/\s+/, $args);
        for my $file (@files) {
            unlink($file) or ($force ? 1 : return 1);
        }
        return 0;
    }

    if ($clean_cmd =~ /^mkdir\s+(?:-p\s+)?(.*)$/) {
        my $dir = $1;
        $dir =~ s/^\s+|\s+$//g;
        make_path($dir);
        return 0;
    }

    if ($clean_cmd =~ /^mv\s+(\S+)\s+(\S+)\s*$/) {
        my ($src, $dst) = ($1, $2);
        if (!move($src, $dst)) {
            print $socket "OUTPUT mv: cannot move '$src' to '$dst': $!\n" if $socket;
            return 1;
        }
        return 0;
    }

    if ($clean_cmd =~ /^cp\s+(\S+)\s+(\S+)\s*$/) {
        my ($src, $dst) = ($1, $2);
        if (!copy($src, $dst)) {
            print $socket "OUTPUT cp: cannot copy '$src' to '$dst': $!\n" if $socket;
            return 1;
        }
        return 0;
    }

    if ($clean_cmd =~ /^touch\s+(\S+)\s*$/) {
        my $file = $1;
        if (-e $file) {
            utime(undef, undef, $file);
        } else {
            open(my $fh, '>', $file) or return 1;
            close($fh);
        }
        return 0;
    }

    if ($clean_cmd =~ /^(true|:)\s*$/) {
        return 0;
    }

    if ($clean_cmd =~ /^false\s*$/) {
        return 1;
    }

    if ($clean_cmd =~ /^echo\s+(.*)$/) {
        my $text = $1;
        # Don't handle as builtin if shell metacharacters are present
        return undef if $text =~ /[>|<;&`\$]/;
        print $socket "OUTPUT $text\n" if $socket;
        return 0;
    }

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
    ) or die "Cannot connect to master at $host:$port: $!\n";

    $socket->autoflush(1);
    # Disable Nagle's algorithm for low latency - always needed for responsive dispatch
    setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);
    print STDERR "Worker connected to master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';

    # Send ready signal
    print $socket "READY\n";
    $socket->flush();

    # Receive environment from master
    my $env_done = 0;
    while (my $line = <$socket>) {
        chomp $line;
        
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

    die "Connection closed before environment received\n" unless $env_done;

    # Main worker loop - use select for periodic IDLE heartbeats
    my $sel = IO::Select->new($socket);
    my $last_idle_sent = 0;

    while (1) {
        # Wait up to 1 second for data from master
        my @ready = $sel->can_read(1.0);

        if (!@ready) {
            # Timeout - send periodic IDLE heartbeat so job server knows we're alive
            my $now = Time::HiRes::time();
            if ($now - $last_idle_sent >= 1.0) {
                print $socket "IDLE $now\n";
                $socket->flush();
                $last_idle_sent = $now;
            }
            next;
        }

        my $line = <$socket>;
        last unless defined $line;  # Connection closed
        chomp $line;

        # Check for shutdown signal
        if ($line eq 'SHUTDOWN') {
            print STDERR "Worker shutting down on master request\n" if $ENV{SMAK_DEBUG} || $ENV{SMAK_VERBOSE};
            last;
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
            my $dir_line = <$socket>;
            chomp $dir_line;
            die "Expected DIR line, got: $dir_line\n" unless $dir_line =~ /^DIR (.*)$/;
            my $dir = $1;

            # Get external commands (EXTERNAL_CMDS or EXTERNAL_CMDS_DRY protocol)
            my @external_commands;
            my @trailing_builtins;
            my $command = '';  # For display
            my $is_dry_run = 0;

            my $ext_line = <$socket>;
            chomp $ext_line;
            if ($ext_line =~ /^EXTERNAL_CMDS(_DRY)? (\d+)$/) {
                $is_dry_run = 1 if $1;
                my $count = $2;
                for (1..$count) {
                    my $cmd = <$socket>;
                    chomp $cmd if defined $cmd;
                    push @external_commands, $cmd if defined $cmd && $cmd ne '';
                }

                # Get trailing builtins
                my $builtin_line = <$socket>;
                chomp $builtin_line;
                if ($builtin_line =~ /^TRAILING_BUILTINS (\d+)$/) {
                    my $count = $1;
                    for (1..$count) {
                        my $cmd = <$socket>;
                        chomp $cmd if defined $cmd;
                        push @trailing_builtins, $cmd if defined $cmd && $cmd ne '';
                    }
                }
                $command = join(' && ', @external_commands, @trailing_builtins);
            } else {
                die "Expected EXTERNAL_CMDS line, got: $ext_line\n";
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
                my $display_cmd = $command;
                $display_cmd =~ s/\bBUILTIN_MV\b/mv/g;
                print $socket "OUTPUT $display_cmd\n";
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
                    my ($pid, $cmd_fh, $is_direct) = execute_command_direct($ext_cmd);
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
                            my $pid = open(my $cmd_fh, '-|', "$builtin_cmd 2>&1");
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
