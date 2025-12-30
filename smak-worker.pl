#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(:sys_wait_h);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy move);

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

# Execute a command using built-in Perl functions instead of shell
# Returns exit code (0 = success, non-zero = failure)
sub execute_builtin {
    my ($cmd, $socket) = @_;

    # Strip leading @ (silent) or - (ignore errors) prefixes
    my $ignore_errors = 0;
    my $silent = 0;
    while ($cmd =~ s/^[@-]//) {
        $silent = 1 if $& eq '@';
        $ignore_errors = 1 if $& eq '-';
    }

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
                        print $socket "OUTPUT rm: cannot remove '$file': $!\n" if $socket;
                        return 1 unless $ignore_errors;
                    }
                } else {
                    print $socket "OUTPUT rm: cannot remove '$file': Is a directory\n" if $socket && !$silent;
                    return 1 unless $force || $ignore_errors;
                }
            } elsif (-e $file) {
                unless (unlink($file)) {
                    print $socket "OUTPUT rm: cannot remove '$file': $!\n" if $socket && !$silent;
                    return 1 unless $force || $ignore_errors;
                }
            } elsif (!$force) {
                print $socket "OUTPUT rm: cannot remove '$file': No such file or directory\n" if $socket && !$silent;
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
            if ($parents) {
                make_path($dir, {error => \my $err});
                if (@$err) {
                    print $socket "OUTPUT mkdir: cannot create directory '$dir': $!\n" if $socket && !$silent;
                    return 1 unless $ignore_errors;
                }
            } else {
                unless (mkdir($dir)) {
                    print $socket "OUTPUT mkdir: cannot create directory '$dir': $!\n" if $socket && !$silent;
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
        print $socket "OUTPUT $text\n" if $socket && !$silent;
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
            print $socket "OUTPUT cd: $dir: $!\n" if $socket && !$silent;
            return 1 unless $ignore_errors;
        }
        return 0;
    }

    # Not a recognized built-in
    return undef;
}

# Usage: smak-worker <host:port>
my $server_addr = $ARGV[0] or die "Usage: $0 <host:port>\n";

# Parse host:port
my ($host, $port) = split(/:/, $server_addr);
die "Invalid address format. Use host:port\n" unless defined $port;

# Connect to master
print STDERR "Worker connecting to $host:$port...\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
my $socket = IO::Socket::INET->new(
    PeerHost => $host,
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 10,
) or die "Cannot connect to master at $host:$port: $!\n";

$socket->autoflush(1);
print STDERR "Worker connected to master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';

# Send ready signal
print $socket "READY\n";

our $command;
our $dir;
our $old_dir;
our $task_id;

sub get_task {
    my ($tid,$env_set) = @_;

    $task_id = $tid;
    
    # Get directory
    my $dir_line = <$socket>;
    chomp $dir_line;
    die "Expected DIR line, got: $dir_line\n" unless $dir_line =~ /^DIR (.*)$/;
    $dir = $1;
    
    # Get command
    my $cmd_line = <$socket>;
    chomp $cmd_line;
    die "Expected CMD line, got: $cmd_line\n" unless $cmd_line =~ /^CMD (.*)$/;
    $command = $1;

    if ($env_set) {
	# Execute command - just show the command without the task ID prefix
	print STDERR "$command\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
	
	# Change to directory
	$old_dir = `pwd`;
	chomp $old_dir;
	chdir($dir) or do {
	    # Send error back
	    print $socket "TASK_START $task_id\n";
	    print $socket "OUTPUT ERROR: Cannot chdir to $dir: $!\n";
	    print $socket "TASK_END $task_id 1\n";
	    print $socket "READY\n";
	    next;
	};
	
	# Signal task start
	print $socket "TASK_START $task_id\n";
    }
    else {
	print $socket "TASK_RETURN $task_id Not ready\n";
    }
    
}

# Receive environment
my $env_done = 0;

while (my $line = <$socket>) {
    chomp $line;
    my $last = "";
    
    if ($line eq 'ENV_START') {
        next;
    } elsif ($line eq 'ENV_END') {
        $env_done = 1;
        print STDERR "Worker received environment\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
        last;
    } elsif ($line =~ /^ENV (\w+)=(.*)$/) {
        # Set environment variable
        $ENV{$1} = $2;
    } else {
        warn "Unexpected line during environment setup: '$line' (after '$last')\n";	
	if ($line =~ /^TASK (\d+)$/) {
	    get_task($1,0);
	}
    }
    $last = $line;
}

die "Connection closed before environment received\n" unless $env_done;

# Main loop: receive and execute commands
while (my $line = <$socket>) {
    chomp $line;

    # Check for shutdown signal
    if ($line eq 'SHUTDOWN') {
        print STDERR "Worker shutting down on master request\n";
        last;
    }

    # Handle CLI owner change
    if ($line =~ /^CLI_OWNER (\d+)$/) {
        my $new_owner = $1;
        $ENV{SMAK_CLI_PID} = $new_owner;
        # Worker doesn't prompt, so just update environment
        next;
    }

    # Parse command format: "task <#> ; cd <dir> ; <command>"
    # Or simplified: "TASK <#>\nDIR <dir>\nCMD <command>\n"
    if ($line =~ /^TASK (\d+)$/) {
	get_task($1,$env_done);

        # Check if command has recursive smak/make -C calls
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
            # Allow optional flags (like -j4) between smak and -C
            if ($part =~ m{^(?:(?:\.\.?/|/)?[\w/.-]*(?:smak|make))(?:\s+-\S+)*\s+-C\s+(\S+)\s+(\S+)}) {
                if (!$found_non_recursive) {
                    push @recursive_calls, { dir => $1, target => $2 };
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
            # Check if built-in optimizations are disabled (for testing)
            if ($ENV{SMAK_NO_BUILTINS}) {
                print STDERR "DEBUG: SMAK_NO_BUILTINS set - skipping in-process optimization\n" if $ENV{SMAK_VERBOSE};
                # Fall through to execute command normally
            } else {
                # Handle recursive calls in-process using existing smak
                print $socket "OUTPUT [In-process: " . scalar(@recursive_calls) . " recursive build(s)]\n";

                my $final_exit = 0;
                for my $call (@recursive_calls) {
                    my ($subdir, $subtarget) = ($call->{dir}, $call->{target});

                    # Convert subdir to absolute path
                    my $abs_subdir = $subdir;
                    unless ($abs_subdir =~ m{^/}) {
                        use Cwd 'abs_path';
                        $abs_subdir = abs_path($subdir) || "$old_dir/$subdir";
                    }

                    # Execute smak directly in the subdirectory (reuses parent job server)
                    use FindBin qw($RealBin);
                    my $smak_path = "$RealBin/smak";
                    my $smak_cmd = "cd '$abs_subdir' && '$smak_path' '$subtarget'";
                    print $socket "OUTPUT   → $abs_subdir: $subtarget\n";

                    # Use fork/pipe to capture output and maintain I/O control
                    my $pid = open(my $smak_fh, '-|', "$smak_cmd 2>&1 ; echo EXIT_STATUS=\$?");
                    if (!defined $pid) {
                        print $socket "OUTPUT Cannot execute smak: $!\n";
                        $final_exit = 1;
                        last;
                    }

                    # Stream output line by line
                    my $sub_exit = 0;
                    while (my $line = <$smak_fh>) {
                        if ($line =~ /^EXIT_STATUS=(\d+)$/) {
                            $sub_exit = $1;
                            next;
                        }
                        # Forward output to master
                        print $socket "OUTPUT $line";
                    }
                    close($smak_fh);

                    if ($sub_exit != 0) {
                        print $socket "OUTPUT   ✗ Failed (exit $sub_exit)\n";
                        $final_exit = $sub_exit;
                        last;
                    }
                    print $socket "OUTPUT   ✓ Complete\n";
                }

                # If there are non-recursive commands after the recursive ones, execute them
                if ($final_exit == 0 && @non_recursive_parts > 0) {
                    print $socket "OUTPUT [Executing remaining commands]\n";

                    # Try to execute each command as a built-in first
                    for my $cmd_part (@non_recursive_parts) {
                        my $builtin_exit = execute_builtin($cmd_part, $socket);

                        if (defined $builtin_exit) {
                            # Command was handled as built-in
                            if ($builtin_exit != 0) {
                                $final_exit = $builtin_exit;
                                last;
                            }
                        } else {
                            # Not a built-in, execute via fork/pipe to capture output
                            print $socket "OUTPUT [Shell: $cmd_part]\n" if $ENV{SMAK_DEBUG};

                            my $pid = open(my $cmd_fh, '-|', "cd '$old_dir' && $cmd_part 2>&1 ; echo EXIT_STATUS=\$?");
                            if (!defined $pid) {
                                print $socket "OUTPUT Cannot execute command: $!\n";
                                $final_exit = 1;
                                last;
                            }

                            # Stream output line by line
                            my $shell_exit = 0;
                            while (my $line = <$cmd_fh>) {
                                if ($line =~ /^EXIT_STATUS=(\d+)$/) {
                                    $shell_exit = $1;
                                    next;
                                }
                                print $socket "OUTPUT $line";
                            }
                            close($cmd_fh);

                            if ($shell_exit != 0) {
                                $final_exit = $shell_exit;
                                last;
                            }
                        }
                    }
                }

                print $socket "TASK_END $task_id $final_exit\n";
                chdir($old_dir);
                print $socket "READY\n";
                next;
            }
        }

        # Assert that we should be using built-in optimizations (for testing)
        if ($ENV{SMAK_ASSERT_NO_SPAWN} && @recursive_calls > 0) {
            my $error_msg = "SMAK_ASSERT_NO_SPAWN: About to spawn subprocess for recursive build, but built-in should be used\n" .
                "Command: $command\n" .
                "Recursive calls detected: " . scalar(@recursive_calls) . "\n" .
                "Targets: " . join(", ", map { "$_->{dir}/$_->{target}" } @recursive_calls) . "\n";
            print $socket "OUTPUT $error_msg";
            print $socket "TASK_END $task_id 1\n";
            print STDERR $error_msg;
            die $error_msg;
        }

        # Not a recursive build - execute command normally
        # Execute command with non-blocking I/O to remain responsive
        use IO::Select;
        use POSIX ":sys_wait_h";
        use Time::HiRes qw(sleep);

        my $exit_code = 0;
        my @errors;
        my @warnings;
        my $max_retries = 3;
        my $attempt = 0;

        # Retry loop for transient failures
        while ($attempt < $max_retries) {
            $attempt++;
            @errors = ();
            @warnings = ();
            $exit_code = 0;

            # Fork to execute command, keep parent responsive
            my $pid = open(my $cmd_fh, '-|', "$command 2>&1");
            if ($pid) {
            # Make command output non-blocking
            $cmd_fh->blocking(0);

            # Use select to multiplex socket and command output
            my $select = IO::Select->new($socket, $cmd_fh);
            my $command_done = 0;

            while (!$command_done || $select->count() > 1) {
                my @ready = $select->can_read(0.1);

                for my $fh (@ready) {
                    if ($fh == $socket) {
                        # Handle socket messages while command runs
                        my $msg = <$socket>;
                        if (!defined $msg) {
                            # Socket closed - try to send TASK_END before exiting
                            kill 'TERM', $pid if $pid;
                            # Try to send termination message (may fail if socket is truly dead)
                            eval {
                                print $socket "TASK_END $task_id 1\n";
                                print $socket "OUTPUT ERROR: Socket closed during task execution\n";
                            };
                            exit 1;
                        }
                        chomp $msg;

                        if ($msg eq 'SHUTDOWN') {
                            kill 'TERM', $pid if $pid;
                            print STDERR "Worker shutting down during task\n";
                            exit 0;
                        } elsif ($msg eq 'STATUS') {
                            print $socket "RUNNING $task_id\n";
                        }
                        # Ignore other messages during execution

                    } elsif ($fh == $cmd_fh) {
                        # Read command output
                        my $line = <$cmd_fh>;
                        if (defined $line) {
                            chomp $line;

                            # Detect errors and warnings
                            if ($line =~ /\berror\b/i || $line =~ /\bfailed\b/i) {
                                push @errors, $line;
                                print $socket "ERROR $line\n";
                            } elsif ($line =~ /\bwarning\b/i) {
                                push @warnings, $line;
                                print $socket "WARN $line\n";
                            } else {
                                print $socket "OUTPUT $line\n";
                            }
                        } else {
                            # EOF on command output
                            $select->remove($cmd_fh);
                            close($cmd_fh);
                            $exit_code = $? >> 8;
                            $command_done = 1;
                        }
                    }
                }

                # Check if command exited
                if ($pid && !$command_done) {
                    my $result = waitpid($pid, WNOHANG);
                    if ($result > 0) {
                        $exit_code = $? >> 8;
                        # Drain any remaining output
                        while (my $line = <$cmd_fh>) {
                            chomp $line;
                            if ($line =~ /\berror\b/i || $line =~ /\bfailed\b/i) {
                                push @errors, $line;
                                print $socket "ERROR $line\n";
                            } elsif ($line =~ /\bwarning\b/i) {
                                push @warnings, $line;
                                print $socket "WARN $line\n";
                            } else {
                                print $socket "OUTPUT $line\n";
                            }
                        }
                        close($cmd_fh);
                        $select->remove($cmd_fh);
                        $command_done = 1;
                    }
                }
            }

            # Send summary if there were errors or warnings
            if (@errors || @warnings) {
                my $err_count = scalar(@errors);
                my $warn_count = scalar(@warnings);
                print $socket "OUTPUT \n";
                print $socket "OUTPUT Summary: $err_count error(s), $warn_count warning(s)\n";
            }
            } else {
                # Fork failed
                print $socket "ERROR Failed to execute command: $!\n";
                $exit_code = 1;
            }

            # Check if failure is acceptable
            if ($exit_code != 0 && is_acceptable_failure($command, $exit_code, $dir)) {
                $exit_code = 0;  # Treat as success
            }

            # Check for transient failures and retry if needed
            if ($exit_code != 0 && $attempt < $max_retries) {
                # Check if any error looks transient
                my $all_errors = join("\n", @errors);
                if (is_transient_failure($all_errors)) {
                    my $delay = 0.1 * (2 ** ($attempt - 1));  # Exponential backoff: 0.1s, 0.2s, 0.4s
                    print $socket "OUTPUT [Transient failure detected, retrying in ${delay}s... (attempt $attempt/$max_retries)]\n";
                    sleep($delay);
                    next;  # Retry
                }
            }

            # Exit retry loop on success or non-transient failure
            last;
        }

        # Send completion
        print $socket "TASK_END $task_id $exit_code\n";

        # Send ready for next task
        print $socket "READY\n";

        # Restore directory
        chdir($old_dir);
    } else {
        warn "Worker received unexpected command: $line\n";
    }
}

# Connection closed
print STDERR "Worker disconnected from master\n" if $ENV{SMAK_DEBUG};
close($socket);
exit 0;
