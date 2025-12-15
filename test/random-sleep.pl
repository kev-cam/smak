#!/usr/bin/perl
# Random sleep script for testing parallel execution
use strict;
use warnings;

my $name = shift || "task";
my $min_seconds = shift || 1;
my $max_seconds = shift || 5;

# Random sleep time between min and max
my $sleep_time = $min_seconds + rand($max_seconds - $min_seconds);

printf "[%s] Starting (will sleep %.2f seconds)\n", $name, $sleep_time;
sleep($sleep_time);
printf "[%s] Completed after %.2f seconds\n", $name, $sleep_time;

exit 0;
