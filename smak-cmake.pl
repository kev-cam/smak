#!/usr/bin/perl
# smak-cmake - Run cmake from smak/cmake, downloading if needed
use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';

# Find the smak directory (where this script lives)
my $script_dir = dirname(abs_path($0));
my $cmake_link = "$script_dir/cmake";
my $cmake_bin = "$cmake_link/bin/cmake";

# CMake version to download
my $cmake_version = "3.31.4";
my $cmake_dirname = "cmake-$cmake_version-linux-x86_64";
my $cmake_archive = "$cmake_dirname.tar.gz";
my $cmake_url = "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$cmake_archive";

if (-x $cmake_bin) {
    # cmake exists, run it with all arguments
    exec($cmake_bin, @ARGV) or die "Failed to exec $cmake_bin: $!\n";
}

# cmake not found, prompt to download
print "CMake not found at $cmake_bin\n";
print "Download cmake $cmake_version? [Y/n] ";
my $answer = <STDIN>;
chomp($answer);

if ($answer =~ /^n/i) {
    print "Aborted.\n";
    exit 1;
}

# Download and extract
print "Downloading $cmake_url...\n";
my $archive_path = "$script_dir/$cmake_archive";

system("curl", "-L", "-o", $archive_path, $cmake_url) == 0
    or die "Download failed\n";

print "Extracting to $script_dir/$cmake_dirname...\n";

system("tar", "-xzf", $archive_path, "-C", $script_dir) == 0
    or die "Extraction failed\n";

# Create symlink
if (-e $cmake_link || -l $cmake_link) {
    if (-l $cmake_link) {
        unlink($cmake_link);
    } elsif (-d $cmake_link) {
        die "Cannot create symlink: $cmake_link is a directory. Please remove it manually.\n";
    } else {
        unlink($cmake_link);
    }
}
symlink($cmake_dirname, $cmake_link)
    or die "Failed to create symlink: $!\n";

print "Delete archive $cmake_archive? [Y/n] ";
$answer = <STDIN>;
chomp($answer);

if ($answer !~ /^n/i) {
    unlink($archive_path);
    print "Archive deleted.\n";
}

if (-x $cmake_bin) {
    print "CMake installed successfully.\n";
    print "Running: $cmake_bin @ARGV\n\n";
    exec($cmake_bin, @ARGV) or die "Failed to exec $cmake_bin: $!\n";
} else {
    die "Installation failed - $cmake_bin not found\n";
}
