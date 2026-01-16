#!/usr/bin/perl
# smak-ps - Show smak process tree with job details
use strict;
use warnings;

# Find all smak-worker processes and extract their server PIDs
my %server_pids;
my %worker_info;

# Get worker processes with their full command line
open(my $pgrep, '-|', 'pgrep', '-a', 'smak-') or die "pgrep failed: $!\n";
while (<$pgrep>) {
    chomp;
    my ($pid, $cmd) = /^(\d+)\s+(.*)$/;
    next unless $pid;

    if ($cmd =~ /^smak-server/) {
        $server_pids{$pid} = 1;
    }
    elsif ($cmd =~ /^smak-worker\s+for\s+(\S+):(\d+)/) {
        my ($host, $server_pid) = ($1, $2);
        $server_pids{$server_pid} = 1;
        push @{$worker_info{$server_pid}}, { pid => $pid, host => $host };
    }
    elsif ($cmd =~ /^smak-watcher/) {
        # Track watchers too
    }
}
close($pgrep);

if (!%server_pids) {
    print "No smak servers found.\n";
    exit 0;
}

# For each server, show its tree
for my $server_pid (sort { $a <=> $b } keys %server_pids) {
    # Check if server is still alive and not a zombie
    next unless -d "/proc/$server_pid";

    # Check process state - skip zombies
    my $state = '';
    if (open(my $fh, '<', "/proc/$server_pid/stat")) {
        my $stat = <$fh>;
        close($fh);
        ($state) = $stat =~ /^\d+\s+\([^)]+\)\s+(\S+)/ if $stat;
    }
    next if $state eq 'Z';  # Skip zombie processes

    # Get server's working directory
    my $cwd = readlink("/proc/$server_pid/cwd") || '?';
    next if $cwd eq '?';  # Skip if can't read cwd (likely defunct)

    # Get server's cmdline for context
    my $cmdline = '';
    if (open(my $fh, '<', "/proc/$server_pid/cmdline")) {
        local $/;
        $cmdline = <$fh>;
        $cmdline =~ s/\0/ /g if $cmdline;
        close($fh);
    }

    print "=" x 60, "\n";
    print "smak-server [$server_pid] $cwd\n";
    print "=" x 60, "\n";

    # Get workers for this server
    my @workers = @{$worker_info{$server_pid} || []};

    if (@workers) {
        print "  Workers: ", scalar(@workers), "\n";

        for my $w (@workers) {
            my $wpid = $w->{pid};
            my $status = get_worker_status($wpid);
            print "  ├─ worker [$wpid] $status\n";

            # Show children (actual build commands)
            my @children = get_children($wpid);
            for my $i (0 .. $#children) {
                my $child = $children[$i];
                my $prefix = ($i == $#children) ? "  │     └─" : "  │     ├─";
                my $child_cmd = get_cmdline($child, "  │       ");
                print "$prefix [$child] $child_cmd\n";
            }
        }
    } else {
        print "  Workers: (none connected)\n";
    }

    print "\n";
}

# Get worker status (idle/busy)
sub get_worker_status {
    my ($pid) = @_;
    my @children = get_children($pid);
    if (@children) {
        return "busy (" . scalar(@children) . " job" . (@children > 1 ? "s" : "") . ")";
    }
    return "idle";
}

# Get child PIDs of a process
sub get_children {
    my ($ppid) = @_;
    my @children;

    # Read /proc to find children
    opendir(my $dh, '/proc') or return ();
    for my $entry (readdir($dh)) {
        next unless $entry =~ /^\d+$/;
        my $stat_file = "/proc/$entry/stat";
        next unless -r $stat_file;

        open(my $fh, '<', $stat_file) or next;
        my $stat = <$fh>;
        close($fh);

        # stat format: pid (comm) state ppid ...
        if ($stat =~ /^\d+\s+\([^)]+\)\s+\S+\s+(\d+)/) {
            push @children, $entry if $1 == $ppid;
        }
    }
    closedir($dh);

    return sort { $a <=> $b } @children;
}

# Get command line for a PID, formatted with line breaks
sub get_cmdline {
    my ($pid, $indent) = @_;
    $indent //= '';

    my $cmdline_file = "/proc/$pid/cmdline";
    return '?' unless -r $cmdline_file;

    open(my $fh, '<', $cmdline_file) or return '?';
    local $/;
    my $cmdline = <$fh>;
    close($fh);

    return '?' unless $cmdline;
    $cmdline =~ s/\0/ /g;
    $cmdline =~ s/^\s+|\s+$//g;

    # Compact multiple whitespace to single space
    $cmdline =~ s/\s+/ /g;

    # Format pipelines and command chains with line breaks
    # Only break on shell operators with surrounding whitespace to avoid
    # matching sed delimiters like s|foo|bar| or sed command separators
    my $cont_indent = $indent . "        ";  # Extra indent for continuation
    $cmdline =~ s/ \| /\n$cont_indent| /g;
    $cmdline =~ s/ && /\n$cont_indent&& /g;
    $cmdline =~ s/; /;\n$cont_indent/g;

    return $cmdline;
}
