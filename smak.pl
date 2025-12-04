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

    # Create smak.env file with environment variables for reproducing the build
    my $env_file = "$report_dir/smak.env";
    open(my $env_fh, '>', $env_file) or warn "Cannot create $env_file: $!\n";
    if ($env_fh) {
        print $env_fh "# Smak environment variables for bug report $timestamp\n";
        print $env_fh "# Source this file with: source smak.env\n\n";

        # Export smak-specific variables
        print $env_fh "export SMAK_INVOKED_AS='$ENV{SMAK_INVOKED_AS}'\n" if $ENV{SMAK_INVOKED_AS};
        print $env_fh "export SMAK_LAUNCHER='$ENV{SMAK_LAUNCHER}'\n" if $ENV{SMAK_LAUNCHER};

        # Export relevant build environment variables
        print $env_fh "export PATH='$ENV{PATH}'\n" if $ENV{PATH};
        print $env_fh "export SHELL='$ENV{SHELL}'\n" if $ENV{SHELL};
        print $env_fh "export USER='$ENV{USER}'\n" if $ENV{USER};
        print $env_fh "export HOME='$ENV{HOME}'\n" if $ENV{HOME};
        print $env_fh "export PWD='$ENV{PWD}'\n" if $ENV{PWD};

        # Export any USR_SMAK_OPT if set
        print $env_fh "export USR_SMAK_OPT='$ENV{USR_SMAK_OPT}'\n" if $ENV{USR_SMAK_OPT};

        close($env_fh);
    }

    # Copy Makefile(s) to bug directory for analysis
    use File::Copy;
    if (-f $makefile) {
        my $makefile_copy = "$report_dir/" . (split(/\//, $makefile))[-1];
        copy($makefile, $makefile_copy) or warn "Could not copy $makefile: $!\n";
    }

    # Capture directory listing for filesystem reconstruction
    my $listing_file = "$report_dir/directory-listing.txt";
    my $cwd = $ENV{PWD} || `pwd`;
    chomp $cwd;
    my $listing = `ls -lR . 2>&1`;
    open(my $listing_fh, '>', $listing_file) or warn "Cannot create $listing_file: $!\n";
    if ($listing_fh) {
        print $listing_fh "Directory listing from: $cwd\n";
        print $listing_fh "=" x 50 . "\n\n";
        print $listing_fh $listing;
        close($listing_fh);
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
    my $build_failed = 0;
    my $build_error = '';

    # Wrap build in eval to catch failures but still allow report prompt
    eval {
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
    };

    # Check if build failed
    if ($@) {
        $build_failed = 1;
        $build_error = $@;
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

        # Ask user if they want to commit the bug report (even if build failed)
        prompt_commit_bug_report($report_dir);

        # If build failed, exit with error after prompt
        if ($build_failed) {
            exit 1;
        }
    } else {
        # Not in report mode - re-throw the build error if it failed
        if ($build_failed) {
            die $build_error;
        }
    }

    exit 0;
}

sub prompt_commit_bug_report {
    my ($report_dir) = @_;

    # Check if running interactively (has a terminal)
    if (!-t STDIN) {
        print "\nNote: Not running interactively, skipping commit prompt.\n";
        return;
    }

    # Save current directory
    use Cwd;
    my $original_dir = getcwd();

    # Change to smak directory (where bugs/ is located)
    chdir($RealBin) or do {
        warn "Warning: Cannot change to smak directory $RealBin: $!\n";
        return;
    };

    # Check if we're in a git repository
    my $in_git_repo = system("git rev-parse --git-dir >/dev/null 2>&1") == 0;

    if (!$in_git_repo) {
        print "\nNote: Not in a git repository, skipping commit prompt.\n";
        chdir($original_dir);
        return;
    }

    print "\n";
    print "=" x 50 . "\n";
    print "Commit bug report to repository?\n";
    print "=" x 50 . "\n";
    print "Report directory: $report_dir\n\n";
    print "Do you want to commit this bug report to the git repository? (y/N): ";

    my $response = <STDIN>;
    chomp($response) if defined $response;

    if ($response && $response =~ /^[Yy]/) {
        print "\nCommitting bug report...\n";

        # Get current branch name
        my $branch = `git branch --show-current`;
        chomp($branch);

        # Extract timestamp from report directory
        my $timestamp = (split(/\//, $report_dir))[-1];

        # Get relative path for git (bugs/timestamp)
        my $git_path = "bugs/$timestamp";

        # Add the bug report directory (force add since bugs/ is in .gitignore)
        my $add_result = system("git add -f $git_path");
        if ($add_result != 0) {
            warn "Warning: Failed to add bug report to git. Continue anyway? (y/N): ";
            my $cont = <STDIN>;
            chomp($cont) if defined $cont;
            chdir($original_dir);
            return unless $cont && $cont =~ /^[Yy]/;
        }

        # Create commit message
        my $commit_msg = "Add bug report $timestamp\n\n" .
                        "Generated by smak -Kreport\n" .
                        "Makefile: $makefile\n" .
                        "Report directory: $report_dir\n";

        # Commit
        my $commit_result = system("git", "commit", "-m", $commit_msg);
        if ($commit_result != 0) {
            warn "Warning: Failed to commit bug report.\n";
            chdir($original_dir);
            return;
        }

        print "Bug report committed successfully.\n";

        # Ask if they want to push
        print "\nPush to remote repository? (y/N): ";
        my $push_response = <STDIN>;
        chomp($push_response) if defined $push_response;

        if ($push_response && $push_response =~ /^[Yy]/) {
            print "\nPushing to remote...\n";
            my $push_result = system("git push origin $branch");
            if ($push_result == 0) {
                print "Bug report pushed successfully.\n";
            } else {
                warn "Warning: Failed to push to remote.\n";
            }
        } else {
            print "Skipping push. You can push later with: git push origin $branch\n";
        }
    } else {
        print "Skipping commit.\n";
    }

    # Return to original directory
    chdir($original_dir);
}

# Debug mode - enter interactive debugger
interactive_debug();
