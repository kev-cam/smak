#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use FindBin qw($RealBin);
use File::Path qw(make_path);
use POSIX qw(strftime);
use lib $RealBin;
use Smak qw(:all);

my $makefile = 'Makefile';
my $debug = 0;
my $help = 0;
my $script_file = '';
my $report = 0;
my $report_dir = '';
my $log_fh;

# Parse environment variable options first
if (defined $ENV{USR_SMAK_OPT}) {
    # Split the environment variable into arguments
    my @env_args = split(/\s+/, $ENV{USR_SMAK_OPT});
    # Save original @ARGV
    my @saved_argv = @ARGV;
    # Process environment options
    @ARGV = @env_args;
    GetOptions(
        'f|file|makefile=s' => \$makefile,
        'Kd|Kdebug' => \$debug,
        'Kh|Khelp' => \$help,
        'Ks|Kscript=s' => \$script_file,
        'Kreport' => \$report,
    );
    # Restore and append remaining command line args
    @ARGV = @saved_argv;
}

# Parse command-line options (override environment)
GetOptions(
    'f|file|makefile=s' => \$makefile,
    'Kd|Kdebug' => \$debug,
    'Kh|Khelp' => \$help,
    'Ks|Kscript=s' => \$script_file,
    'Kreport' => \$report,
) or die "Error in command line arguments\n";

# Remaining arguments are targets to build
my @targets = @ARGV;

if ($help) {
    print_help();
    exit 0;
}

# Setup report directory if -Kreport is enabled
if ($report) {
    # Create date-stamped subdirectory in bugs directory where smak is located
    my $timestamp = strftime("%Y%m%d-%H%M%S", localtime);
    $report_dir = "$RealBin/bugs/$timestamp";
    make_path($report_dir) or die "Cannot create report directory $report_dir: $!\n";

    # Open log file
    my $log_file = "$report_dir/build.log";
    open($log_fh, '>', $log_file) or die "Cannot open log file $log_file: $!\n";
    $log_fh->autoflush(1);

    # Enable report mode in the module
    set_report_mode(1, $log_fh);

    # Copy Makefile(s) to bug directory for analysis
    use File::Copy;
    if (-f $makefile) {
        my $makefile_copy = "$report_dir/" . (split(/\//, $makefile))[-1];
        copy($makefile, $makefile_copy) or warn "Could not copy $makefile: $!\n";
    }

    # Print header to both terminal and log
    my $header = "=== SMAK BUILD REPORT ===\n" .
                 "Timestamp: $timestamp\n" .
                 "Makefile: $makefile\n" .
                 "Report directory: $report_dir\n" .
                 "=" x 50 . "\n\n";
    print STDOUT $header;
    print $log_fh $header;
}

sub print_help {
    print <<'HELP';
Usage: smak [options] [targets...]

Options:
  -f, -file, -makefile FILE   Use FILE as a makefile (default: Makefile)
  -Kd, -Kdebug                Enter interactive debug mode
  -Ks, -Kscript FILE          Load and execute smak commands from FILE
  -Kreport                    Create verbose build log and run make-cmp
  -Kh, -Khelp                 Display this help message

Environment Variables:
  USR_SMAK_OPT                Options to prepend (e.g., "USR_SMAK_OPT=-Kd")

Examples:
  smak -Ks fixes.smak all     Load fixes, then build target 'all'
  USR_SMAK_OPT='-Ks fixes.smak' smak target
  smak -Kreport all           Build with verbose logging to bugs directory

HELP
}

# Parse the makefile
parse_makefile($makefile);

# Execute script file if specified
if ($script_file) {
    execute_script($script_file);
}

# If not in debug mode, build targets
if (!$debug) {
    # If no targets specified, build default target (like gmake)
    if (!@targets) {
        my $default_target = get_default_target();
        if (defined $default_target) {
            build_target($default_target);
        } else {
            die "smak: *** No targets. Stop.\n";
        }
    } else {
        # Build specified targets
        foreach my $target (@targets) {
            build_target($target);
        }
    }

    # If in report mode, run make-cmp and save output
    if ($report) {
        tee_print("\n" . "=" x 50 . "\n");
        tee_print("Running make-cmp...\n");
        tee_print("=" x 50 . "\n");

        my $makecmp_output = "$report_dir/make-cmp.txt";
        my $makecmp_result = `make-cmp 2>&1`;

        # Save make-cmp output to file
        if (defined $makecmp_result && length($makecmp_result) > 0) {
            open(my $mc_fh, '>', $makecmp_output) or warn "Cannot write to $makecmp_output: $!\n";
            print $mc_fh $makecmp_result if $mc_fh;
            close($mc_fh) if $mc_fh;

            # Display make-cmp output
            tee_print($makecmp_result);
        } else {
            tee_print("(make-cmp produced no output)\n");
            # Still create the file, even if empty
            open(my $mc_fh, '>', $makecmp_output);
            close($mc_fh) if $mc_fh;
        }

        tee_print("\n=== BUILD REPORT COMPLETE ===\n");
        tee_print("Log saved to: $report_dir/build.log\n");
        tee_print("make-cmp output: $makecmp_output\n");
        close($log_fh) if $log_fh;
    }

    exit 0;
}

# Debug mode - enter interactive debugger
interactive_debug();
