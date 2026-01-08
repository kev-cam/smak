package SmakWorker;
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use POSIX qw(:sys_wait_h);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy move);
use Cwd;
use IO::Select;
use Time::HiRes qw(sleep);

# Analyze command failures and determine if they're acceptable
sub is_acceptable_failure {
    my ($command, $exit_code, $dir) = @_;

    return 0 if $exit_code == 0;  # Not a failure

    # mkdir: if directory exists after command, treat as success
    if ($command =~ /^\s*mkdir\s+(.+)/) {
        my $target_dir = $1;
        $target_dir =~ s/\s+$//;  # Trim trailing whitespace

        # Check if directory exists
        my $full_path = "$dir/$target_dir";
        $full_path =~ s{/+}{/}g;  # Normalize path

        if (-d $full_path) {
            print STDERR "mkdir failed but directory '$target_dir' exists, treating as success\n";
            return 1;
        }
    }

    return 0;
}

# Determine if an error looks like a transient failure worth retrying
sub is_transient_failure {
    my ($output) = @_;

    # Compiler errors about missing input files (race condition)
    return 1 if $output =~ /fatal error:.*No such file or directory/i;
    return 1 if $output =~ /error:.*No such file or directory/i;
    return 1 if $output =~ /cannot open.*No such file or directory/i;

    # Linker errors about missing object files
    return 1 if $output =~ /cannot find.*\.o\b/i;

    return 0;
}

# Worker entry point - to be called after fork()
# Parameters: ($host, $port, $is_dry_run)
sub run_worker {
    my ($host, $port, $is_dry_run) = @_;
    
    # Set up connection to job master
    print STDERR "Worker connecting to $host:$port...\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
    my $socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "Cannot connect to master at $host:$port: $!\n";

    $socket->autoflush(1);
    # Disable Nagle's algorithm for low latency
    setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1) if !$is_dry_run;
    print STDERR "Worker connected to master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';

    # Send ready signal
    print $socket "READY\n";
    $socket->flush() if $is_dry_run;

    # Receive environment from master
    my $env_done = 0;
    while (my $line = <$socket>) {
        chomp $line;
        
        if ($line eq 'ENV_START') {
            next;
        } elsif ($line eq 'ENV_END') {
            $env_done = 1;
            print STDERR "Worker received environment\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
            last;
        } elsif ($line =~ /^ENV (\w+)=(.*)$/) {
            $ENV{$1} = $2;
        }
    }

    die "Connection closed before environment received\n" unless $env_done;

    # Main worker loop
    while (my $line = <$socket>) {
        chomp $line;

        # Check for shutdown signal
        if ($line eq 'SHUTDOWN') {
            print STDERR "Worker shutting down on master request\n";
            last;
        }

        # Handle CLI owner change
        if ($line =~ /^CLI_OWNER (\d+)$/) {
            $ENV{SMAK_CLI_PID} = $1;
            next;
        }

        # Handle task
        if ($line =~ /^TASK (\d+)$/) {
            my $task_id = $1;
            
            # Get directory
            my $dir_line = <$socket>;
            chomp $dir_line;
            die "Expected DIR line, got: $dir_line\n" unless $dir_line =~ /^DIR (.*)$/;
            my $dir = $1;
            
            # Get command
            my $cmd_line = <$socket>;
            chomp $cmd_line;
            die "Expected CMD line, got: $cmd_line\n" unless $cmd_line =~ /^CMD (.*)$/;
            my $command = $1;

            # Change to directory
            my $old_dir = getcwd();
            unless (chdir($dir)) {
                print $socket "TASK_START $task_id\n";
                print $socket "OUTPUT ERROR: Cannot chdir to $dir: $!\n";
                print $socket "TASK_END $task_id 1\n";
                print $socket "READY\n";
                next;
            }
            
            # Signal task start
            print $socket "TASK_START $task_id\n";
            $socket->flush();

            my $exit_code = 0;
            
            if ($is_dry_run) {
                # DRY-RUN MODE: Just print command
                warn "DRY-RUN WORKER: task_id=$task_id, command=$command\n" if $ENV{SMAK_DEBUG};
                print $socket "OUTPUT $command\n";
                $socket->flush();
            } else {
                # REGULAR MODE: Execute command
                warn "WORKER DEBUG: dir='$dir', command='$command'\n" if $ENV{SMAK_DEBUG};
                my $pid = open(my $cmd_fh, '-|', "$command 2>&1");
                if ($pid) {
                    while (my $out_line = <$cmd_fh>) {
                        chomp $out_line;
                        print $socket "OUTPUT $out_line\n";
                    }
                    close($cmd_fh);
                    $exit_code = $? >> 8;
                } else {
                    print $socket "OUTPUT ERROR: Cannot execute command: $!\n";
                    $exit_code = 1;
                }
            }

            # Send completion
            print $socket "TASK_END $task_id $exit_code\n";
            $socket->flush() if $is_dry_run;
            
            # Send ready for next task
            print $socket "READY\n";
            $socket->flush() if $is_dry_run;
            
            # Restore directory
            chdir($old_dir);
        }
    }
    
    print STDERR "Worker disconnected from master\n" if $ENV{SMAK_VERBOSE} && $ENV{SMAK_VERBOSE} ne 'w';
    exit 0;
}

1;
