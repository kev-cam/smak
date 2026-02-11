#!/usr/bin/perl
use strict;
use warnings;

# Remote worker script - thin wrapper around SmakWorker module
# This is used when workers are spawned via SSH on remote hosts
# Local workers call SmakWorker::run_worker() directly from Smak.pm

use FindBin qw($RealBin);
use lib $RealBin;
use SmakWorker;

# Usage: smak-worker [-cd <dir>] <host:port>
my $dir;
while (@ARGV && $ARGV[0] =~ /^-/) {
    my $opt = shift @ARGV;
    if ($opt eq '-cd' && @ARGV) {
        $dir = shift @ARGV;
    }
}

my $server_addr = $ARGV[0] or die "Usage: $0 [-cd <dir>] <host:port>\n";

# Parse host:port
my ($host, $port) = split(/:/, $server_addr);
die "Invalid address format. Use host:port\n" unless defined $port;

# Change to directory if specified
if ($dir) {
    chdir($dir) or die "Cannot chdir to $dir: $!\n";
}

# Run the worker
SmakWorker::run_worker($host, $port);
