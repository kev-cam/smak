#!/usr/bin/perl
# Raw terminal input handler for smak CLI
# Provides line editing with async notification support

package SmakCli;

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

our $self;
our $buffer;
our $pos;

sub redraw_line {

    # Move to start of line, clear it, print prompt and buffer
    print "\r\033[K";  # CR + clear to end of line
    print $self->{prompt}, $buffer;

    # Move cursor to correct position
    my $cursor_pos = length($self->{prompt}) + $pos;
    print "\r\033[", $cursor_pos + 1, "G";  # Move to column (1-based)
    STDOUT->flush();
}

our $cancel_requested = 0;
our $reprompt_requested = 0;
our $cli_owner = -1;
our $enabled = 1;
our $current_buffer = '';
our $current_pos = 0;
our $current_prompt = '';

our @EXPORT_OK = qw(
    cli_owner
    enabled 
    new
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

sub winch_handler {
    if ($enabled && $cli_owner == $$) {
	# Redraw on SIGWINCH
	$self->{redraw_line};
    }
};

sub readline {
    ($self) = @_;

    $buffer = '';
    $pos = 0;  # Cursor position in buffer
    
    # Reset history position
    $self->{history_pos} = @{$self->{history}};
    my $temp_line = '';  # Temporary storage when browsing history

    # Set terminal to raw mode
    $self->set_raw_mode();

    # Print initial prompt
    print $self->{prompt};
    STDOUT->flush();

    # Set up SIGWINCH handler for reprompt
    local $SIG{WINCH} = sub { winch_handler };
    $cli_owner = $$;

    # Set up select for multiplexing stdin and socket
    my $select = IO::Select->new();
    $select->add(\*STDIN);
    $select->add($self->{socket}) if $self->{socket};

    my $result = undef;
    my $detached = 0;
    my $had_notification = 0;

    # eval {
        while (1) {
            # Update globals for reprompt()
            $current_buffer = $buffer;
            $current_pos = $pos;
            $current_prompt = $self->{prompt};

            # Check for async notifications
            if ($self->{check_notifications}) {
                my $had_notification = $self->{check_notifications}->($buffer, $pos);
                if ($had_notification) {
                    redraw_line();
		    if (-2 == $had_notification ) {
			$result = undef;
			last;
		    }
                }
            }

            # Check for reprompt request
            if ($reprompt_requested) {
                $reprompt_requested = 0;
                redraw_line();
            }

            # Wait for input with timeout (for periodic notification checks)
            my @ready = $select->can_read(0.2);

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
            # Note: Ctrl-C (ord 3) is handled by SIGINT signal handler, not here
            # Just skip the character if we receive it
            if ($ord == 3) {  # Ctrl-C
		$cancel_requested = 1;
                next;  # Handled in interim check
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
                redraw_line();
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
                    redraw_line();
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
                            redraw_line();
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
                            redraw_line();
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
            elsif ($ord == 9) {  # Tab - completion
                # Find the current word (from last space or start to cursor)
                my $before_cursor = substr($buffer, 0, $pos);
                my $word_start = 0;
                if ($before_cursor =~ /.*\s(\S*)$/) {
                    $word_start = length($before_cursor) - length($1);
                }
                my $word = substr($buffer, $word_start, $pos - $word_start);

                # Get completions using glob
                my @matches = glob("$word*");

                if (@matches == 0) {
                    # No matches - beep or do nothing
                } elsif (@matches == 1) {
                    # Single match - replace word
                    my $completion = $matches[0];
                    # Add trailing slash for directories
                    $completion .= '/' if -d $completion;
                    substr($buffer, $word_start, $pos - $word_start) = $completion;
                    $pos = $word_start + length($completion);
                    redraw_line();
                } else {
                    # Multiple matches - find common prefix
                    my $common = $matches[0];
                    for my $match (@matches[1..$#matches]) {
                        # Find common prefix between $common and $match
                        my $len = length($common) < length($match) ? length($common) : length($match);
                        for (my $i = 0; $i < $len; $i++) {
                            if (substr($common, $i, 1) ne substr($match, $i, 1)) {
                                $common = substr($common, 0, $i);
                                last;
                            }
                        }
                    }

                    if (length($common) > length($word)) {
                        # Replace with common prefix
                        substr($buffer, $word_start, $pos - $word_start) = $common;
                        $pos = $word_start + length($common);
                        redraw_line();
                    } else {
                        # Show all matches
                        print "\n";
                        my $cols = 80;  # Assume 80 column terminal
                        my $max_len = 0;
                        for my $m (@matches) {
                            my $len = length($m);
                            $max_len = $len if $len > $max_len;
                        }
                        my $col_width = $max_len + 2;
                        my $num_cols = int($cols / $col_width);
                        $num_cols = 1 if $num_cols < 1;

                        for (my $i = 0; $i < @matches; $i++) {
                            printf "%-${col_width}s", $matches[$i];
                            print "\n" if (($i + 1) % $num_cols == 0);
                        }
                        print "\n" if (@matches % $num_cols != 0);
                        redraw_line();
                    }
                }
            }
            elsif ($ord >= 32 && $ord < 127) {  # Printable character
                substr($buffer, $pos, 0) = $char;
                $pos++;
                redraw_line();
            }

            STDOUT->flush();
        }
    # };

    # Always restore terminal mode
    $self->restore_mode();

    $cli_owner = -1;
    
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
