#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(time);
use FindBin;

# Parent: create a listening socket
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto => 'tcp',
    Listen => 1,
    ReuseAddr => 1,
) or die "Cannot create server socket: $!";

my $port = $server->sockport();

# Start the worker using SmakWorker module (EXTERNAL_CMDS protocol)
my $worker_pid = fork();
if ($worker_pid == 0) {
    close($server);
    # Add smak directory to @INC for SmakWorker module
    unshift @INC, "$FindBin::Bin/..";
    require SmakWorker;
    SmakWorker::run_worker('127.0.0.1', $port);
    exit 0;
}

print "Waiting for worker to connect on port $port...\n";
my $worker = $server->accept();
$worker->autoflush(1);
close($server);
print "Worker connected\n";

# Worker sends READY first
my $ready = <$worker>;
chomp $ready if defined $ready;
die "Expected READY, got: " . ($ready // "undef") unless $ready eq 'READY';
print "Worker is READY\n";

# Send environment
print $worker "ENV_START\n";
print $worker "ENV_END\n";

# Send 100 test commands and measure throughput (EXTERNAL_CMDS protocol)
my $num_commands = 100;
my $start_time = time();

my $send_time = 0;
my $recv_time = 0;

for my $i (1..$num_commands) {
    # Send TASK using EXTERNAL_CMDS protocol
    my $t1 = time();
    print $worker "TASK $i\n";
    print $worker "DIR /tmp\n";
    print $worker "EXTERNAL_CMDS 1\n";
    print $worker "echo test command $i\n";
    print $worker "TRAILING_BUILTINS 0\n";
    $worker->flush();
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
$worker->flush();
close($worker);
waitpid($worker_pid, 0);
