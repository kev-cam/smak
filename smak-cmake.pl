#!/usr/bin/perl
# smak-cmake - Drive CMake builds via smak's own interpreter, with an
# optional fallback to a downloaded real cmake binary.
#
# Dispatch order:
#   1. If SMAK_CMAKE_REAL=1 (or the invocation doesn't look like a config
#      run — e.g., `cmake --build`, `cmake -E`), use the real cmake.
#   2. Otherwise try `smak -cmake` (SmakCMakeInterp + generator).
#   3. On any failure, fall through to the real cmake (download if needed).
use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';

my $script_dir = dirname(abs_path($0));
my $cmake_link = "$script_dir/cmake-install";
my $cmake_bin  = "$cmake_link/bin/cmake";
my $smak_pl    = "$script_dir/smak.pl";

# CMake version to download (fallback only)
my $cmake_version = "3.31.4";
my $cmake_dirname = "cmake-$cmake_version-linux-x86_64";
my $cmake_archive = "$cmake_dirname.tar.gz";
my $cmake_url = "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$cmake_archive";

sub _run_real {
    if (-x $cmake_bin) {
        exec($cmake_bin, @ARGV) or die "Failed to exec $cmake_bin: $!\n";
    }
    # fall through to download path
}

# Decide whether to attempt the smak interp. Non-configure invocations
# (--build, --install, -E, --version) go straight to real cmake.
my $is_config = 1;
for my $a (@ARGV) {
    if ($a eq '--build' || $a eq '--install' || $a eq '-E'
        || $a eq '--version' || $a eq '--help' || $a eq '-P') {
        $is_config = 0; last;
    }
}
$is_config = 0 if $ENV{SMAK_CMAKE_REAL};

if ($is_config && -f $smak_pl) {
    # Call smak.pl directly (NOT via the bash wrapper `smak`, which would
    # re-enter this script and loop). smak.pl's first line checks for
    # -cmake and dispatches to SmakCMakeInterp + generate_makefiles.
    local $ENV{PERLLIB} = ($ENV{PERLLIB} // '') eq '' ? $script_dir : "$script_dir:$ENV{PERLLIB}";
    my $rc = system('perl', $smak_pl, '-cmake', @ARGV);
    if ($rc == 0) { exit 0; }
    warn "smak -cmake failed (rc=", ($rc >> 8), "); falling back to real cmake\n";
}

if (-x $cmake_bin) {
    exec($cmake_bin, @ARGV) or die "Failed to exec $cmake_bin: $!\n";
}

# cmake not found — auto-download, or prompt if interactive
print "CMake not found at $cmake_bin\n";
my $auto = !-t STDIN;  # non-interactive (piped / script) → auto-yes
if (!$auto) {
    print "Download cmake $cmake_version? [Y/n] ";
    my $answer = <STDIN>;
    chomp($answer);
    if ($answer =~ /^n/i) {
        print "Aborted.\n";
        exit 1;
    }
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

# Clean up archive (auto-delete in non-interactive mode)
if ($auto) {
    unlink($archive_path);
    print "Archive deleted.\n";
} else {
    print "Delete archive $cmake_archive? [Y/n] ";
    my $answer = <STDIN>;
    chomp($answer);
    if ($answer !~ /^n/i) {
        unlink($archive_path);
        print "Archive deleted.\n";
    }
}

if (-x $cmake_bin) {
    print "CMake installed successfully.\n";
    print "Running: $cmake_bin @ARGV\n\n";
    exec($cmake_bin, @ARGV) or die "Failed to exec $cmake_bin: $!\n";
} else {
    die "Installation failed - $cmake_bin not found\n";
}
