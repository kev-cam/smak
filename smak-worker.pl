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
	# Execute command
	print STDERR "Worker executing task $task_id: $command\n";
	
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

    # Parse command format: "task <#> ; cd <dir> ; <command>"
    # Or simplified: "TASK <#>\nDIR <dir>\nCMD <command>\n"
    if ($line =~ /^TASK (\d+)$/) {
	get_task($1,$env_done);

        # Execute command with non-blocking I/O to remain responsive
        use IO::Select;
        use POSIX ":sys_wait_h";

        my $exit_code = 0;
        my @errors;
        my @warnings;

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
print STDERR "Worker disconnected from master\n";
close($socket);
exit 0;
