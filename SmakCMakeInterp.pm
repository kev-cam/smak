package SmakCMakeInterp;
# SmakCMakeInterp — CMake language interpreter
#
# Parses CMakeLists.txt directly and evaluates the cmake commands to
# build up target/source information, without running cmake.
#
# Grammar (simplified from CMake reference):
#
#   file        := command_invocation* EOF
#   command     := IDENT LPAREN args RPAREN
#   args        := arg*  (with optional (nested) parens for some commands)
#   arg         := bracket_string | quoted_string | unquoted_string
#   bracket_string := [[ ... ]]  (with = for nesting: [=[...]=])
#   quoted_string  := " ... "   (with backslash escapes)
#   unquoted       := any non-whitespace, non-paren, non-quote text
#                     (may contain ${var}, $<...>, $ENV{...})
#
# Variables: ${VAR}, $ENV{VAR}, $CACHE{VAR}
# Generator expressions: $<...> — treated as opaque text during parse
# Comments: # to end of line, or #[[ ... ]]

use strict;
use warnings;
use File::Basename;
use File::Spec;

# ─── Lexer ──────────────────────────────────────────────────────────
#
# Token types:
#   ident    - command name
#   lparen   - (
#   rparen   - )
#   arg      - an argument (bracket / quoted / unquoted), kept as a
#              hashref { type => '...', text => '...' }
#   newline  - statement separator (for error reporting only)
#
# We emit one token per lex() call (pull lexer).

sub new_lexer {
    my ($text, $source) = @_;
    return {
        text => $text,
        pos  => 0,
        line => 1,
        source => $source // '<string>',
    };
}

sub _at_eof { $_[0]{pos} >= length($_[0]{text}) }
sub _peek_char { substr($_[0]{text}, $_[0]{pos}, 1) }
sub _advance {
    my $lex = shift;
    my $c = substr($lex->{text}, $lex->{pos}, 1);
    $lex->{pos}++;
    $lex->{line}++ if $c eq "\n";
    return $c;
}

# Skip whitespace and comments.
sub _skip_trivia {
    my $lex = shift;
    while (!_at_eof($lex)) {
        my $c = _peek_char($lex);
        if ($c eq ' ' || $c eq "\t" || $c eq "\n" || $c eq "\r") {
            _advance($lex);
        } elsif ($c eq '#') {
            # Line comment, or bracket comment #[[...]]
            _advance($lex);
            if (_peek_char($lex) eq '[') {
                # Bracket comment — count = signs for nesting level
                my $eqs = '';
                _advance($lex);  # consume [
                while (_peek_char($lex) eq '=') {
                    $eqs .= '=';
                    _advance($lex);
                }
                if (_peek_char($lex) eq '[') {
                    _advance($lex);
                    my $close = "]${eqs}]";
                    while (!_at_eof($lex) && substr($lex->{text}, $lex->{pos}, length($close)) ne $close) {
                        _advance($lex);
                    }
                    # Skip the close
                    $lex->{pos} += length($close);
                }
                # else: not a bracket comment, fall through to eat as line comment
            }
            # Skip to end of line
            while (!_at_eof($lex) && _peek_char($lex) ne "\n") {
                _advance($lex);
            }
        } else {
            last;
        }
    }
}

sub _read_bracket_string {
    my $lex = shift;
    # We're at the first [ of [[ or [=[
    _advance($lex);  # consume [
    my $eqs = '';
    while (_peek_char($lex) eq '=') {
        $eqs .= '=';
        _advance($lex);
    }
    die "Expected [ at line $lex->{line} in $lex->{source}\n" unless _peek_char($lex) eq '[';
    _advance($lex);  # consume second [

    my $close = "]${eqs}]";
    my $content = '';
    while (!_at_eof($lex) && substr($lex->{text}, $lex->{pos}, length($close)) ne $close) {
        $content .= _advance($lex);
    }
    die "Unterminated bracket string at line $lex->{line} in $lex->{source}\n" if _at_eof($lex);
    $lex->{pos} += length($close);
    return { type => 'bracket', text => $content };
}

sub _read_quoted_string {
    my $lex = shift;
    _advance($lex);  # consume "
    my $text = '';
    while (!_at_eof($lex) && _peek_char($lex) ne '"') {
        my $c = _advance($lex);
        if ($c eq '\\') {
            my $nc = _advance($lex);
            # Standard C-like escapes
            $text .= { 'n' => "\n", 't' => "\t", 'r' => "\r",
                       '"' => '"', '\\' => '\\', ' ' => ' ',
                       ';' => ';', '0' => "\0" }->{$nc} // $nc;
        } else {
            $text .= $c;
        }
    }
    die "Unterminated quoted string at line $lex->{line} in $lex->{source}\n" if _at_eof($lex);
    _advance($lex);  # consume "
    return { type => 'quoted', text => $text };
}

sub _read_unquoted {
    my $lex = shift;
    my $text = '';
    my $paren_depth = 0;
    while (!_at_eof($lex)) {
        my $c = _peek_char($lex);
        # End of argument — but a " inside an unquoted arg starts a quoted
        # substring that becomes part of the argument (CMake semantics).
        last if $c =~ /\s/;
        last if $c eq '(' && $paren_depth == 0;
        last if $c eq ')' && $paren_depth == 0;
        last if $c eq '#' && $text eq '';
        # Quoted substring embedded in unquoted arg — treat as literal,
        # preserve the quotes, handle escapes inside.
        if ($c eq '"') {
            _advance($lex);
            $text .= '"';
            while (!_at_eof($lex) && _peek_char($lex) ne '"') {
                my $cc = _advance($lex);
                if ($cc eq '\\') {
                    my $nc = _advance($lex);
                    $text .= "\\$nc";
                } else {
                    $text .= $cc;
                }
            }
            _advance($lex) if !_at_eof($lex);  # closing "
            $text .= '"';
            next;
        }
        # Track nested parens inside unquoted args
        $paren_depth++ if $c eq '(';
        $paren_depth-- if $c eq ')';
        # Handle backslash escape
        if ($c eq '\\') {
            _advance($lex);
            my $nc = _advance($lex);
            $text .= $nc;
        } else {
            $text .= _advance($lex);
        }
    }
    return { type => 'unquoted', text => $text };
}

# Lex next token (returns undef at EOF).
sub next_token {
    my $lex = shift;
    _skip_trivia($lex);
    return undef if _at_eof($lex);

    my $c = _peek_char($lex);
    if ($c eq '(') {
        _advance($lex);
        return { type => 'lparen', line => $lex->{line} };
    }
    if ($c eq ')') {
        _advance($lex);
        return { type => 'rparen', line => $lex->{line} };
    }
    if ($c eq '[') {
        # May be bracket string [[ or [=[ — peek ahead
        my $save = $lex->{pos};
        _advance($lex);
        my $eqs = '';
        while (_peek_char($lex) eq '=') {
            $eqs .= '=';
            _advance($lex);
        }
        if (_peek_char($lex) eq '[') {
            # Restore and read as bracket string
            $lex->{pos} = $save;
            return _read_bracket_string($lex);
        }
        # Not a bracket string — treat [ as start of unquoted arg
        $lex->{pos} = $save;
        return _read_unquoted($lex);
    }
    if ($c eq '"') {
        return _read_quoted_string($lex);
    }

    # Identifier (command name) or unquoted argument.
    # In CMake, command names come at statement start; a "bareword" token at
    # statement start is the command, subsequent barewords are args.
    # We emit both as 'unquoted' and let the parser distinguish by position.
    return _read_unquoted($lex);
}

# ─── Parser ─────────────────────────────────────────────────────────
#
# Output: a list of command hashrefs:
#   { name => 'set', args => [arg, arg, ...], line => N }
# where each arg is a hashref from the lexer.

sub parse_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot open $path: $!\n";
    local $/;
    my $text = <$fh>;
    close($fh);
    return parse_string($text, $path);
}

sub parse_string {
    my ($text, $source) = @_;
    my $lex = new_lexer($text, $source);
    my @commands;

    while (my $tok = next_token($lex)) {
        # Expect identifier (command name) — which we lexed as 'unquoted'
        die "Expected command name at line $lex->{line} in $lex->{source}, got $tok->{type}\n"
            unless $tok->{type} eq 'unquoted';
        my $name = lc($tok->{text});
        my $line = $lex->{line};

        # Expect (
        my $lp = next_token($lex);
        die "Expected '(' after '$name' at line $lex->{line} in $lex->{source}\n"
            unless defined $lp && $lp->{type} eq 'lparen';

        # Collect args until matching )
        my @args;
        my $depth = 1;
        while (1) {
            my $t = next_token($lex);
            die "Unterminated command '$name' (started line $line) in $lex->{source}\n"
                unless defined $t;
            if ($t->{type} eq 'lparen') {
                $depth++;
                push @args, { type => 'unquoted', text => '(' };
            } elsif ($t->{type} eq 'rparen') {
                $depth--;
                last if $depth == 0;
                push @args, { type => 'unquoted', text => ')' };
            } else {
                push @args, $t;
            }
        }

        push @commands, { name => $name, args => \@args, line => $line,
                           source => $lex->{source} };
    }

    return \@commands;
}

# ─── Variable expansion ─────────────────────────────────────────────
#
# Expand ${VAR}, $ENV{VAR}, $CACHE{VAR} in a string.
# Generator expressions $<...> are left as-is (evaluated later).

sub expand {
    my ($str, $scope) = @_;
    # Repeat until no more expansions (${${X}} nested refs)
    my $prev = '';
    while ($str ne $prev) {
        $prev = $str;
        $str =~ s/\$\{([^\{\}\$]+?)\}/_lookup($1, $scope) \/\/ ''/ge;
        $str =~ s/\$ENV\{([^\}]+)\}/$ENV{$1} \/\/ ''/ge;
        $str =~ s/\$CACHE\{([^\}]+)\}/_lookup_cache($1, $scope) \/\/ ''/ge;
    }
    return $str;
}

sub _lookup {
    my ($name, $scope) = @_;
    # Walk scope chain
    while ($scope) {
        return $scope->{vars}{$name} if exists $scope->{vars}{$name};
        $scope = $scope->{parent};
    }
    return undef;
}

sub _lookup_cache {
    my ($name, $scope) = @_;
    # Find root scope
    while ($scope->{parent}) { $scope = $scope->{parent}; }
    return $scope->{cache}{$name};
}

# Expand an argument (lexer token) to one or more strings.
# Per CMake rules:
#   - quoted: expanded, produces exactly one string
#   - unquoted: expanded, then split on ';' to produce 0+ strings (list expansion)
#   - bracket: NOT expanded, produces exactly one string
sub expand_arg {
    my ($arg, $scope) = @_;
    if ($arg->{type} eq 'bracket') {
        return ($arg->{text});
    }
    my $expanded = expand($arg->{text}, $scope);
    if ($arg->{type} eq 'quoted') {
        return ($expanded);
    }
    # Unquoted — if it contains quoted substrings (embedded "), treat whole
    # thing as one token (don't split on ;).  Otherwise list-expand.
    if ($arg->{text} =~ /"/) {
        return ($expanded);
    }
    return grep { $_ ne '' } split(/;/, $expanded);
}

sub expand_args {
    my ($args, $scope) = @_;
    return map { expand_arg($_, $scope) } @$args;
}

# ─── Evaluator (stub) ───────────────────────────────────────────────

sub new_scope {
    my ($parent) = @_;
    return {
        parent => $parent,
        vars   => {},
        cache  => $parent ? undef : {},  # cache only at root
    };
}

# Built-in commands table. Each takes ($state, $args_expanded, $cmd_ast).
our %builtins;

sub eval_commands {
    my ($commands, $state, $scope) = @_;
    my $i = 0;
    while ($i < @$commands) {
        my $cmd = $commands->[$i];
        my $name = $cmd->{name};

        if ($name eq 'if') {
            $i = _eval_if($commands, $i, $state, $scope);
        } elsif ($name eq 'foreach') {
            $i = _eval_foreach($commands, $i, $state, $scope);
        } elsif ($name eq 'while') {
            $i = _eval_while($commands, $i, $state, $scope);
        } elsif ($name eq 'function' || $name eq 'macro') {
            $i = _eval_function_def($commands, $i, $state, $scope);
        } else {
            eval_command($cmd, $state, $scope);
            $i++;
        }
        # Flow control: return/break/continue propagate up through eval_commands
        last if _flow_control_set($scope);
    }
}

sub _flow_control_set {
    my $scope = shift;
    my $s = $scope;
    while ($s) {
        return 1 if $s->{_return} || $s->{_break} || $s->{_continue};
        $s = $s->{parent};
    }
    return 0;
}

# Find the matching end-keyword for a block starter, honoring nesting.
# Returns the index of the end-keyword command.
sub _find_block_end {
    my ($commands, $start, $opener, $closer) = @_;
    my $depth = 1;
    for (my $j = $start + 1; $j < @$commands; $j++) {
        my $n = $commands->[$j]{name};
        $depth++ if $n eq $opener;
        $depth-- if $n eq $closer;
        return $j if $depth == 0;
    }
    die "Unterminated $opener block (started at line $commands->[$start]{line})\n";
}

# Scan a block for top-level elseif/else branches (honoring nesting).
# Returns a list of { name => 'if'|'elseif'|'else', args => [...], start => idx }
# where start is the index of the branch's opener.
sub _if_branches {
    my ($commands, $start, $end) = @_;
    my @branches = ({ name => 'if', args => $commands->[$start]{args}, start => $start });
    my $depth = 0;
    for (my $j = $start + 1; $j < $end; $j++) {
        my $n = $commands->[$j]{name};
        if ($n eq 'if') { $depth++ }
        elsif ($n eq 'endif') { $depth-- }
        elsif ($depth == 0 && ($n eq 'elseif' || $n eq 'else')) {
            push @branches, { name => $n, args => $commands->[$j]{args}, start => $j };
        }
    }
    return @branches;
}

sub _eval_if {
    my ($commands, $i, $state, $scope) = @_;
    my $end = _find_block_end($commands, $i, 'if', 'endif');
    my @branches = _if_branches($commands, $i, $end);

    # Compute body ranges for each branch: [start+1, next_branch_start-1]
    for my $b (0 .. $#branches) {
        my $body_start = $branches[$b]{start} + 1;
        my $body_end   = ($b < $#branches) ? $branches[$b+1]{start} - 1 : $end - 1;
        my $truthy;
        if ($branches[$b]{name} eq 'else') {
            $truthy = 1;
        } else {
            my @args = expand_args($branches[$b]{args}, $scope);
            $truthy = _if_test(\@args, $scope);
        }
        if ($truthy) {
            my @body = @{$commands}[$body_start .. $body_end];
            eval_commands(\@body, $state, $scope);
            last;
        }
    }
    return $end + 1;
}

# Evaluate if() condition per CMake semantics.
# Handles: TRUE/FALSE/ON/OFF/YES/NO/1/0/non-empty-string-that-is-a-var
# Operators: NOT, AND, OR, STREQUAL, EQUAL, LESS, GREATER, MATCHES,
#            DEFINED, EXISTS, IS_DIRECTORY, VERSION_LESS, etc.
# Simplified — good enough for common cases.
sub _if_test {
    my ($args, $scope) = @_;
    # Shunting-yard-ish: handle NOT, AND, OR by recursion
    return _if_expr($args, $scope);
}

sub _if_expr {
    my ($args, $scope) = @_;
    # Handle parens (rare; we pass tokens through)
    # Handle OR (lowest precedence)
    for (my $i = 0; $i < @$args; $i++) {
        if (uc($args->[$i]) eq 'OR') {
            my @l = @$args[0..$i-1];
            my @r = @$args[$i+1..$#$args];
            return _if_expr(\@l, $scope) || _if_expr(\@r, $scope);
        }
    }
    for (my $i = 0; $i < @$args; $i++) {
        if (uc($args->[$i]) eq 'AND') {
            my @l = @$args[0..$i-1];
            my @r = @$args[$i+1..$#$args];
            return _if_expr(\@l, $scope) && _if_expr(\@r, $scope);
        }
    }
    # NOT
    if (@$args >= 1 && uc($args->[0]) eq 'NOT') {
        my @r = @$args[1..$#$args];
        return !_if_expr(\@r, $scope);
    }
    # Binary predicates
    if (@$args == 3) {
        my ($l, $op, $r) = @$args;
        my $uop = uc($op);
        return _deref($l, $scope) eq _deref($r, $scope) if $uop eq 'STREQUAL';
        return _deref($l, $scope) ne _deref($r, $scope) if $uop eq 'STRNOTEQUAL';
        return _deref($l, $scope) == _deref($r, $scope) if $uop eq 'EQUAL';
        return _deref($l, $scope) <  _deref($r, $scope) if $uop eq 'LESS';
        return _deref($l, $scope) <= _deref($r, $scope) if $uop eq 'LESS_EQUAL';
        return _deref($l, $scope) >  _deref($r, $scope) if $uop eq 'GREATER';
        return _deref($l, $scope) >= _deref($r, $scope) if $uop eq 'GREATER_EQUAL';
        if ($uop eq 'MATCHES') {
            my $s = _deref($l, $scope);
            return $s =~ /$r/;
        }
        # Version comparison — compare parts
        if ($uop =~ /^VERSION_/) {
            return _version_cmp(_deref($l, $scope), $uop, _deref($r, $scope));
        }
    }
    # Unary predicates
    if (@$args == 2) {
        my ($op, $arg) = @$args;
        my $uop = uc($op);
        return exists _find_var($arg, $scope)->{$arg} if $uop eq 'DEFINED';
        return -e $arg ? 1 : 0 if $uop eq 'EXISTS';
        return -d $arg ? 1 : 0 if $uop eq 'IS_DIRECTORY';
        return -f $arg && !(-l $arg) ? 1 : 0 if $uop eq 'IS_SYMLINK';
        return -e $arg ? 1 : 0 if $uop eq 'IS_ABSOLUTE';
        return (defined $scope->{vars}{$arg} && $scope->{vars}{$arg}) ? 1 : 0 if $uop eq 'TARGET' || $uop eq 'COMMAND';
    }
    # Single value — truthy test
    if (@$args == 1) {
        my $v = $args->[0];
        return _truthy($v, $scope);
    }
    # Empty
    return 0;
}

# Is a bare value "truthy" in cmake if() context?
sub _truthy {
    my ($v, $scope) = @_;
    # Constants
    return 1 if $v =~ /^(1|ON|YES|TRUE|Y)$/i;
    return 0 if $v =~ /^(0|OFF|NO|FALSE|N|IGNORE|NOTFOUND|)$/i;
    return 0 if $v =~ /-NOTFOUND$/;
    # Otherwise, treat as variable name — look it up recursively
    my $lookup = _lookup($v, $scope);
    if (defined $lookup && $lookup ne '') {
        return _truthy($lookup, $scope);
    }
    return 0;
}

sub _find_var {
    my ($name, $scope) = @_;
    while ($scope) {
        return $scope->{vars} if exists $scope->{vars}{$name};
        $scope = $scope->{parent};
    }
    return {};
}

# Dereference: if arg is a defined variable name, return its value;
# otherwise return arg as-is.
sub _deref {
    my ($v, $scope) = @_;
    my $lookup = _lookup($v, $scope);
    return defined $lookup ? $lookup : $v;
}

sub _version_cmp {
    my ($a, $op, $b) = @_;
    my @ap = split /\./, $a;
    my @bp = split /\./, $b;
    my $len = @ap > @bp ? @ap : @bp;
    my $cmp = 0;
    for (my $i = 0; $i < $len; $i++) {
        # Extract leading integer from each part (cmake allows "1.2.3rc1" etc.)
        my $av = ($ap[$i] // '') =~ /^(\d+)/ ? $1 : 0;
        my $bv = ($bp[$i] // '') =~ /^(\d+)/ ? $1 : 0;
        if ($av != $bv) { $cmp = $av <=> $bv; last; }
    }
    return { 'VERSION_LESS' => $cmp < 0,
             'VERSION_LESS_EQUAL' => $cmp <= 0,
             'VERSION_GREATER' => $cmp > 0,
             'VERSION_GREATER_EQUAL' => $cmp >= 0,
             'VERSION_EQUAL' => $cmp == 0,
           }->{$op} ? 1 : 0;
}

sub _eval_foreach {
    my ($commands, $i, $state, $scope) = @_;
    my $end = _find_block_end($commands, $i, 'foreach', 'endforeach');
    my $cmd = $commands->[$i];
    my @args = expand_args($cmd->{args}, $scope);
    my $var = shift @args;

    # Determine iteration list
    my @items;
    if (@args >= 2 && $args[0] eq 'RANGE') {
        shift @args;
        if (@args == 1) { @items = (0 .. $args[0]); }
        elsif (@args == 2) { @items = ($args[0] .. $args[1]); }
        elsif (@args == 3) {
            my ($start, $stop, $step) = @args;
            for (my $v = $start; $v <= $stop; $v += $step) { push @items, $v; }
        }
    } elsif (@args >= 1 && $args[0] eq 'IN') {
        shift @args;
        # IN LISTS <var> or IN ITEMS <items>
        if (@args >= 1 && $args[0] eq 'LISTS') {
            shift @args;
            for my $listvar (@args) {
                my $val = _lookup($listvar, $scope) // '';
                push @items, split /;/, $val;
            }
        } elsif (@args >= 1 && $args[0] eq 'ITEMS') {
            shift @args;
            @items = @args;
        } else {
            @items = @args;
        }
    } else {
        @items = @args;
    }

    my @body = @{$commands}[$i+1 .. $end-1];
    for my $item (@items) {
        $scope->{vars}{$var} = $item;
        eval_commands(\@body, $state, $scope);
        if ($scope->{_break}) { delete $scope->{_break}; last; }
        if ($scope->{_continue}) { delete $scope->{_continue}; next; }
        last if $scope->{_return};
    }
    return $end + 1;
}

sub _eval_while {
    my ($commands, $i, $state, $scope) = @_;
    my $end = _find_block_end($commands, $i, 'while', 'endwhile');
    my $cmd = $commands->[$i];
    my @body = @{$commands}[$i+1 .. $end-1];
    my $max = 100000;
    while ($max-- > 0) {
        my @args = expand_args($cmd->{args}, $scope);
        last unless _if_test(\@args, $scope);
        eval_commands(\@body, $state, $scope);
        if ($scope->{_break}) { delete $scope->{_break}; last; }
        if ($scope->{_continue}) { delete $scope->{_continue}; next; }
        last if $scope->{_return};
    }
    return $end + 1;
}

sub _eval_function_def {
    my ($commands, $i, $state, $scope) = @_;
    my $opener = $commands->[$i]{name};   # 'function' or 'macro'
    my $closer = "end$opener";
    my $end = _find_block_end($commands, $i, $opener, $closer);
    my $cmd = $commands->[$i];
    my @args = expand_args($cmd->{args}, $scope);
    my $name = lc(shift @args);
    my @params = @args;
    my @body = @{$commands}[$i+1 .. $end-1];
    # Store function definition — functions get a new scope, macros do not
    my $is_macro = ($opener eq 'macro');
    $state->{functions}{$name} = {
        params => \@params,
        body   => \@body,
        is_macro => $is_macro,
    };
    return $end + 1;
}

sub eval_command {
    my ($cmd, $state, $scope) = @_;
    my @expanded = expand_args($cmd->{args}, $scope);
    my $handler = $builtins{$cmd->{name}};
    if ($handler) {
        $handler->($state, \@expanded, $cmd, $scope);
        return;
    }
    # User-defined function/macro
    if ($state->{functions} && $state->{functions}{$cmd->{name}}) {
        _call_function($cmd->{name}, \@expanded, $state, $scope);
        return;
    }
    # Unknown command — record it but don't fail (yet)
    push @{$state->{unknown_commands}}, $cmd->{name};
    warn "SmakCMake: unknown command '$cmd->{name}' at $cmd->{source}:$cmd->{line}\n"
        if $ENV{SMAK_CMAKE_DEBUG};
}

sub _call_function {
    my ($name, $args, $state, $scope) = @_;
    my $fn = $state->{functions}{$name};
    my $call_scope = $fn->{is_macro} ? $scope : new_scope($scope);
    # Set ARGC, ARGN, ARGV, ARGV0..
    $call_scope->{vars}{ARGC} = scalar @$args;
    $call_scope->{vars}{ARGV} = join(';', @$args);
    for my $k (0 .. $#$args) {
        $call_scope->{vars}["ARGV$k"] = $args->[$k];
    }
    # Bind named parameters
    for my $k (0 .. $#{$fn->{params}}) {
        $call_scope->{vars}{$fn->{params}[$k]} = $args->[$k] // '';
    }
    # ARGN = extra args beyond named params
    my $nparams = scalar @{$fn->{params}};
    $call_scope->{vars}{ARGN} = join(';', @$args[$nparams..$#$args]) if @$args > $nparams;

    eval_commands($fn->{body}, $state, $call_scope);
    # Clear return flag — it only unwinds to the function boundary
    delete $call_scope->{_return};
}

# ─── Built-in commands (minimal) ────────────────────────────────────

$builtins{'set'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    return unless @$args;
    my $name = shift @$args;
    # Detect CACHE / PARENT_SCOPE keywords
    my $cache = 0;
    my $parent = 0;
    my @values;
    for my $a (@$args) {
        if ($a eq 'CACHE') { $cache = 1; last; }
        if ($a eq 'PARENT_SCOPE') { $parent = 1; last; }
        push @values, $a;
    }
    my $value = join(';', @values);
    if ($cache) {
        # Walk to root
        my $s = $scope;
        while ($s->{parent}) { $s = $s->{parent}; }
        $s->{cache}{$name} = $value unless exists $s->{cache}{$name};
        $s->{vars}{$name} = $value;
    } elsif ($parent) {
        $scope->{parent}{vars}{$name} = $value if $scope->{parent};
    } else {
        $scope->{vars}{$name} = $value;
    }
};

$builtins{'unset'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    return unless @$args;
    my $name = $args->[0];
    delete $scope->{vars}{$name};
};

$builtins{'message'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    return unless @$args;
    my $mode = $args->[0];
    if ($mode =~ /^(STATUS|NOTICE|VERBOSE|DEBUG|TRACE|CHECK_START|CHECK_PASS|CHECK_FAIL)$/) {
        shift @$args;
    }
    print STDERR "-- ", join(' ', @$args), "\n" if $ENV{SMAK_CMAKE_DEBUG};
};

$builtins{'cmake_minimum_required'} = sub { };  # no-op
$builtins{'cmake_policy'} = sub { };

$builtins{'project'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    $state->{project_name} = $name;
    $scope->{vars}{PROJECT_NAME} = $name;
    $scope->{vars}{"${name}_SOURCE_DIR"} = $state->{source_dir};
    $scope->{vars}{"${name}_BINARY_DIR"} = $state->{build_dir};
    $scope->{vars}{CMAKE_PROJECT_NAME} //= $name;
};

$builtins{'add_executable'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my @sources = grep { !/^(IMPORTED|ALIAS|GLOBAL|EXCLUDE_FROM_ALL|WIN32|MACOSX_BUNDLE)$/ } @$args;
    $state->{targets}{$name} = _new_target($state, 'executable', \@sources);
};

$builtins{'add_library'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $libtype = 'static';
    if (@$args && $args->[0] =~ /^(STATIC|SHARED|MODULE|INTERFACE|OBJECT)$/) {
        $libtype = lc(shift @$args);
    }
    my @sources = grep { !/^(IMPORTED|ALIAS|GLOBAL|EXCLUDE_FROM_ALL)$/ } @$args;
    my $t = _new_target($state, 'library', \@sources);
    $t->{libtype} = $libtype;
    $state->{targets}{$name} = $t;
};

# Build a new target, inheriting directory-level include_directories
# and definitions that were in effect at the point of definition.
sub _new_target {
    my ($state, $type, $sources) = @_;
    my $t = {
        type       => $type,
        sources    => [@$sources],
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
        include_directories => [@{$state->{include_directories} // []}],
        defines_list        => [@{$state->{definitions} // []}],
        options_list        => [@{$state->{compile_options} // []}],
    };
    $t->{compile_definitions} = join(' ', @{$t->{defines_list}});
    $t->{compile_options}     = join(' ', @{$t->{options_list}});
    return $t;
}

$builtins{'target_include_directories'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    # Skip PUBLIC/PRIVATE/INTERFACE/SYSTEM/BEFORE keywords
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE|SYSTEM|BEFORE|AFTER)$/;
        push @{$t->{include_directories}}, $a;
    }
};

$builtins{'target_compile_definitions'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE)$/;
        # Accept both "FOO" and "FOO=bar"; add -D prefix
        my $d = $a =~ /^-D/ ? $a : "-D$a";
        push @{$t->{defines_list}}, $d;
    }
    $t->{compile_definitions} = join(' ', @{$t->{defines_list} // []});
};

$builtins{'target_compile_options'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE|BEFORE)$/;
        push @{$t->{options_list}}, $a;
    }
    $t->{compile_options} = join(' ', @{$t->{options_list} // []});
};

$builtins{'target_link_libraries'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE|LINK_PUBLIC|LINK_PRIVATE|LINK_INTERFACE_LIBRARIES)$/;
        push @{$t->{link_libraries}}, $a;
    }
};

$builtins{'target_sources'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE)$/;
        push @{$t->{sources}}, $a;
    }
};

$builtins{'set_target_properties'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # set_target_properties(name1 name2 PROPERTIES prop1 val1 prop2 val2)
    my @names;
    while (@$args && $args->[0] ne 'PROPERTIES') {
        push @names, shift @$args;
    }
    shift @$args if @$args && $args->[0] eq 'PROPERTIES';
    while (@$args >= 2) {
        my ($prop, $val) = (shift @$args, shift @$args);
        for my $n (@names) {
            next unless $state->{targets}{$n};
            $state->{targets}{$n}{properties}{$prop} = $val;
        }
    }
};

$builtins{'include_directories'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    push @{$state->{include_directories}}, grep { !/^(SYSTEM|BEFORE|AFTER)$/ } @$args;
};

$builtins{'add_definitions'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    push @{$state->{definitions}}, @$args;
};

$builtins{'add_compile_options'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    push @{$state->{compile_options}}, @$args;
};

$builtins{'include'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $file = $args->[0] or return;
    return if $file eq 'OPTIONAL' || $file eq 'NO_POLICY_SCOPE';
    # Module name or file path
    my $path = $file;
    unless (-f $path) {
        # Try .cmake suffix
        $path = "$file.cmake" if -f "$file.cmake";
    }
    unless (-f $path) {
        # Search CMAKE_MODULE_PATH
        my $module_path = _lookup('CMAKE_MODULE_PATH', $scope) // '';
        for my $dir (split /;/, $module_path) {
            if (-f "$dir/$file.cmake") { $path = "$dir/$file.cmake"; last; }
            if (-f "$dir/$file")       { $path = "$dir/$file";       last; }
        }
    }
    unless (-f $path) {
        warn "SmakCMake: include(): cannot find '$file' at $cmd->{source}:$cmd->{line}\n"
            if $ENV{SMAK_CMAKE_DEBUG};
        return;
    }
    my $sub = parse_file($path);
    eval_commands($sub, $state, $scope);
};

$builtins{'list'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $op = shift @$args;
    my $name = shift @$args;
    my @list = split /;/, (_lookup($name, $scope) // '');

    if ($op eq 'APPEND') {
        push @list, @$args;
    } elsif ($op eq 'PREPEND') {
        unshift @list, @$args;
    } elsif ($op eq 'REMOVE_ITEM') {
        my %rm = map { $_ => 1 } @$args;
        @list = grep { !$rm{$_} } @list;
    } elsif ($op eq 'REMOVE_DUPLICATES') {
        my %seen;
        @list = grep { !$seen{$_}++ } @list;
    } elsif ($op eq 'LENGTH') {
        my $out = shift @$args;
        $scope->{vars}{$out} = scalar @list;
        return;
    } elsif ($op eq 'GET') {
        my $out = pop @$args;
        my @idx = @$args;
        my @vals = map { $list[$_] // '' } @idx;
        $scope->{vars}{$out} = join(';', @vals);
        return;
    } elsif ($op eq 'JOIN') {
        my $sep = shift @$args;
        my $out = shift @$args;
        $scope->{vars}{$out} = join($sep, @list);
        return;
    } elsif ($op eq 'SORT') {
        @list = sort @list;
    } elsif ($op eq 'REVERSE') {
        @list = reverse @list;
    } elsif ($op eq 'INSERT') {
        my $idx = shift @$args;
        splice(@list, $idx, 0, @$args);
    } elsif ($op eq 'FIND') {
        my $item = shift @$args;
        my $out = shift @$args;
        my $found = -1;
        for my $i (0..$#list) { if ($list[$i] eq $item) { $found = $i; last; } }
        $scope->{vars}{$out} = $found;
        return;
    } elsif ($op eq 'FILTER') {
        # list(FILTER <var> <INCLUDE|EXCLUDE> REGEX <regex>)
        my $mode = shift @$args;
        shift @$args if @$args && $args->[0] eq 'REGEX';
        my $rx = shift @$args;
        if ($mode eq 'INCLUDE') {
            @list = grep { /$rx/ } @list;
        } else {
            @list = grep { !/$rx/ } @list;
        }
    }
    $scope->{vars}{$name} = join(';', @list);
};

$builtins{'string'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $op = shift @$args;
    if ($op eq 'REPLACE') {
        my ($from, $to, $out, @inputs) = @$args;
        my $s = join('', @inputs);
        $s =~ s/\Q$from\E/$to/g;
        $scope->{vars}{$out} = $s;
    } elsif ($op eq 'REGEX') {
        my $mode = shift @$args;
        if ($mode eq 'REPLACE') {
            my ($rx, $repl, $out, @inputs) = @$args;
            my $s = join('', @inputs);
            # Convert cmake \1 backrefs — Perl uses $1; simplest: replace only
            $s =~ s/$rx/_cmake_regex_expand($repl)/ge;
            $scope->{vars}{$out} = $s;
        } elsif ($mode eq 'MATCH' || $mode eq 'MATCHALL') {
            my ($rx, $out, @inputs) = @$args;
            my $s = join('', @inputs);
            if ($mode eq 'MATCH') {
                $scope->{vars}{$out} = ($s =~ /($rx)/) ? $1 : '';
            } else {
                my @m;
                while ($s =~ /($rx)/g) { push @m, $1; }
                $scope->{vars}{$out} = join(';', @m);
            }
        }
    } elsif ($op eq 'APPEND') {
        my $name = shift @$args;
        $scope->{vars}{$name} = ($scope->{vars}{$name} // '') . join('', @$args);
    } elsif ($op eq 'PREPEND') {
        my $name = shift @$args;
        $scope->{vars}{$name} = join('', @$args) . ($scope->{vars}{$name} // '');
    } elsif ($op eq 'CONCAT') {
        my $out = shift @$args;
        $scope->{vars}{$out} = join('', @$args);
    } elsif ($op eq 'TOUPPER') {
        my ($in, $out) = @$args;
        $scope->{vars}{$out} = uc $in;
    } elsif ($op eq 'TOLOWER') {
        my ($in, $out) = @$args;
        $scope->{vars}{$out} = lc $in;
    } elsif ($op eq 'LENGTH') {
        my ($in, $out) = @$args;
        $scope->{vars}{$out} = length $in;
    } elsif ($op eq 'SUBSTRING') {
        my ($in, $start, $len, $out) = @$args;
        $scope->{vars}{$out} = $len < 0 ? substr($in, $start) : substr($in, $start, $len);
    } elsif ($op eq 'STRIP') {
        my ($in, $out) = @$args;
        $in =~ s/^\s+|\s+$//g;
        $scope->{vars}{$out} = $in;
    } elsif ($op eq 'COMPARE') {
        my $mode = shift @$args;
        my ($l, $r, $out) = @$args;
        my $res = 0;
        if    ($mode eq 'EQUAL')    { $res = ($l eq $r) ? 1 : 0 }
        elsif ($mode eq 'NOTEQUAL') { $res = ($l ne $r) ? 1 : 0 }
        elsif ($mode eq 'LESS')     { $res = ($l lt $r) ? 1 : 0 }
        elsif ($mode eq 'GREATER')  { $res = ($l gt $r) ? 1 : 0 }
        $scope->{vars}{$out} = $res;
    }
};

sub _cmake_regex_expand {
    my $repl = shift;
    # Stub: don't expand backrefs; assume $1..$9 used by caller
    return $repl;
}

$builtins{'math'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # math(EXPR <var> <expression> [OUTPUT_FORMAT ...])
    shift @$args if $args->[0] eq 'EXPR';
    my $out = shift @$args;
    my $expr = shift @$args;
    # Very limited: evaluate as Perl arithmetic
    my $val = eval { no strict; no warnings; eval $expr };
    $scope->{vars}{$out} = defined $val ? $val : 0;
};

$builtins{'option'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($name, $desc, $default) = @$args;
    $default //= 'OFF';
    return if exists $scope->{vars}{$name};
    $scope->{vars}{$name} = $default;
    # Root scope cache
    my $s = $scope; while ($s->{parent}) { $s = $s->{parent}; }
    $s->{cache}{$name} //= $default;
};

$builtins{'file'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $op = shift @$args;
    if ($op eq 'GLOB' || $op eq 'GLOB_RECURSE') {
        my $out = shift @$args;
        # Skip RELATIVE <dir>, LIST_DIRECTORIES, CONFIGURE_DEPENDS
        my $relative;
        while (@$args && $args->[0] =~ /^(RELATIVE|LIST_DIRECTORIES|CONFIGURE_DEPENDS|FOLLOW_SYMLINKS)$/) {
            my $kw = shift @$args;
            $relative = shift @$args if $kw eq 'RELATIVE';
            shift @$args if $kw eq 'LIST_DIRECTORIES';  # TRUE/FALSE
        }
        my @matches;
        for my $pattern (@$args) {
            # If pattern is relative, make absolute against current source dir
            my $abs_pattern = $pattern =~ m{^/} ? $pattern
                : File::Spec->catfile($state->{current_source_dir}, $pattern);
            if ($op eq 'GLOB_RECURSE') {
                # Simple recursive glob: convert pattern → regex
                my $base = $abs_pattern;
                $base =~ s{/[^/]*$}{};
                my $fpat = $abs_pattern;
                $fpat =~ s{^.*/}{};
                $fpat = quotemeta($fpat);
                $fpat =~ s/\\\*/[^\/]*/g;
                $fpat =~ s/\\\?/./g;
                use File::Find;
                File::Find::find({ wanted => sub {
                    if (-f $_ && /^$fpat$/) {
                        my $p = $File::Find::name;
                        $p = File::Spec->abs2rel($p, $relative) if $relative;
                        push @matches, $p;
                    }
                }, no_chdir => 1 }, $base) if -d $base;
            } else {
                for my $m (glob($abs_pattern)) {
                    $m = File::Spec->abs2rel($m, $relative) if $relative;
                    push @matches, $m;
                }
            }
        }
        $scope->{vars}{$out} = join(';', @matches);
    } elsif ($op eq 'READ') {
        my ($path, $out) = @$args;
        if (open(my $fh, '<', $path)) {
            local $/;
            $scope->{vars}{$out} = <$fh>;
            close $fh;
        }
    } elsif ($op eq 'WRITE' || $op eq 'APPEND') {
        my $path = shift @$args;
        if (open(my $fh, $op eq 'APPEND' ? '>>' : '>', $path)) {
            print $fh join('', @$args);
            close $fh;
        }
    } elsif ($op eq 'MAKE_DIRECTORY') {
        use File::Path qw(make_path);
        for my $d (@$args) { make_path($d); }
    }
};

$builtins{'configure_file'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($in, $out) = @$args[0, 1];
    # Resolve paths
    $in = File::Spec->catfile($state->{current_source_dir}, $in)
        unless $in =~ m{^/};
    $out = File::Spec->catfile($state->{current_binary_dir}, $out)
        unless $out =~ m{^/};
    open(my $ifh, '<', $in) or do {
        warn "configure_file: cannot read $in\n" if $ENV{SMAK_CMAKE_DEBUG};
        return;
    };
    local $/;
    my $text = <$ifh>;
    close $ifh;

    # Substitute @VAR@
    $text =~ s/\@([A-Za-z_][A-Za-z0-9_]*)\@/_lookup($1, $scope) \/\/ ''/ge;
    # Substitute ${VAR}
    $text =~ s/\$\{([^\{\}\$]+?)\}/_lookup($1, $scope) \/\/ ''/ge;
    # #cmakedefine VAR → #define VAR val, or /* #undef VAR */
    $text =~ s{^(\s*)#cmakedefine\s+(\w+)(.*)$}{
        my ($ws, $var, $rest) = ($1, $2, $3);
        my $val = _lookup($var, $scope);
        if (defined $val && $val ne '' && $val !~ /^(0|OFF|NO|FALSE|IGNORE|NOTFOUND)$/i) {
            "${ws}#define $var$rest";
        } else {
            "${ws}/* #undef $var */";
        }
    }gem;
    # #cmakedefine01 VAR → #define VAR 0 or 1
    $text =~ s{^(\s*)#cmakedefine01\s+(\w+)}{
        my ($ws, $var) = ($1, $2);
        my $val = _lookup($var, $scope);
        my $n = (defined $val && $val ne '' && $val !~ /^(0|OFF|NO|FALSE)$/i) ? 1 : 0;
        "${ws}#define $var $n";
    }gem;

    # Create output directory
    use File::Path qw(make_path);
    use File::Basename qw(dirname);
    make_path(dirname($out));
    open(my $ofh, '>', $out) or return;
    print $ofh $text;
    close $ofh;
};

$builtins{'return'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # Signal return by setting a flag in the scope chain — eval_commands
    # checks this after each command and exits the loop if set.
    $scope->{_return} = 1;
};

$builtins{'break'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    $scope->{_break} = 1;
};

$builtins{'continue'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    $scope->{_continue} = 1;
};

$builtins{'get_target_property'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($out, $target, $prop) = @$args;
    my $t = $state->{targets}{$target};
    my $val;
    if ($t) {
        if ($prop eq 'INCLUDE_DIRECTORIES') {
            $val = join(';', @{$t->{include_directories} // []});
        } elsif ($prop eq 'COMPILE_DEFINITIONS') {
            $val = join(';', @{$t->{defines_list} // []});
        } elsif ($prop eq 'SOURCES') {
            $val = join(';', @{$t->{sources} // []});
        } elsif ($prop eq 'LINK_LIBRARIES') {
            $val = join(';', @{$t->{link_libraries} // []});
        } else {
            $val = $t->{properties}{$prop};
        }
    }
    $scope->{vars}{$out} = defined $val ? $val : "$out-NOTFOUND";
};

$builtins{'get_property'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # Minimal: get_property(<var> <GLOBAL|DIRECTORY|TARGET|SOURCE|CACHE> PROPERTY <prop>)
    my $out = shift @$args;
    shift @$args;  # scope keyword
    # skip to PROPERTY
    while (@$args && $args->[0] ne 'PROPERTY') { shift @$args; }
    shift @$args if @$args && $args->[0] eq 'PROPERTY';
    my $prop = shift @$args;
    $scope->{vars}{$out} = '';
};

$builtins{'set_property'} = sub { };  # stub

$builtins{'find_program'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    my $prog = shift @$args;
    # Shift past NAMES, PATHS, HINTS, DOC, REQUIRED, etc.
    my @candidates = ($prog);
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'NAMES') {
            while (@$args && $args->[0] !~ /^(PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES)$/) {
                push @candidates, shift @$args;
            }
        } else {
            last if $kw =~ /^(REQUIRED|NO_DEFAULT_PATH)$/;
            # eat arg
        }
    }
    for my $cand (@candidates) {
        for my $dir (split /:/, $ENV{PATH} // '/usr/bin:/usr/local/bin') {
            if (-x "$dir/$cand") {
                $scope->{vars}{$out} = "$dir/$cand";
                return;
            }
        }
    }
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

$builtins{'find_library'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

$builtins{'find_path'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

$builtins{'install'} = sub { };          # stub — we don't install
$builtins{'export'} = sub { };           # stub
$builtins{'enable_testing'} = sub { };   # stub
$builtins{'add_test'} = sub { };         # stub (we can add later)
$builtins{'cmake_language'} = sub { };   # stub — complex meta-programming
$builtins{'include_guard'} = sub { };

# mark_as_advanced, get_cmake_property, etc.
$builtins{'mark_as_advanced'} = sub { };
$builtins{'get_cmake_property'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    $scope->{vars}{$out} = '';
};

$builtins{'find_package'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # Stub — record the request, set _FOUND=FALSE by default.
    # Real implementation needs to search Find<Pkg>.cmake / <Pkg>Config.cmake
    my $name = shift @$args;
    push @{$state->{find_package_requests}}, $name;
    $scope->{vars}{"${name}_FOUND"} = 'FALSE';
};

$builtins{'add_subdirectory'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $subdir = $args->[0];
    my $source_subdir = File::Spec->catdir($state->{current_source_dir}, $subdir);
    my $binary_subdir = $args->[1] // File::Spec->catdir($state->{current_binary_dir}, $subdir);
    my $sub_cmake = "$source_subdir/CMakeLists.txt";
    return unless -f $sub_cmake;
    my $sub_commands = parse_file($sub_cmake);
    # New scope, new current dirs
    my $sub_scope = new_scope($scope);
    my $saved_src = $state->{current_source_dir};
    my $saved_bin = $state->{current_binary_dir};
    $state->{current_source_dir} = $source_subdir;
    $state->{current_binary_dir} = $binary_subdir;
    eval_commands($sub_commands, $state, $sub_scope);
    delete $sub_scope->{_return};  # return() at subdir scope unwinds here
    $state->{current_source_dir} = $saved_src;
    $state->{current_binary_dir} = $saved_bin;
};

# ─── Makefile generator ─────────────────────────────────────────────
#
# Given interpreted state, emit Makefiles that are functionally
# equivalent to what cmake generates.  Minimal viable set:
#
#   <build_dir>/Makefile              — top-level with 'all' and 'clean'
#   <build_dir>/CMakeFiles/Makefile2  — inter-target deps
#   <build_dir>/CMakeFiles/<target>.dir/build.make    — per-target build rules
#   <build_dir>/CMakeFiles/<target>.dir/flags.make    — compiler flags
#   <build_dir>/CMakeFiles/<target>.dir/link.txt      — link command
#   <build_dir>/CMakeFiles/<target>.dir/DependInfo.cmake — source→obj mapping
#
# (Matches the layout SmakCMake.pm already reads, so the same
#  build engine works on CMakeLists.txt-derived rules.)

sub generate_makefiles {
    my ($state, $opts) = @_;
    $opts //= {};
    my $build_dir = $state->{build_dir};
    my $source_dir = $state->{source_dir};

    use File::Path qw(make_path);
    make_path("$build_dir/CMakeFiles");

    # Generate per-target files
    for my $name (sort keys %{$state->{targets}}) {
        my $t = $state->{targets}{$name};
        my $tdir = "$build_dir/CMakeFiles/$name.dir";
        make_path($tdir);

        _write_flags_make($t, $tdir, $state);
        _write_depend_info($t, $tdir, $state, $name);
        _write_link_txt($t, $tdir, $state, $name);
    }
}

sub _target_sources_with_paths {
    my ($t, $state) = @_;
    my @out;
    for my $src (@{$t->{sources}}) {
        my $src_path = $src =~ m{^/} ? $src
            : File::Spec->catfile($t->{source_dir}, $src);
        my $obj_rel = $src;
        $obj_rel =~ s{^.*/}{};  # basename
        my $obj = "CMakeFiles/" . _target_name_from_dir($t) . ".dir/$obj_rel.o";
        push @out, { src => $src_path, obj => $obj };
    }
    return @out;
}

sub _target_name_from_dir {
    my ($t) = @_;
    # Fallback; caller really should pass name explicitly
    return 'unknown';
}

sub _write_flags_make {
    my ($t, $tdir, $state) = @_;
    my $lang = _primary_lang($t);
    open(my $fh, '>', "$tdir/flags.make") or die "write $tdir/flags.make: $!";
    print $fh "# CMAKE generated file: DO NOT EDIT!\n";
    print $fh "# Generated by SmakCMakeInterp\n\n";
    print $fh "# compile $lang with ", _compiler_for_lang($lang), "\n";
    print $fh "${lang}_DEFINES = ", ($t->{compile_definitions} // ''), "\n";
    print $fh "${lang}_INCLUDES = ", _include_flags($t), "\n";
    print $fh "${lang}_FLAGS = ", ($t->{compile_options} // ''), "\n";
    close($fh);
}

sub _write_depend_info {
    my ($t, $tdir, $state, $name) = @_;
    my $lang = _primary_lang($t);
    open(my $fh, '>', "$tdir/DependInfo.cmake") or die "write $tdir/DependInfo.cmake: $!";
    print $fh "# CMAKE generated file: DO NOT EDIT!\n";
    print $fh "# Generated by SmakCMakeInterp\n\n";
    print $fh "set(CMAKE_DEPENDS_LANGUAGES\n  \"$lang\"\n  )\n";
    print $fh "set(CMAKE_DEPENDS_DEPENDENCY_FILES\n";
    for my $src (@{$t->{sources}}) {
        my $src_path = $src =~ m{^/} ? $src
            : File::Spec->catfile($t->{source_dir}, $src);
        my $obj_base = $src;
        $obj_base =~ s{^.*/}{};
        my $obj = "CMakeFiles/$name.dir/$obj_base.o";
        my $depfile = "$obj.d";
        my $compiler = $lang eq 'C' ? 'gcc' : ($lang eq 'CXX' ? 'gcc' : 'gfortran');
        print $fh "  \"$src_path\" \"$obj\" \"$compiler\" \"$depfile\"\n";
    }
    print $fh "  )\n";
    close($fh);
}

sub _write_link_txt {
    my ($t, $tdir, $state, $name) = @_;
    my $lang = _primary_lang($t);
    my @objs = map {
        my $s = $_;
        $s =~ s{^.*/}{};
        "CMakeFiles/$name.dir/$s.o"
    } @{$t->{sources}};

    my $link_cmd;
    if ($t->{type} eq 'library' && $t->{libtype} eq 'static') {
        my $out = "lib$name.a";
        $link_cmd = "/usr/bin/ar qc $out " . join(' ', @objs) . "\n" .
                    "/usr/bin/ranlib $out";
    } elsif ($t->{type} eq 'executable') {
        my $compiler = _compiler_for_lang($lang);
        $link_cmd = "$compiler " . join(' ', @objs) . " -o $name";
    } else {
        $link_cmd = "# unsupported target type: $t->{type}";
    }

    open(my $fh, '>', "$tdir/link.txt") or die "write $tdir/link.txt: $!";
    print $fh $link_cmd, "\n";
    close($fh);
}

sub _primary_lang {
    my ($t) = @_;
    for my $src (@{$t->{sources}}) {
        return 'Fortran' if $src =~ /\.f(\d+)?$/i;
        return 'C'       if $src =~ /\.c$/;
        return 'CXX'     if $src =~ /\.(cc|cpp|cxx|C)$/;
    }
    return 'CXX';
}

sub _compiler_for_lang {
    my $lang = shift;
    return {
        C => '/usr/bin/cc',
        CXX => '/usr/bin/c++',
        Fortran => '/usr/bin/gfortran',
    }->{$lang} // '/usr/bin/cc';
}

sub _include_flags {
    my ($t) = @_;
    my @inc = @{$t->{include_directories} // []};
    return join(' ', map { "-I$_" } @inc);
}

# ─── Entry point ────────────────────────────────────────────────────

# Parse + evaluate a project rooted at $source_dir, targeting $build_dir.
# Returns the state hash (targets, variables, etc.).
sub interpret_project {
    my ($source_dir, $build_dir) = @_;
    $source_dir = File::Spec->rel2abs($source_dir);
    $build_dir  = File::Spec->rel2abs($build_dir);

    my $state = {
        source_dir => $source_dir,
        build_dir  => $build_dir,
        current_source_dir => $source_dir,
        current_binary_dir => $build_dir,
        targets    => {},
        unknown_commands => [],
    };

    my $root_scope = new_scope(undef);
    # Predefined CMake variables
    $root_scope->{vars}{CMAKE_SOURCE_DIR} = $source_dir;
    $root_scope->{vars}{CMAKE_BINARY_DIR} = $build_dir;
    $root_scope->{vars}{CMAKE_CURRENT_SOURCE_DIR} = $source_dir;
    $root_scope->{vars}{CMAKE_CURRENT_BINARY_DIR} = $build_dir;
    # Version string of our pretend cmake
    $root_scope->{vars}{CMAKE_VERSION} = '3.31.4';
    $root_scope->{vars}{CMAKE_MAJOR_VERSION} = 3;
    $root_scope->{vars}{CMAKE_MINOR_VERSION} = 31;
    $root_scope->{vars}{CMAKE_PATCH_VERSION} = 4;
    # Platform
    $root_scope->{vars}{CMAKE_HOST_SYSTEM_NAME} = 'Linux';
    $root_scope->{vars}{CMAKE_SYSTEM_NAME} = 'Linux';
    $root_scope->{vars}{UNIX} = 1;
    $root_scope->{vars}{LINUX} = 1;
    $root_scope->{vars}{CMAKE_HOST_UNIX} = 1;
    # Compilers (match typical CMake output)
    $root_scope->{vars}{CMAKE_C_COMPILER} = '/usr/bin/cc';
    $root_scope->{vars}{CMAKE_CXX_COMPILER} = '/usr/bin/c++';
    $root_scope->{vars}{CMAKE_C_COMPILER_ID} = 'GNU';
    $root_scope->{vars}{CMAKE_CXX_COMPILER_ID} = 'GNU';
    $root_scope->{vars}{CMAKE_SIZEOF_VOID_P} = 8;

    my $commands = parse_file("$source_dir/CMakeLists.txt");
    eval_commands($commands, $state, $root_scope);

    return $state;
}

1;
