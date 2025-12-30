#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(:sys_wait_h);

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

        # Check if command is entirely composed of recursive smak/make -C calls
        # This prevents spawning multiple job servers for subdirectories
        my @command_parts = split(/\s+&&\s+/, $command);
        my $all_recursive = 1;
        my @recursive_calls;

        for my $part (@command_parts) {
            $part =~ s/^\s+|\s+$//g;  # Trim whitespace
            $part =~ s/^[@-]+//;      # Strip @ (silent) and - (ignore errors) prefixes
            # Match: smak -C <dir> <target> or make -C <dir> <target>
            # Also match relative paths like ../smak or ./smak
            # Allow optional flags (like -j4) between smak and -C
            if ($part =~ m{^(?:(?:\.\.?/|/)?[\w/.-]*(?:smak|make))(?:\s+-\S+)*\s+-C\s+(\S+)\s+(\S+)}) {
                push @recursive_calls, { dir => $1, target => $2 };
            } elsif ($part eq 'true' || $part eq ':' || $part eq '') {
                # Ignore no-op commands and empty parts
                next;
            } else {
                $all_recursive = 0;
                last;
            }
        }

        if ($all_recursive && @recursive_calls > 0) {
            # Check if built-in optimizations are disabled (for testing)
            if ($ENV{SMAK_NO_BUILTINS}) {
                print STDERR "DEBUG: SMAK_NO_BUILTINS set - skipping in-process optimization\n" if $ENV{SMAK_VERBOSE};
                # Fall through to execute command normally
            } else {
                # Handle recursive calls in-process using existing smak
                # Instead of spawning new job servers, execute smak directly
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
                    # The key is NOT using -j flag, which would spawn a new job server
                    # Use FindBin to locate the smak executable
                    use FindBin qw($RealBin);
                    my $smak_path = "$RealBin/smak";
                    my $smak_cmd = "cd '$abs_subdir' && '$smak_path' '$subtarget'";
                    print $socket "OUTPUT   → $abs_subdir: $subtarget\n";

                    my $sub_exit = system($smak_cmd) >> 8;
                    if ($sub_exit != 0) {
                        print $socket "OUTPUT   ✗ Failed (exit $sub_exit)\n";
                        $final_exit = $sub_exit;
                        last;
                    }
                    print $socket "OUTPUT   ✓ Complete\n";
                }

                print $socket "TASK_END $task_id $final_exit\n";
                chdir($old_dir);
                print $socket "READY\n";
                next;
            }
        }

        # Assert that we should be using built-in optimizations (for testing)
        if ($ENV{SMAK_ASSERT_NO_SPAWN} && $all_recursive && @recursive_calls > 0) {
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
