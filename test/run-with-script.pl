#!/usr/bin/env perl
# Standalone script runner for automated interactive tests using PTY
# Usage: run-with-script.pl <script-file> <test-command>

use strict;
use warnings;
use IO::Pty;
use IO::Select;
use POSIX ":sys_wait_h";
use Time::HiRes qw(sleep time);
use Cwd 'abs_path';

my ($script_file, @test_cmd) = @ARGV;

if (!$script_file || !@test_cmd) {
    die "Usage: $0 <script-file> <test-command>\n";
}

my $VERBOSE = $ENV{TEST_VERBOSE} || 0;

sub vprint {
    print STDERR @_ if $VERBOSE;
}

# Parse script file with expect-like directives
sub parse_script_file {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Cannot open script file $file: $!\n";
    my @actions;

    while (my $line = <$fh>) {
        chomp $line;

        # Skip blank lines
        next if $line =~ /^\s*$/;

        # Check for directive comments first, then regular commands
        if ($line =~ /^\s*#\s*wait\s+(\d+)(ms|s)?\s*$/i) {
            my $duration = $1;
            my $unit = $2 || 'ms';
            $duration = $duration / 1000 if $unit eq 'ms';
            push @actions, { type => 'wait', duration => $duration };

        } elsif ($line =~ /^\s*#\s*send\s+\^([A-Z])\s*$/i) {
            my $char = uc($1);
            my $ctrl_char = chr(ord($char) - ord('A') + 1);
            push @actions, { type => 'send_ctrl', char => $ctrl_char, display => "^$char" };

        } elsif ($line =~ /^\s*#\s*expect\s+"([^"]+)"\s*$/i || $line =~ /^\s*#\s*expect\s+'([^']+)'\s*$/i) {
            my $text = $1;
            push @actions, { type => 'expect', text => $text };

        } elsif ($line =~ /^\s*#\s*waitfor\s+"([^"]+)"\s+(\d+)(ms|s)?\s*$/i ||
                 $line =~ /^\s*#\s*waitfor\s+'([^']+)'\s+(\d+)(ms|s)?\s*$/i) {
            my $text = $1;
            my $duration = $2;
            my $unit = $3 || 's';
            $duration = $duration / 1000 if $unit eq 'ms';
            push @actions, { type => 'waitfor', text => $text, timeout => $duration };

        } else {
            # Skip non-directive comment lines
            next if $line =~ /^\s*#/;

            # Strip trailing comments from command lines
            $line =~ s/\s*#.*$//;
            next if $line =~ /^\s*$/;
            push @actions, { type => 'command', text => $line };
        }
    }

    close($fh);
    return \@actions;
}

# Run command with script using PTY
my $actions = parse_script_file($script_file);
my $cmd = join(' ', @test_cmd);

vprint "Running with script (PTY): $cmd (script: $script_file)\n";

# Create pseudo-terminal
my $pty = IO::Pty->new();
die "Cannot create PTY: $!\n" unless $pty;

my $pid = fork();
die "Fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    # Child process
    $pty->make_slave_controlling_terminal();
    my $slave = $pty->slave();

    close($pty);

    open(STDIN, "<&", $slave->fileno()) or die "Cannot dup stdin: $!";
    open(STDOUT, ">&", $slave->fileno()) or die "Cannot dup stdout: $!";
    open(STDERR, ">&", $slave->fileno()) or die "Cannot dup stderr: $!";

    close($slave);

    exec($cmd) or die "Exec failed: $!";
}

# Parent process
my $output = '';
my $pending_output = '';
my $test_failed = 0;
my $failure_reason = '';
my $start = time();
my $timeout = 30;
my $action_index = 0;
my $last_output_time = time();

my $sel = IO::Select->new($pty);

while (time() - $start < $timeout) {
    my @ready = $sel->can_read(0.1);

    for my $fh (@ready) {
        my $data;
        my $n = sysread($fh, $data, 4096);
        if ($n) {
            $output .= $data;
            $pending_output .= $data;
            print $data unless $VERBOSE;  # Show output
            $last_output_time = time();
        } else {
            $sel->remove($fh);
        }
    }

    # Process next action
    if ($action_index < @$actions) {
        my $action = $actions->[$action_index];

        if ($action->{type} eq 'wait') {
            vprint ">>> Waiting $action->{duration}s\n";
            sleep($action->{duration});
            $action_index++;

        } elsif ($action->{type} eq 'send_ctrl') {
            vprint ">>> Sending $action->{display}\n";
            kill('INT', $pid) if $action->{display} eq '^C';
            kill('TSTP', $pid) if $action->{display} eq '^Z';
            syswrite($pty, "\x04") if $action->{display} eq '^D';
            $action_index++;

        } elsif ($action->{type} eq 'expect') {
            if ($pending_output =~ /\Q$action->{text}\E/) {
                vprint ">>> Found expected text: '$action->{text}'\n";
                # Don't clear pending_output - keep any prompt that may be there
                $action_index++;
            } elsif (time() - $last_output_time > 5) {
                $test_failed = 1;
                $failure_reason = "Expected text not found: '$action->{text}'";
                print STDERR "FAIL: $failure_reason\n";
                last;
            }

        } elsif ($action->{type} eq 'waitfor') {
            my $wait_start = time();
            my $found = 0;
            while (time() - $wait_start < $action->{timeout}) {
                if ($pending_output =~ /\Q$action->{text}\E/) {
                    vprint ">>> Found text: '$action->{text}'\n";
                    $found = 1;
                    last;
                }
                sleep(0.1);

                my @ready = $sel->can_read(0.1);
                for my $fh (@ready) {
                    my $data;
                    my $n = sysread($fh, $data, 4096);
                    if ($n) {
                        $output .= $data;
                        $pending_output .= $data;
                        print $data unless $VERBOSE;
                    }
                }
            }

            if (!$found) {
                $test_failed = 1;
                $failure_reason = "Timeout waiting for: '$action->{text}'";
                print STDERR "FAIL: $failure_reason\n";
                last;
            }
            $pending_output = '';
            $action_index++;

        } elsif ($action->{type} eq 'command') {
            # Wait for prompt before sending command
            if ($pending_output =~ /smak>|smak-attach>/) {
                vprint ">>> Sending: $action->{text}\n";
                syswrite($pty, "$action->{text}\n");
                $pending_output = '';
                $action_index++;
            }
        }
    }

    # Check if process exited
    my $kid = waitpid($pid, WNOHANG);
    if ($kid > 0) {
        vprint "Process exited\n";
        last;
    }

    # If we've processed all actions and no output for 2 seconds, we're done
    if ($action_index >= @$actions && time() - $last_output_time > 2) {
        vprint "All actions complete and idle, exiting\n";
        last;
    }
}

# Kill if still running
if (kill(0, $pid)) {
    vprint "Killing process\n";
    kill('TERM', $pid);
    sleep(0.5);
    if (kill(0, $pid)) {
        kill('KILL', $pid);
    }
    waitpid($pid, 0);
}

my $exit_code = $? >> 8;
exit($test_failed ? 1 : $exit_code);
