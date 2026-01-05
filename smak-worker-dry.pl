#!/usr/bin/perl
# Dummy worker for --dry-run mode
# Just prints commands and returns success
use strict;
use warnings;
use IO::Socket::INET;

my $host = $ARGV[0] || die "Usage: $0 <host:port>\n";

# Connect to job master
my $socket = IO::Socket::INET->new(
    PeerAddr => $host,
    Proto    => 'tcp',
) or die "Cannot connect to job master at $host: $!\n";

# Receive environment
my $env_done = 0;

while (my $line = <$socket>) {
    chomp $line;

    if ($line eq 'ENV_START') {
        next;
    } elsif ($line eq 'ENV_END') {
        $env_done = 1;
        last;
    } elsif ($line =~ /^ENV (\w+)=(.*)$/) {
        # Set environment variable (though we won't use it)
        $ENV{$1} = $2;
    }
}

die "Connection closed before environment received\n" unless $env_done;

# Main loop: receive commands and print them
while (my $line = <$socket>) {
    chomp $line;

    # Check for shutdown signal
    if ($line eq 'SHUTDOWN') {
        last;
    }

    # Handle CLI owner change (ignored in dry-run)
    if ($line =~ /^CLI_OWNER (\d+)$/) {
        next;
    }

    # Parse command format: TASK <#>\nDIR <dir>\nCMD <command>\n
    if ($line =~ /^TASK (\d+)$/) {
        my $task_id = $1;

        # Get directory
        my $dir_line = <$socket>;
        chomp $dir_line;
        die "Expected DIR line, got: $dir_line\n" unless $dir_line =~ /^DIR (.*)$/;
        my $dir = $1;

        # Get command
        my $cmd_line = <$socket>;
        chomp $cmd_line;
        die "Expected CMD line, got: $cmd_line\n" unless $cmd_line =~ /^CMD (.*)$/;
        my $command = $1;

        # Signal task start
        print $socket "TASK_START $task_id\n";

        # Print the command to stdout (master will display it)
        print $socket "OUTPUT $command\n";

        # Signal task completion with success
        print $socket "TASK_END $task_id 0\n";

        # Ready for next task
        print $socket "READY\n";
    }
}

exit 0;
