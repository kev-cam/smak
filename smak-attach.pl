#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Cwd 'abs_path';
use Getopt::Long;
use Term::ReadLine;
use Smak qw(:all);

# Parse command-line options
my $target_pid;
my $target_port;
my $pid_arg;
my $kill_all = 0;
GetOptions(
    'pid=s' => \$pid_arg,
    'kill-all' => \$kill_all,
) or die "Usage: $0 [-pid <process-id>[:<port>]] [--kill-all]\n";

# Parse PID and optional port from -pid argument
if ($pid_arg) {
    if ($pid_arg =~ /^(\d+):(\d+)$/) {
        ($target_pid, $target_port) = ($1, $2);
    } elsif ($pid_arg =~ /^(\d+)$/) {
        $target_pid = $1;
        $target_port = undef;
    } else {
        die "Invalid -pid format. Use: -pid <process-id>[:<port>]\n";
    }
}

our @jobservers;

# Find smak-jobserver processes using port files
sub find_jobservers {
    my @jobservers;

    # Scan /tmp for port files - this is the source of truth
    my @port_files = glob("/tmp/smak-jobserver-*.port");

    for my $port_file (@port_files) {
        my ($pid) = $port_file =~ /smak-jobserver-(\d+)\.port/;
        next unless $pid;

        # Check if process is still alive
        unless (-d "/proc/$pid") {
            # Stale port file
            print STDERR "Removing stale port file: $port_file\n";
            unlink $port_file;
            next;
        }

        # Read port information
        open(my $fh, '<', $port_file) or next;
        my @ports;
        while (my $line = <$fh>) {
            chomp $line;
            push @ports, $line if $line =~ /^\d+$/;
        }
        close($fh);

        next unless @ports >= 2;  # Need at least observer and master ports
        my ($observer_port, $master_port) = @ports;

        # Get process info
        my $cmdline_file = "/proc/$pid/cmdline";
        my $cmdline = '';
        if (open(my $cmd_fh, '<', $cmdline_file)) {
            $cmdline = <$cmd_fh>;
            close($cmd_fh);
            if (defined $cmdline) {
                $cmdline =~ s/\0/ /g;
                $cmdline =~ s/\s+$//;
            } else {
                $cmdline = '';
            }
        }

        # Get working directory
        my $cwd = readlink("/proc/$pid/cwd");

        # Try to determine number of workers from lsof (count worker connections)
        my $num_workers = 0;
        my $lsof_output = `lsof -Pan -p $pid -i TCP 2>/dev/null`;
        for my $line (split /\n/, $lsof_output) {
            $num_workers++ if $line =~ /ESTABLISHED/;
        }

        push @jobservers, {
            pid => $pid,
            workers => $num_workers,
            cwd => $cwd,
            cmdline => $cmdline,
            observer_port => $observer_port,
            master_port => $master_port,
        };
    }

    return @jobservers;
}

# Kill specific job servers by index
sub kill_jobservers {
    my @indices = @_;
    my $killed = 0;
    my $failed = 0;

    for my $idx (@indices) {
        my $js = $jobservers[$idx];
        unless ($js) {
            print "Invalid index: $idx\n";
            $failed++;
            next;
        }

        my $pid = $js->{pid};
        my $master_port = $js->{master_port};

        print "Killing job server [$idx] PID $pid";
        print " ($js->{cwd})" if $js->{cwd};
        print "... ";

        # Try to connect and send SHUTDOWN command
        my $socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $master_port,
            Proto    => 'tcp',
            Timeout  => 2,
        );

        if ($socket) {
            $socket->autoflush(1);
            print $socket "SHUTDOWN\n";

            # Wait briefly for acknowledgment
            my $select = IO::Select->new($socket);
            if ($select->can_read(1)) {
                my $ack = <$socket>;
            }
            close($socket);

            # Wait for process to exit (up to 2 seconds)
            my $wait_time = 0;
            while (-d "/proc/$pid" && $wait_time < 20) {
                select(undef, undef, undef, 0.1);
                $wait_time++;
            }

            if (-d "/proc/$pid") {
                print "timed out, sending SIGTERM\n";
                kill 'TERM', $pid;
                sleep 1;
                if (-d "/proc/$pid") {
                    print "Warning: Process $pid still running\n";
                    $failed++;
                } else {
                    $killed++;
                }
            } else {
                print "done\n";
                $killed++;
            }
        } else {
            # Couldn't connect, try SIGTERM directly
            print "couldn't connect, sending SIGTERM... ";
            kill 'TERM', $pid;
            sleep 1;
            if (-d "/proc/$pid") {
                print "failed\n";
                $failed++;
            } else {
                print "done\n";
                $killed++;
            }
        }
    }

    print "\nKilled $killed job server(s)" if $killed > 0;
    print ", $failed failed" if $failed > 0;
    print "\n";
    return ($killed, $failed);
}

# Find running job-master instances
@jobservers = find_jobservers();

unless (@jobservers) {
    print STDERR "No running smak job-master instances found.\n";
    print STDERR "Check that smak is running with -j option:\n";
    print STDERR "  smak -cli -j 4\n";
    exit 1;
}

# Handle --kill-all option
if ($kill_all) {
    print "Found " . scalar(@jobservers) . " job server(s)\n";
    my $killed = 0;
    my $failed = 0;

    for my $js (@jobservers) {
        my $pid = $js->{pid};
        my $master_port = $js->{master_port};

        print "Killing job server PID $pid";
        print " ($js->{cwd})" if $js->{cwd};
        print "... ";

        # Try to connect and send SHUTDOWN command
        my $socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $master_port,
            Proto    => 'tcp',
            Timeout  => 2,
        );

        if ($socket) {
            $socket->autoflush(1);
            print $socket "SHUTDOWN\n";

            # Wait briefly for acknowledgment
            my $select = IO::Select->new($socket);
            if ($select->can_read(1)) {
                my $ack = <$socket>;
            }
            close($socket);

            # Wait for process to exit (up to 2 seconds)
            my $wait_time = 0;
            while (-d "/proc/$pid" && $wait_time < 20) {
                select(undef, undef, undef, 0.1);
                $wait_time++;
            }

            if (-d "/proc/$pid") {
                print "timed out, sending SIGTERM\n";
                kill 'TERM', $pid;
                sleep 1;
                if (-d "/proc/$pid") {
                    print "Warning: Process $pid still running\n";
                    $failed++;
                } else {
                    $killed++;
                }
            } else {
                print "done\n";
                $killed++;
            }
        } else {
            # Couldn't connect, try SIGTERM directly
            print "couldn't connect, sending SIGTERM... ";
            kill 'TERM', $pid;
            sleep 1;
            if (-d "/proc/$pid") {
                print "failed\n";
                $failed++;
            } else {
                print "done\n";
                $killed++;
            }
        }
    }

    print "\nKilled $killed job server(s)";
    print ", $failed failed" if $failed > 0;
    print "\n";
    exit($failed > 0 ? 1 : 0);
}

my $selected_js;

# If -pid was specified, find that specific job-master
if ($target_pid) {
    for my $js (@jobservers) {
        if ($js->{pid} == $target_pid) {
            $selected_js = $js;
            last;
        }
    }
    unless ($selected_js) {
        die "No job-master found with PID $target_pid\n";
    }
} elsif (@jobservers > 1) {
    # Interactive selection with help and kill commands
    while (!$selected_js) {
        print "Multiple smak instances found:\n";
        for (my $i = 0; $i < @jobservers; $i++) {
            my $js = $jobservers[$i];
            print "  [$i] PID $js->{pid}";
            print " - $js->{cwd}" if $js->{cwd};
            print "\n";
            print "      Workers: $js->{workers}";
            if ($js->{master_port}) {
                print ", Master port: $js->{master_port}";
            }
            print "\n";
        }
        print "Select instance (0-" . ($#jobservers) . ", 'h' for help): ";
        my $choice = <STDIN>;
        chomp $choice;
        $choice =~ s/^\s+|\s+$//g;  # Trim whitespace

        if ($choice eq 'h' || $choice eq 'help' || $choice eq '?') {
            # Show help
            print "\nCommands:\n";
            print "  <number>    - Attach to instance number\n";
            print "  k *         - Kill all instances\n";
            print "  k <ids>     - Kill specific instances (e.g., 'k 0 2 4')\n";
            print "  h, help, ?  - Show this help\n";
            print "  q, quit     - Exit without attaching\n\n";
        } elsif ($choice eq 'q' || $choice eq 'quit') {
            print "Exiting.\n";
            exit 0;
        } elsif ($choice =~ /^k\s+(.+)$/) {
            # Kill command
            my $args = $1;
            if ($args eq '*') {
                # Kill all
                my @all_indices = (0 .. $#jobservers);
                my ($killed, $failed) = kill_jobservers(@all_indices);
                exit($failed > 0 ? 1 : 0);
            } else {
                # Kill specific instances
                my @indices = split(/\s+/, $args);
                # Validate indices
                my @valid_indices;
                for my $idx (@indices) {
                    if ($idx =~ /^\d+$/ && $idx <= $#jobservers) {
                        push @valid_indices, $idx;
                    } else {
                        print "Invalid index: $idx (must be 0-" . $#jobservers . ")\n";
                    }
                }
                if (@valid_indices) {
                    my ($killed, $failed) = kill_jobservers(@valid_indices);
                    # Refresh the list
                    @jobservers = find_jobservers();
                    unless (@jobservers) {
                        print "No more job servers running.\n";
                        exit 0;
                    }
                }
            }
        } elsif ($choice =~ /^\d+$/ && $choice <= $#jobservers) {
            # Valid numeric selection
            $selected_js = $jobservers[$choice];
        } else {
            print "Invalid selection. Type 'h' for help.\n\n";
        }
    }
} else {
    $selected_js = $jobservers[0];
}

my $jobserver_pid = $selected_js->{pid};
my $master_port = $selected_js->{master_port};
my $observer_port = $selected_js->{observer_port};

# Use specified port if provided, otherwise prefer master port for CLI mode
my $port;
if ($target_port) {
    $port = $target_port;
} else {
    $port = $master_port || $observer_port;
}
unless ($port) {
    die "Cannot determine port for job-master (PID $jobserver_pid)\n";
}

print "Connecting to job-master (PID $jobserver_pid) on port $port...\n";

# Connect to master port
my $socket = IO::Socket::INET->new(
    PeerHost => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 5,
) or die "Cannot connect to job-master: $!\n";

$socket->autoflush(1);
print "Connected to job-master\n";

# Send environment variables
for my $key (keys %ENV) {
    next if $key =~ /^(BASH_FUNC_|_)/;
    my $val = $ENV{$key};
    $val =~ s/\n/ /g;
    print $socket "ENV $key=$val\n";
}
print $socket "ENV_END\n";

# Wait for ready signal
my $ready = <$socket>;
chomp $ready if defined $ready;
unless ($ready && $ready eq 'JOBSERVER_WORKERS_READY') {
    die "Job-master not ready (got: " . ($ready || "EOF") . ")\n";
}

print "Job-master ready. Entering CLI mode.\n";
print "Working directory: $selected_js->{cwd}\n" if $selected_js->{cwd};
print "Workers: $selected_js->{workers}\n\n";

my $prompt = 'smak-attach> ';

my $term = Term::ReadLine->new($prompt);

server_cli($jobserver_pid,$socket,$prompt,$term,$selected_js);

close($socket);
exit 0;
