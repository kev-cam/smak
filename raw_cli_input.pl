#!/usr/bin/perl
# Raw terminal input handler for smak CLI
# Provides line editing with async notification support

package RawCLI;

use strict;
use warnings;
use POSIX qw(:termios_h);
use IO::Select;

sub new {
    my ($class, %opts) = @_;

    my $self = {
        prompt => $opts{prompt} || '> ',
        history_file => $opts{history_file} || '.smak_history',
        socket => $opts{socket},  # For async notifications
        check_notifications => $opts{check_notifications},
        history => [],
        history_pos => -1,
        max_history => 1000,
        termios => undef,
        orig_termios => undef,
    };

    bless $self, $class;
    $self->load_history();
    return $self;
}

# Set terminal to raw mode
sub set_raw_mode {
    my ($self) = @_;

    # Save original terminal settings
    $self->{orig_termios} = POSIX::Termios->new();
    $self->{orig_termios}->getattr(0);  # 0 = STDIN

    # Create new settings for raw mode
    $self->{termios} = POSIX::Termios->new();
    $self->{termios}->getattr(0);

    # Disable canonical mode and echo
    my $lflag = $self->{termios}->getlflag();
    $lflag &= ~(ICANON | ECHO | ECHOE | ECHOK | ECHONL);
    $self->{termios}->setlflag($lflag);

    # Set minimum characters and timeout for read
    $self->{termios}->setcc(VMIN, 0);   # Non-blocking read
    $self->{termios}->setcc(VTIME, 1);  # 0.1 second timeout

    # Apply new settings
    $self->{termios}->setattr(0, TCSANOW);
}

# Restore terminal to original mode
sub restore_mode {
    my ($self) = @_;
    return unless $self->{orig_termios};
    $self->{orig_termios}->setattr(0, TCSANOW);
}

# Read a single character (non-blocking)
sub read_char {
    my ($self) = @_;
    my $char;
    my $nread = sysread(STDIN, $char, 1);
    return undef unless $nread;
    return $char;
}

sub load_history {
    my ($self) = @_;
    return unless -f $self->{history_file};

    open(my $fh, '<', $self->{history_file}) or return;
    while (my $line = <$fh>) {
        chomp $line;
        push @{$self->{history}}, $line if $line =~ /\S/;
    }
    close($fh);

    # Keep only last max_history items
    if (@{$self->{history}} > $self->{max_history}) {
        splice(@{$self->{history}}, 0, @{$self->{history}} - $self->{max_history});
    }
}

sub save_history {
    my ($self) = @_;

    open(my $fh, '>', $self->{history_file}) or do {
        warn "Cannot save history: $!\n";
        return;
    };

    # Save last max_history items
    my $start = @{$self->{history}} > $self->{max_history}
        ? @{$self->{history}} - $self->{max_history}
        : 0;

    for (my $i = $start; $i < @{$self->{history}}; $i++) {
        print $fh $self->{history}[$i], "\n";
    }
    close($fh);
}

sub redraw_line {
    my ($self, $buffer, $pos) = @_;

    # Move to start of line, clear it, print prompt and buffer
    print "\r\033[K";  # CR + clear to end of line
    print $self->{prompt}, $buffer;

    # Move cursor to correct position
    my $cursor_pos = length($self->{prompt}) + $pos;
    print "\r\033[", $cursor_pos + 1, "G";  # Move to column (1-based)
}

sub readline {
    my ($self) = @_;

    my $buffer = '';
    my $pos = 0;  # Cursor position in buffer

    # Reset history position
    $self->{history_pos} = @{$self->{history}};
    my $temp_line = '';  # Temporary storage when browsing history

    # Set terminal to raw mode
    $self->set_raw_mode();

    # Print initial prompt
    print $self->{prompt};
    STDOUT->flush();

    # Set up select for multiplexing stdin and socket
    my $select = IO::Select->new();
    $select->add(\*STDIN);
    $select->add($self->{socket}) if $self->{socket};

    my $result = undef;
    my $detached = 0;

    eval {
        while (1) {
            # Check for async notifications
            if ($self->{check_notifications}) {
                my $had_notification = $self->{check_notifications}->($buffer, $pos);
                if ($had_notification) {
                    $self->redraw_line($buffer, $pos);
                }
            }

            # Wait for input with timeout (for periodic notification checks)
            my @ready = $select->can_read(0.1);

            # Check if stdin has data
            my $stdin_ready = 0;
            for my $fh (@ready) {
                if (fileno($fh) == fileno(STDIN)) {
                    $stdin_ready = 1;
                    last;
                }
            }

            next unless $stdin_ready;

            my $char = $self->read_char();
            next unless defined $char;

            my $ord = ord($char);

            # Handle control characters
            if ($ord == 3) {  # Ctrl-C
                $detached = 1;
                last;
            }
            elsif ($ord == 4) {  # Ctrl-D (EOF)
                if (length($buffer) == 0) {
                    $detached = 1;
                    last;
                }
            }
            elsif ($ord == 26) {  # Ctrl-Z
                # Restore terminal and suspend
                $self->restore_mode();
                kill('TSTP', $$);
                # Will resume here when fg'd
                $self->set_raw_mode();
                $self->redraw_line($buffer, $pos);
            }
            elsif ($ord == 13 || $ord == 10) {  # Enter
                print "\n";
                $result = $buffer;
                last;
            }
            elsif ($ord == 127 || $ord == 8) {  # Backspace/Delete
                if ($pos > 0) {
                    substr($buffer, $pos - 1, 1) = '';
                    $pos--;
                    $self->redraw_line($buffer, $pos);
                }
            }
            elsif ($ord == 27) {  # Escape sequence (arrow keys, etc.)
                # Read next character with small delay for escape sequences
                select(undef, undef, undef, 0.01);  # 10ms delay
                my $next1 = $self->read_char();
                next unless defined $next1;

                if (ord($next1) == 91) {  # '['
                    select(undef, undef, undef, 0.01);
                    my $next2 = $self->read_char();
                    next unless defined $next2;

                    my $code = ord($next2);

                    if ($code == 65) {  # Up arrow
                        if ($self->{history_pos} > 0) {
                            # Save current line if at bottom of history
                            if ($self->{history_pos} == @{$self->{history}}) {
                                $temp_line = $buffer;
                            }
                            $self->{history_pos}--;
                            $buffer = $self->{history}[$self->{history_pos}];
                            $pos = length($buffer);
                            $self->redraw_line($buffer, $pos);
                        }
                    }
                    elsif ($code == 66) {  # Down arrow
                        if ($self->{history_pos} < @{$self->{history}}) {
                            $self->{history_pos}++;
                            if ($self->{history_pos} == @{$self->{history}}) {
                                $buffer = $temp_line;
                            } else {
                                $buffer = $self->{history}[$self->{history_pos}];
                            }
                            $pos = length($buffer);
                            $self->redraw_line($buffer, $pos);
                        }
                    }
                    elsif ($code == 67) {  # Right arrow
                        if ($pos < length($buffer)) {
                            $pos++;
                            my $cursor_pos = length($self->{prompt}) + $pos;
                            print "\033[", $cursor_pos + 1, "G";
                        }
                    }
                    elsif ($code == 68) {  # Left arrow
                        if ($pos > 0) {
                            $pos--;
                            my $cursor_pos = length($self->{prompt}) + $pos;
                            print "\033[", $cursor_pos + 1, "G";
                        }
                    }
                    elsif ($code == 72) {  # Home
                        $pos = 0;
                        my $cursor_pos = length($self->{prompt});
                        print "\033[", $cursor_pos + 1, "G";
                    }
                    elsif ($code == 70) {  # End
                        $pos = length($buffer);
                        my $cursor_pos = length($self->{prompt}) + $pos;
                        print "\033[", $cursor_pos + 1, "G";
                    }
                }
            }
            elsif ($ord >= 32 && $ord < 127) {  # Printable character
                substr($buffer, $pos, 0) = $char;
                $pos++;
                $self->redraw_line($buffer, $pos);
            }

            STDOUT->flush();
        }
    };

    # Always restore terminal mode
    $self->restore_mode();

    # Re-throw any errors after cleanup
    die $@ if $@;

    # Handle detach
    if ($detached) {
        return undef;
    }

    # Add to history if non-empty
    if (defined $result && $result =~ /\S/) {
        # Don't add duplicates of the last command
        if (!@{$self->{history}} || $self->{history}[-1] ne $result) {
            push @{$self->{history}}, $result;
        }
    }

    return $result;
}

sub DESTROY {
    my ($self) = @_;
    $self->restore_mode();
    $self->save_history();
}

1;
