#!/usr/bin/perl
# Random sleep script for testing parallel execution
use strict;
use warnings;
use Getopt::Long;

my $name = "task";
my $min_seconds = 1;
my $max_seconds = 5;
my @inputs = ();
my @outputs = ();

GetOptions(
    'name=s' => \$name,
    'min=f' => \$min_seconds,
    'max=f' => \$max_seconds,
    'in=s@' => \@inputs,
    'out=s@' => \@outputs,
) or die "Usage: $0 [--name NAME] [--min SECONDS] [--max SECONDS] [--in FILE...] [--out FILE...]\n";

# Check that all input files exist
for my $input (@inputs) {
    if (!-e $input) {
        printf STDERR "[%s] ERROR: Input file does not exist: %s\n", $name, $input;
        exit 1;
    }
}

# Random sleep time between min and max
my $sleep_time = $min_seconds + rand($max_seconds - $min_seconds);

printf "[%s] Starting (will sleep %.2f seconds)\n", $name, $sleep_time;
if (@inputs) {
    printf "[%s] Inputs: %s\n", $name, join(", ", @inputs);
}
if (@outputs) {
    printf "[%s] Outputs: %s\n", $name, join(", ", @outputs);
}

sleep($sleep_time);

# Touch all output files
for my $output (@outputs) {
    # Create parent directories if needed
    if ($output =~ m{^(.+)/[^/]+$}) {
        my $dir = $1;
        system("mkdir", "-p", $dir) unless -d $dir;
    }

    # Touch the file
    open(my $fh, '>>', $output) or die "Cannot touch $output: $!\n";
    close($fh);
    utime(undef, undef, $output);
}

printf "[%s] Completed after %.2f seconds\n", $name, $sleep_time;

exit 0;
