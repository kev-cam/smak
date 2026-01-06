#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(time);

# Parent: create a listening socket
my $server = IO::Socket::INET->new(
    LocalPort => 0,
    Proto => 'tcp',
    Listen => 1,
    ReuseAddr => 1,
) or die "Cannot create server socket: $!";

my $port = $server->sockport();

# Start the dry worker
my $worker_pid = fork();
if ($worker_pid == 0) {
    # Child: exec the dry worker (it will connect to us)
    exec('/usr/local/src/smak/smak-worker-dry', "localhost:$port") or die "Failed to exec worker: $!";
}

print "Waiting for worker to connect on port $port...\n";
my $worker = $server->accept();
$worker->autoflush(1);
print "Worker connected\n";

# Send environment
print $worker "ENV_START\n";
print $worker "ENV_END\n";

# Wait for READY
my $ready = <$worker>;
chomp $ready if defined $ready;
die "Expected READY, got: " . ($ready // "undef") unless $ready eq 'READY';
print "Worker is READY\n";

# Send 100 test commands and measure throughput
my $num_commands = 100;
my $start_time = time();

my $send_time = 0;
my $recv_time = 0;

for my $i (1..$num_commands) {
    # Send TASK
    my $t1 = time();
    print $worker "TASK $i\n";
    print $worker "DIR /tmp\n";
    print $worker "CMD echo test command $i\n";
    $send_time += (time() - $t1);

    # Read responses until we get READY again
    my $t2 = time();
    while (1) {
        my $response = <$worker>;
        last unless defined $response;
        chomp $response;
        last if $response eq 'READY';
    }
    $recv_time += (time() - $t2);
}

my $elapsed = time() - $start_time;
my $throughput = $num_commands / $elapsed;

print "\n";
print "Completed $num_commands commands in ${elapsed} seconds\n";
print "Send time: ${send_time} seconds\n";
print "Recv time: ${recv_time} seconds\n";
print "Throughput: ${throughput} commands/second\n";

# Cleanup
print $worker "SHUTDOWN\n";
close($worker);
waitpid($worker_pid, 0);
