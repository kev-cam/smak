#!/usr/bin/env perl
#
# smak-man - Display smak manual page
#

use strict;
use warnings;
use FindBin qw($RealBin);
use File::Spec;

# Find the man page
my $man_file = File::Spec->catfile($RealBin, 'smak.man');

unless (-f $man_file) {
    die "Error: Cannot find smak.man in $RealBin\n";
}

# Try different methods to display the man page, in order of preference

# Method 1: Use man with -l flag (local file)
if (system("which man >/dev/null 2>&1") == 0) {
    exec('man', '-l', $man_file);
    # If exec fails, fall through to next method
}

# Method 2: Use groff with less
if (system("which groff >/dev/null 2>&1") == 0) {
    # Format with groff and pipe to less
    my $cmd = "groff -man -Tutf8 '$man_file' | less -R";
    exec($cmd);
}

# Method 3: Use nroff with less
if (system("which nroff >/dev/null 2>&1") == 0) {
    my $cmd = "nroff -man '$man_file' | less";
    exec($cmd);
}

# Method 4: Just display the raw file with less
if (system("which less >/dev/null 2>&1") == 0) {
    warn "Warning: No man/groff/nroff found, displaying raw file\n";
    exec('less', $man_file);
}

# Method 5: Fall back to cat
warn "Warning: No pager found, dumping to stdout\n";
exec('cat', $man_file);
