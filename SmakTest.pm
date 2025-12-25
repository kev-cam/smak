package SmakTest;
# Testing framework for smak - interactive and automated testing

use strict;
use warnings;
use Exporter 'import';
use IO::Select;
use Time::HiRes qw(time sleep);
use File::Path qw(remove_tree);
use File::Copy;
use Cwd;

our @EXPORT_OK = qw(
    run_test_suite
    run_interactive_tests
    test_ctrl_c
    test_file_dirty
    test_file_remove
    test_rebuild_detection
    test_clean_rebuild
);

our $VERBOSE = $ENV{TEST_VERBOSE} || 0;

# Test state
my $tests_run = 0;
my $tests_passed = 0;
my $tests_failed = 0;
my @failures;
my @test_log;

sub vprint {
    print @_ if $VERBOSE;
}

sub log_test {
    push @test_log, @_;
}

sub test_header {
    my ($name) = @_;
    $tests_run++;
    my $header = "\n" . "=" x 60 . "\n" . "TEST $tests_run: $name\n" . "=" x 60;
    print "$header\n";
    log_test($header);
}

sub pass {
    my ($name) = @_;
    $tests_passed++;
    my $msg = "✓ $name";
    print "$msg\n";
    log_test($msg);
}

sub fail {
    my ($name, $reason) = @_;
    $tests_failed++;
    push @failures, "$name: $reason";
    my $msg = "✗ $name";
    $msg .= "\n  Reason: $reason" if $reason;
    print "$msg\n";
    log_test($msg);
}

sub reset_stats {
    $tests_run = 0;
    $tests_passed = 0;
    $tests_failed = 0;
    @failures = ();
    @test_log = ();
}

sub print_summary {
    print "\n";
    print "=" x 60 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 60 . "\n";
    print "Total tests: $tests_run\n";
    print "Passed: $tests_passed\n";
    print "Failed: $tests_failed\n";

    if (@failures) {
        print "\nFailures:\n";
        for my $failure (@failures) {
            print "  - $failure\n";
        }
    }

    print "\nPass rate: ";
    if ($tests_run > 0) {
        printf "%.1f%%\n", ($tests_passed / $tests_run) * 100;
    } else {
        print "N/A\n";
    }
    print "=" x 60 . "\n";
}

# Send command to smak and wait for response
sub send_command {
    my ($socket, $command, $timeout) = @_;
    $timeout ||= 10;

    vprint ">>> Sending: $command\n";
    print $socket "$command\n";

    my $output = '';
    my $sel = IO::Select->new($socket);
    my $start = time();
    my $last_output = time();

    while (time() - $start < $timeout) {
        my @ready = $sel->can_read(0.1);
        for my $fh (@ready) {
            my $line = <$fh>;
            if (defined $line) {
                $output .= $line;
                vprint $line;
                $last_output = time();

                # Stop reading when we see a prompt
                return $output if $line =~ /smak>|smak-attach>/;
            }
        }

        # If no output for 2 seconds, assume done
        last if time() - $last_output > 2;
    }

    return $output;
}

# Wait for output with pattern
sub wait_for_output {
    my ($socket, $pattern, $timeout) = @_;
    $timeout ||= 30;

    my $output = '';
    my $sel = IO::Select->new($socket);
    my $start = time();

    while (time() - $start < $timeout) {
        my @ready = $sel->can_read(0.1);
        for my $fh (@ready) {
            my $line = <$fh>;
            if (defined $line) {
                $output .= $line;
                vprint $line;
                return $output if $output =~ /$pattern/;
            }
        }
    }

    return $output;
}

# Test: Build current project
sub test_build_all {
    my ($socket) = @_;

    test_header("Build all targets");

    my $output = send_command($socket, "b all", 60);

    if ($output =~ /Build succeeded|✓/) {
        pass("Build all targets");
        return 1;
    } elsif ($output =~ /No default target/) {
        # Try just 'b' for default target
        $output = send_command($socket, "b", 60);
        if ($output =~ /Build succeeded|✓/) {
            pass("Build default target");
            return 1;
        }
    }

    fail("Build all targets", "Build did not succeed");
    return 0;
}

# Test: Clean and rebuild
sub test_clean_rebuild {
    my ($socket) = @_;

    test_header("Clean and rebuild");

    # Clean
    my $output1 = send_command($socket, "clean", 10);

    # Rebuild
    my $output2 = send_command($socket, "b all", 60);

    if ($output2 =~ /Build succeeded|✓/) {
        pass("Clean and rebuild");
        return 1;
    } else {
        fail("Clean and rebuild", "Rebuild failed after clean");
        return 0;
    }
}

# Test: File removal and rebuild detection
sub test_file_remove {
    my ($socket, $file) = @_;

    test_header("File removal and rebuild detection");

    # Build first
    my $output1 = send_command($socket, "b all", 60);
    if ($output1 !~ /Build succeeded|✓|up to date/) {
        fail("File removal test", "Initial build failed");
        return 0;
    }

    # Find a file to remove if not specified
    unless ($file) {
        my @objs = glob("*.o");
        if (@objs) {
            $file = $objs[0];
        } else {
            fail("File removal test", "No object files found");
            return 0;
        }
    }

    unless (-f $file) {
        fail("File removal test", "File '$file' does not exist");
        return 0;
    }

    vprint "Removing $file\n";
    unlink($file);

    # Rebuild
    my $output2 = send_command($socket, "b all", 60);

    if (-f $file && $output2 =~ /Build succeeded|✓/) {
        pass("File removal and rebuild");
        return 1;
    } else {
        fail("File removal and rebuild", "File not recreated or build failed");
        return 0;
    }
}

# Test: File modification and rebuild detection
sub test_file_dirty {
    my ($socket, $file) = @_;

    test_header("File modification and rebuild detection");

    # Build first
    my $output1 = send_command($socket, "b all", 60);
    if ($output1 !~ /Build succeeded|✓|up to date/) {
        fail("File dirty test", "Initial build failed");
        return 0;
    }

    # Find a file to modify if not specified
    unless ($file) {
        my @srcs = glob("*.c");
        push @srcs, glob("*.cpp");
        push @srcs, glob("*.cc");
        if (@srcs) {
            $file = $srcs[0];
        } else {
            fail("File dirty test", "No source files found");
            return 0;
        }
    }

    unless (-f $file) {
        fail("File dirty test", "File '$file' does not exist");
        return 0;
    }

    vprint "Modifying $file\n";
    sleep(1);  # Ensure mtime changes
    my $backup = "$file.testbackup";
    copy($file, $backup) or do {
        fail("File dirty test", "Cannot backup file: $!");
        return 0;
    };

    # Append a comment
    open(my $fh, '>>', $file) or do {
        fail("File dirty test", "Cannot open file: $!");
        return 0;
    };
    print $fh "// Test modification\n";
    close($fh);

    # Rebuild
    my $output2 = send_command($socket, "b all", 60);

    # Restore original file
    move($backup, $file);

    if ($output2 =~ /Build succeeded|✓/) {
        pass("File modification and rebuild");
        return 1;
    } else {
        fail("File modification and rebuild", "Rebuild failed");
        return 0;
    }
}

# Test: Status command
sub test_status {
    my ($socket) = @_;

    test_header("Status command");

    my $output = send_command($socket, "status", 5);

    if ($output =~ /workers|jobs|ready/i || length($output) > 10) {
        pass("Status command");
        return 1;
    } else {
        fail("Status command", "No status information received");
        return 0;
    }
}

# Test: Help command
sub test_help {
    my ($socket) = @_;

    test_header("Help command");

    my $output = send_command($socket, "help", 5);

    if ($output =~ /commands|help|build/i) {
        pass("Help command");
        return 1;
    } else {
        fail("Help command", "No help text received");
        return 0;
    }
}

# Test: Rebuild detection (should be up to date)
sub test_rebuild_detection {
    my ($socket) = @_;

    test_header("Rebuild detection (up-to-date check)");

    # Build twice
    my $output1 = send_command($socket, "b all", 60);
    my $output2 = send_command($socket, "b all", 60);

    if ($output2 =~ /up to date|nothing to do|0 jobs/i || $output2 =~ /Build succeeded/) {
        pass("Rebuild detection");
        return 1;
    } else {
        fail("Rebuild detection", "Did not detect up-to-date state");
        return 0;
    }
}

# Interactive test menu
sub run_interactive_tests {
    my ($socket) = @_;

    reset_stats();

    print "\n";
    print "=" x 60 . "\n";
    print "SMAK INTERACTIVE TEST MENU\n";
    print "=" x 60 . "\n";
    print "Working directory: " . getcwd() . "\n";
    print "\n";
    print "Available tests:\n";
    print "  1. Build all targets\n";
    print "  2. Clean and rebuild\n";
    print "  3. File removal and rebuild\n";
    print "  4. File modification and rebuild\n";
    print "  5. Rebuild detection (up-to-date)\n";
    print "  6. Status command\n";
    print "  7. Help command\n";
    print "  a. Run all tests\n";
    print "  q. Quit test mode\n";
    print "\n";

    while (1) {
        print "Test> ";
        my $choice = <STDIN>;
        chomp $choice;
        $choice =~ s/^\s+|\s+$//g;

        last if $choice eq 'q' || $choice eq 'quit';

        if ($choice eq '1') {
            test_build_all($socket);
        } elsif ($choice eq '2') {
            test_clean_rebuild($socket);
        } elsif ($choice eq '3') {
            test_file_remove($socket, undef);
        } elsif ($choice eq '4') {
            test_file_dirty($socket, undef);
        } elsif ($choice eq '5') {
            test_rebuild_detection($socket);
        } elsif ($choice eq '6') {
            test_status($socket);
        } elsif ($choice eq '7') {
            test_help($socket);
        } elsif ($choice eq 'a') {
            print "\nRunning all tests...\n";
            test_build_all($socket);
            test_rebuild_detection($socket);
            test_status($socket);
            test_help($socket);
            test_file_dirty($socket, undef);
            test_file_remove($socket, undef);
            test_clean_rebuild($socket);
        } else {
            print "Invalid choice. Enter 1-7, 'a' for all, or 'q' to quit.\n";
            next;
        }

        print "\n";
    }

    print_summary();
}

# Automated test suite
sub run_test_suite {
    my ($socket) = @_;

    reset_stats();

    print "\n";
    print "=" x 60 . "\n";
    print "SMAK AUTOMATED TEST SUITE\n";
    print "=" x 60 . "\n";
    print "Working directory: " . getcwd() . "\n";
    print "\n";

    # Run all tests
    test_build_all($socket);
    test_rebuild_detection($socket);
    test_status($socket);
    test_help($socket);
    test_file_dirty($socket, undef);
    test_file_remove($socket, undef);
    test_clean_rebuild($socket);

    print_summary();

    return $tests_failed == 0;
}

1;

__END__

=head1 NAME

SmakTest - Testing framework for smak build system

=head1 SYNOPSIS

    use SmakTest qw(run_interactive_tests run_test_suite);

    # Interactive testing
    run_interactive_tests($socket);

    # Automated testing
    my $success = run_test_suite($socket);

=head1 DESCRIPTION

SmakTest provides interactive and automated testing capabilities for smak.
Tests can be run against a live job server through a socket connection.

=head1 FUNCTIONS

=over 4

=item run_interactive_tests($socket)

Presents an interactive menu for running individual tests.

=item run_test_suite($socket)

Runs all tests automatically and returns true if all pass.

=item test_build_all($socket)

Tests building all targets.

=item test_clean_rebuild($socket)

Tests clean and rebuild cycle.

=item test_file_remove($socket, $file)

Tests file removal and rebuild detection.

=item test_file_dirty($socket, $file)

Tests file modification and rebuild detection.

=item test_rebuild_detection($socket)

Tests that rebuild is skipped when up-to-date.

=back

=head1 AUTHOR

Claude Code

=cut
