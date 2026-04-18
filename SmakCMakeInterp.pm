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
    # Evaluate generator expressions $<...> — we treat build-time always
    $expanded = _eval_genex($expanded, $scope);
    if ($arg->{type} eq 'quoted') {
        return ($expanded);
    }
    if ($arg->{text} =~ /"/) {
        return ($expanded);
    }
    return grep { $_ ne '' } split(/;/, $expanded);
}

# Evaluate generator expressions in a string.  Handle the common forms:
#   $<BUILD_INTERFACE:content>   → content (we're at build time)
#   $<INSTALL_INTERFACE:content> → '' (not installing)
#   $<CONFIG>                    → 'Release'
#   $<CONFIG:Release>            → 1
#   $<CXX_COMPILER_ID:GNU>       → 1 (we pretend to be GNU)
#   $<IF:cond,then,else>         → then or else
#   $<$<CXX_COMPILER_ID:GNU>:x>  → x  (conditional)
#   $<TARGET_FILE:name>          → build-time path
# Recursively process innermost first.
sub _eval_genex {
    my ($s, $scope) = @_;
    # Repeatedly resolve innermost $<...>
    while (1) {
        # Find an innermost $<...> with no nested $<
        if ($s =~ /\$<([^<>]*?)>/) {
            my $expr = $1;
            my $full = "\$<$expr>";
            my $val = _resolve_genex($expr, $scope);
            $val = '' unless defined $val;
            my $q = quotemeta($full);
            $s =~ s/$q/$val/;
        } else {
            last;
        }
    }
    return $s;
}

sub _resolve_genex {
    my ($expr, $scope) = @_;

    # $<CONFIG>  (no colon)
    return 'Release' if $expr eq 'CONFIG';

    # $<keyword:args>
    if ($expr =~ /^([A-Z_][A-Z_0-9]*):(.*)$/s) {
        my ($kw, $rest) = ($1, $2);
        if ($kw eq 'BUILD_INTERFACE')   { return $rest; }
        if ($kw eq 'INSTALL_INTERFACE') { return ''; }
        if ($kw eq 'BUILD_LOCAL_INTERFACE') { return $rest; }
        if ($kw eq 'CONFIG') {
            return (uc($rest) eq 'RELEASE') ? 1 : 0;
        }
        if ($kw eq 'CXX_COMPILER_ID') {
            return ($rest eq 'GNU') ? 1 : 0;
        }
        if ($kw eq 'C_COMPILER_ID') {
            return ($rest eq 'GNU') ? 1 : 0;
        }
        if ($kw eq 'COMPILE_LANGUAGE') {
            # Can't know per-file here; assume CXX (most common)
            return ($rest eq 'CXX') ? 1 : 0;
        }
        if ($kw eq 'PLATFORM_ID') {
            return ($rest eq 'Linux') ? 1 : 0;
        }
        if ($kw eq 'TARGET_FILE') {
            return $rest;  # target name; placeholder
        }
        if ($kw eq 'TARGET_EXISTS') {
            return 0;  # conservative
        }
        if ($kw eq 'IF') {
            # $<IF:cond,then,else>
            my @parts = _split_genex_args($rest, 3);
            return $parts[0] ? $parts[1] : $parts[2];
        }
        if ($kw eq 'NOT') {
            return $rest ? 0 : 1;
        }
        if ($kw eq 'AND') {
            my @p = _split_genex_args($rest);
            for my $x (@p) { return 0 unless $x; }
            return 1;
        }
        if ($kw eq 'OR') {
            my @p = _split_genex_args($rest);
            for my $x (@p) { return 1 if $x; }
            return 0;
        }
        if ($kw eq 'STREQUAL' || $kw eq 'EQUAL') {
            my @p = _split_genex_args($rest, 2);
            return ($p[0] eq $p[1]) ? 1 : 0;
        }
    }
    # Boolean-as-condition:cond:result form becomes $<cond:result>
    # where cond is the numeric value (0 or 1)
    if ($expr =~ /^(\d+):(.*)$/s) {
        return $1 ? $2 : '';
    }

    # Unknown — drop
    return '';
}

sub _split_genex_args {
    my ($s, $maxparts) = @_;
    my @parts;
    my $depth = 0;
    my $cur = '';
    for my $c (split //, $s) {
        if ($c eq ',' && $depth == 0 && (!$maxparts || @parts < $maxparts - 1)) {
            push @parts, $cur; $cur = ''; next;
        }
        $depth++ if $c eq '<';
        $depth-- if $c eq '>';
        $cur .= $c;
    }
    push @parts, $cur;
    return @parts;
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
        if ($uop eq 'EXISTS' || $uop eq 'IS_DIRECTORY' || $uop eq 'IS_SYMLINK' || $uop eq 'IS_ABSOLUTE') {
            # CMake: these check the literal path.  If the arg looks like
            # a filename (has / or . or exists on disk), use it.  Otherwise
            # dereference it as a variable name first.
            my $path = $arg;
            if ($arg !~ m{^/} && $arg !~ m{/} && !-e $arg) {
                my $v = _lookup($arg, $scope);
                $path = $v if defined $v && $v ne '';
            }
            return -e $path ? 1 : 0 if $uop eq 'EXISTS';
            return -d $path ? 1 : 0 if $uop eq 'IS_DIRECTORY';
            return -l $path ? 1 : 0 if $uop eq 'IS_SYMLINK';
            return $path =~ m{^/} ? 1 : 0 if $uop eq 'IS_ABSOLUTE';
        }
        # TARGET <name> — does a target with this name exist?
        if ($uop eq 'TARGET') {
            my $st = _state_for($scope);
            return ($st && exists $st->{targets}{$arg}) ? 1 : 0;
        }
        if ($uop eq 'COMMAND') {
            my $st = _state_for($scope);
            if ($st) {
                return (exists $st->{functions}{lc($arg)} || exists $builtins{lc($arg)}) ? 1 : 0;
            }
            return 0;
        }
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

sub _state_for {
    my ($scope) = @_;
    while ($scope) {
        return $scope->{_state} if $scope->{_state};
        $scope = $scope->{parent};
    }
    return undef;
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
    $args = [] unless ref($args) eq 'ARRAY';
    my $params = (ref($fn->{params}) eq 'ARRAY') ? $fn->{params} : [];
    $call_scope->{vars}{ARGC} = scalar @$args;
    $call_scope->{vars}{ARGV} = join(';', map { ref($_) ? '' : ($_ // '') } @$args);
    for my $k (0 .. $#$args) {
        my $v = $args->[$k];
        $call_scope->{vars}{"ARGV$k"} = ref($v) ? '' : (defined $v ? "$v" : '');
    }
    for my $k (0 .. $#$params) {
        my $v = $args->[$k];
        $call_scope->{vars}{$params->[$k]} = ref($v) ? '' : ($v // '');
    }
    # ARGN = extra args beyond named params
    my $nparams = scalar @$params;
    if (@$args > $nparams) {
        my @extra = @$args[$nparams..$#$args];
        $call_scope->{vars}{ARGN} = join(';', map { ref($_) ? '' : ($_ // '') } @extra);
    }

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
    my $imported = 0;
    my $global = 0;
    # Peel off keywords
    while (@$args && $args->[0] =~ /^(STATIC|SHARED|MODULE|INTERFACE|OBJECT|IMPORTED|GLOBAL|ALIAS|EXCLUDE_FROM_ALL)$/) {
        my $kw = shift @$args;
        if ($kw =~ /^(STATIC|SHARED|MODULE|INTERFACE|OBJECT)$/) {
            $libtype = lc($kw);
        } elsif ($kw eq 'IMPORTED') {
            $imported = 1;
        } elsif ($kw eq 'GLOBAL') {
            $global = 1;
        }
    }
    my @sources = @$args;
    # ALIAS: add_library(alias ALIAS real) — just point to real
    # (handled above by the while loop eating ALIAS and leaving the target name)
    my $t = _new_target($state, 'library', \@sources);
    $t->{libtype} = $libtype;
    $t->{imported} = $imported;
    $t->{global} = $global;
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
    my $mode = 'PRIVATE';
    my $curdir = $state->{current_source_dir};
    for my $a (@$args) {
        if ($a =~ /^(PUBLIC|PRIVATE|INTERFACE)$/) { $mode = $1; next; }
        next if $a =~ /^(SYSTEM|BEFORE|AFTER)$/;
        # Resolve relative paths against the current source directory
        my $path = $a =~ m{^/} ? $a : File::Spec->catdir($curdir, $a);
        # Normalize: resolve ./ and trailing /
        $path =~ s{/\./}{/}g;
        $path =~ s{/$}{};
        if ($mode ne 'INTERFACE') {
            push @{$t->{include_directories}}, $path;
        }
        if ($mode ne 'PRIVATE') {
            push @{$t->{interface_include_directories}}, $path;
        }
    }
};

$builtins{'target_compile_definitions'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    my $mode = 'PRIVATE';
    for my $a (@$args) {
        if ($a =~ /^(PUBLIC|PRIVATE|INTERFACE)$/) { $mode = $1; next; }
        my $d = $a =~ /^-D/ ? $a : "-D$a";
        if ($mode ne 'INTERFACE') {
            push @{$t->{defines_list}}, $d;
        }
        if ($mode ne 'PRIVATE') {
            push @{$t->{interface_defines_list}}, $d;
        }
    }
    $t->{compile_definitions} = join(' ', @{$t->{defines_list} // []});
};

$builtins{'target_compile_options'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    my $mode = 'PRIVATE';
    for my $a (@$args) {
        if ($a =~ /^(PUBLIC|PRIVATE|INTERFACE|BEFORE)$/) {
            $mode = $1 if $a ne 'BEFORE';
            next;
        }
        if ($mode ne 'INTERFACE') {
            push @{$t->{options_list}}, $a;
        }
        if ($mode ne 'PRIVATE') {
            push @{$t->{interface_options_list}}, $a;
        }
    }
    $t->{compile_options} = join(' ', @{$t->{options_list} // []});
};

$builtins{'target_link_libraries'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    my $mode = 'PRIVATE';  # default when no keyword given
    for my $a (@$args) {
        if ($a =~ /^(PUBLIC|PRIVATE|INTERFACE|LINK_PUBLIC|LINK_PRIVATE)$/) {
            $mode = $1;
            $mode =~ s/^LINK_//;
            next;
        }
        next if $a eq 'LINK_INTERFACE_LIBRARIES';
        # PRIVATE: only in link_libraries
        # INTERFACE: only in interface_link_libraries
        # PUBLIC: both
        if ($mode ne 'INTERFACE') {
            push @{$t->{link_libraries}}, $a;
        }
        if ($mode ne 'PRIVATE') {
            push @{$t->{interface_link_libraries}}, $a;
        }
        # Consumers always pull their deps' INTERFACE properties
        _propagate_interface($state, $t, $a);
    }
};

# When target $t links against $lib, pull $lib's INTERFACE_* properties
# into $t.  These are only the publicly-exposed interfaces — PRIVATE
# properties of $lib do not propagate.
sub _propagate_interface {
    my ($state, $t, $lib, $visited) = @_;
    $visited //= {};
    return if $visited->{$lib}++;

    my $lt = $state->{targets}{$lib};
    return unless $lt;

    # INTERFACE_INCLUDE_DIRECTORIES (set via PUBLIC/INTERFACE target_include_directories)
    for my $inc (@{$lt->{interface_include_directories} // []}) {
        push @{$t->{include_directories}}, $inc
            unless grep { $_ eq $inc } @{$t->{include_directories}};
    }
    # INTERFACE_COMPILE_DEFINITIONS
    for my $d (@{$lt->{interface_defines_list} // []}) {
        push @{$t->{defines_list}}, $d
            unless grep { $_ eq $d } @{$t->{defines_list}};
    }
    # INTERFACE_COMPILE_OPTIONS
    for my $o (@{$lt->{interface_options_list} // []}) {
        push @{$t->{options_list}}, $o
            unless grep { $_ eq $o } @{$t->{options_list}};
    }
    $t->{compile_definitions} = join(' ', @{$t->{defines_list} // []});
    $t->{compile_options}     = join(' ', @{$t->{options_list} // []});

    # Transitive INTERFACE_LINK_LIBRARIES
    for my $sublib (@{$lt->{interface_link_libraries} // []}) {
        next if grep { $_ eq $sublib } @{$t->{link_libraries}};
        push @{$t->{link_libraries}}, $sublib;
        _propagate_interface($state, $t, $sublib, $visited);
    }
}

$builtins{'target_sources'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    my $curdir = $state->{current_source_dir};
    for my $a (@$args) {
        next if $a =~ /^(PUBLIC|PRIVATE|INTERFACE|FILE_SET|BASE_DIRS|TYPE|HEADERS|FILES)$/;
        # If the source is relative and we're in a subdir, qualify it
        my $src = $a =~ m{^/} ? $a : File::Spec->catfile($curdir, $a);
        push @{$t->{sources}}, $src;
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
            my $t = $state->{targets}{$n};
            next unless $t;
            $t->{properties}{$prop} = $val;
            # Well-known properties map to target fields
            if ($prop eq 'INTERFACE_INCLUDE_DIRECTORIES') {
                $t->{interface_include_directories} = [grep { $_ ne '' } split /;/, $val];
            } elsif ($prop eq 'INCLUDE_DIRECTORIES') {
                $t->{include_directories} = [grep { $_ ne '' } split /;/, $val];
            } elsif ($prop eq 'INTERFACE_LINK_LIBRARIES') {
                $t->{interface_link_libraries} = [grep { $_ ne '' } split /;/, $val];
            } elsif ($prop eq 'INTERFACE_COMPILE_DEFINITIONS') {
                $t->{interface_defines_list} = [map { /^-D/ ? $_ : "-D$_" } grep { $_ ne '' } split /;/, $val];
            } elsif ($prop eq 'IMPORTED_LOCATION' || $prop =~ /^IMPORTED_LOCATION_/) {
                $t->{imported_location} = $val;
            }
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

    my $path;
    # 1. Absolute path
    if ($file =~ m{^/} && -f $file) { $path = $file; }
    # 2. Relative to current source dir
    elsif (!defined $path) {
        my $candidate = File::Spec->catfile($state->{current_source_dir}, $file);
        $path = $candidate if -f $candidate;
        $path //= "$candidate.cmake" if -f "$candidate.cmake";
    }
    # 3. Search CMAKE_MODULE_PATH
    unless ($path) {
        my $module_path = _lookup('CMAKE_MODULE_PATH', $scope) // '';
        for my $dir (split /;/, $module_path) {
            for my $try ("$dir/$file", "$dir/$file.cmake") {
                if (-f $try) { $path = $try; last; }
            }
            last if $path;
        }
    }
    # 4. Built-in modules (we have cmake's install available)
    unless ($path) {
        for my $try ("/usr/local/src/smak/cmake-install/share/cmake-3.31/Modules/$file",
                     "/usr/local/src/smak/cmake-install/share/cmake-3.31/Modules/$file.cmake") {
            if (-f $try) { $path = $try; last; }
        }
    }

    unless ($path) {
        warn "SmakCMake: include(): cannot find '$file' at $cmd->{source}:$cmd->{line}\n"
            if $ENV{SMAK_CMAKE_DEBUG};
        return;
    }
    # Normalize the path (collapse a/../b → b) to prevent ever-growing
    # chains when CMake configs use "${CMAKE_CURRENT_LIST_DIR}/../X"
    $path = File::Spec->canonpath($path);
    while ($path =~ s{/[^/]+/\.\./}{/}) {}
    warn "SmakCMake: include: $path\n" if $ENV{SMAK_CMAKE_DEBUG};
    # Parse-cache: avoid re-parsing the same file
    $state->{parse_cache}{$path} //= parse_file($path);
    my $sub = $state->{parse_cache}{$path};

    my $saved_list_dir = $scope->{vars}{CMAKE_CURRENT_LIST_DIR};
    my $saved_list_file = $scope->{vars}{CMAKE_CURRENT_LIST_FILE};
    $scope->{vars}{CMAKE_CURRENT_LIST_DIR} = dirname($path);
    $scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $path;
    eval_commands($sub, $state, $scope);
    delete $scope->{_return};
    $scope->{vars}{CMAKE_CURRENT_LIST_DIR} = $saved_list_dir;
    $scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $saved_list_file;
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

# add_custom_command(OUTPUT <files> COMMAND <cmd> [ARGS <a>...] [DEPENDS <d>...] ...)
# add_custom_command(TARGET <tgt> PRE_BUILD|PRE_LINK|POST_BUILD COMMAND <cmd> ...)
$builtins{'add_custom_command'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my %custom;
    my $i = 0;
    while ($i < @$args) {
        my $kw = $args->[$i];
        if ($kw eq 'OUTPUT') {
            $i++;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|MAIN_DEPENDENCY|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|APPEND|USES_TERMINAL|JOB_POOL|TARGET|PRE_BUILD|PRE_LINK|POST_BUILD)$/) {
                push @{$custom{output}}, $args->[$i++];
            }
        } elsif ($kw eq 'TARGET') {
            $custom{target} = $args->[++$i];
            $i++;
        } elsif ($kw eq 'COMMAND') {
            $i++;
            my @parts;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|MAIN_DEPENDENCY|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|APPEND|USES_TERMINAL|JOB_POOL|TARGET|ARGS|PRE_BUILD|PRE_LINK|POST_BUILD)$/) {
                push @parts, $args->[$i++];
            }
            push @{$custom{commands}}, join(' ', @parts);
            # ARGS is deprecated but legal
            if ($i < @$args && $args->[$i] eq 'ARGS') {
                $i++;
                my @extra;
                while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|MAIN_DEPENDENCY|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|APPEND|USES_TERMINAL|JOB_POOL|TARGET|PRE_BUILD|PRE_LINK|POST_BUILD)$/) {
                    push @extra, $args->[$i++];
                }
                $custom{commands}[-1] .= ' ' . join(' ', @extra) if @extra;
            }
        } elsif ($kw eq 'DEPENDS' || $kw eq 'MAIN_DEPENDENCY') {
            $i++;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|MAIN_DEPENDENCY|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|APPEND|USES_TERMINAL|JOB_POOL|TARGET|PRE_BUILD|PRE_LINK|POST_BUILD)$/) {
                push @{$custom{depends}}, $args->[$i++];
            }
        } elsif ($kw eq 'WORKING_DIRECTORY') {
            $custom{working_dir} = $args->[++$i];
            $i++;
        } elsif ($kw eq 'COMMENT') {
            $custom{comment} = $args->[++$i];
            $i++;
        } elsif ($kw =~ /^(VERBATIM|APPEND|USES_TERMINAL)$/) {
            $i++;
        } else {
            $i++;  # skip unknown
        }
    }
    $custom{source_dir} = $state->{current_source_dir};
    $custom{binary_dir} = $state->{current_binary_dir};
    push @{$state->{custom_commands}}, \%custom;
};

# add_custom_target(name [ALL] [command] [DEPENDS ...] ...)
$builtins{'add_custom_target'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $all = 0;
    if (@$args && $args->[0] eq 'ALL') { $all = 1; shift @$args; }
    my %t = (
        type => 'custom',
        name => $name,
        all => $all,
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
        sources => [],
        commands => [],
        depends => [],
    );
    my $i = 0;
    while ($i < @$args) {
        my $kw = $args->[$i];
        if ($kw eq 'COMMAND') {
            $i++;
            my @parts;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|USES_TERMINAL|SOURCES|JOB_POOL)$/) {
                push @parts, $args->[$i++];
            }
            push @{$t{commands}}, join(' ', @parts);
        } elsif ($kw eq 'DEPENDS') {
            $i++;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|USES_TERMINAL|SOURCES|JOB_POOL)$/) {
                push @{$t{depends}}, $args->[$i++];
            }
        } elsif ($kw eq 'SOURCES') {
            $i++;
            while ($i < @$args && $args->[$i] !~ /^(COMMAND|DEPENDS|BYPRODUCTS|WORKING_DIRECTORY|COMMENT|VERBATIM|USES_TERMINAL|SOURCES|JOB_POOL)$/) {
                push @{$t{sources}}, $args->[$i++];
            }
        } elsif ($kw eq 'WORKING_DIRECTORY') {
            $t{working_dir} = $args->[++$i]; $i++;
        } elsif ($kw eq 'COMMENT') {
            $t{comment} = $args->[++$i]; $i++;
        } else {
            $i++;
        }
    }
    $state->{targets}{$name} = \%t;
};

# add_dependencies(<target> <dep> ...)
$builtins{'add_dependencies'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $t = $state->{targets}{$name} or return;
    for my $dep (@$args) {
        push @{$t->{dependencies}}, $dep
            unless grep { $_ eq $dep } @{$t->{dependencies} // []};
    }
};

# bison_target(NAME input output [COMPILE_FLAGS <f>] [DEFINES_FILE <h>])
$builtins{'bison_target'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $input = shift @$args;
    my $output = shift @$args;
    # Resolve paths
    $input = File::Spec->catfile($state->{current_source_dir}, $input)
        unless $input =~ m{^/};
    $output = File::Spec->catfile($state->{current_binary_dir}, $output)
        unless $output =~ m{^/};
    my $header = $output;
    $header =~ s/\.(c|cc|cxx|cpp)$/.h/;
    my $flags = '';
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'COMPILE_FLAGS') { $flags = shift @$args; }
        elsif ($kw eq 'DEFINES_FILE') { $header = shift @$args; }
        else { shift @$args; }
    }
    my $bison = '/usr/bin/bison';
    push @{$state->{custom_commands}}, {
        output => [$output, $header],
        commands => ["$bison $flags -d -o $output $input"],
        depends => [$input],
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
    };
    # Expose variables for dependents
    $scope->{vars}{"${name}_OUTPUTS"} = "$output;$header";
    $scope->{vars}{"${name}_OUTPUT_SOURCE"} = $output;
    $scope->{vars}{"${name}_OUTPUT_HEADER"} = $header;
};

# flex_target(NAME input output [COMPILE_FLAGS <f>])
$builtins{'flex_target'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $input = shift @$args;
    my $output = shift @$args;
    $input = File::Spec->catfile($state->{current_source_dir}, $input)
        unless $input =~ m{^/};
    $output = File::Spec->catfile($state->{current_binary_dir}, $output)
        unless $output =~ m{^/};
    my $flags = '';
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'COMPILE_FLAGS') { $flags = shift @$args; }
        else { shift @$args; }
    }
    my $flex = '/usr/bin/flex';
    push @{$state->{custom_commands}}, {
        output => [$output],
        commands => ["$flex $flags -o $output $input"],
        depends => [$input],
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
    };
    $scope->{vars}{"${name}_OUTPUTS"} = $output;
};

$builtins{'add_flex_bison_dependency'} = sub { };  # no-op; bison/flex handle it

$builtins{'get_filename_component'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($out, $input, $mode) = @$args;
    my $val;
    if ($mode eq 'DIRECTORY' || $mode eq 'PATH') {
        $val = $input;
        $val =~ s{/[^/]*$}{};
        $val = '/' if $val eq '' && $input =~ m{^/};
    } elsif ($mode eq 'NAME') {
        $val = $input;
        $val =~ s{^.*/}{};
    } elsif ($mode eq 'EXT') {
        $val = ($input =~ /(\.[^\/.]+)$/) ? $1 : '';
    } elsif ($mode eq 'NAME_WE') {
        $val = $input;
        $val =~ s{^.*/}{};
        $val =~ s{\..*$}{};
    } elsif ($mode eq 'NAME_WLE') {
        $val = $input;
        $val =~ s{^.*/}{};
        $val =~ s{\.[^.]+$}{};
    } elsif ($mode eq 'ABSOLUTE' || $mode eq 'REALPATH') {
        $val = File::Spec->rel2abs($input);
    } elsif ($mode eq 'PROGRAM') {
        $val = $input;
    } else {
        $val = $input;
    }
    $scope->{vars}{$out} = $val;
};

# Actually test if a header exists in our sysroot.  Real cmake compiles a
# test program; we just check the filesystem.  Good enough for common cases.
sub _check_include {
    my ($header, $var, $lang, $scope) = @_;
    # Common search paths
    my @paths = ('/usr/include', '/usr/local/include',
                 '/usr/include/x86_64-linux-gnu',
                 '/usr/local/src/smak/cmake-install/include');
    # Add include paths from CMAKE_REQUIRED_INCLUDES if set
    my $req_inc = _lookup('CMAKE_REQUIRED_INCLUDES', $scope);
    if ($req_inc) {
        push @paths, split /;/, $req_inc;
    }
    for my $p (@paths) {
        if (-f "$p/$header") {
            $scope->{vars}{$var} = 1;
            return;
        }
    }
    # Treat a bare .h that's in standard locations as found (unistd.h etc)
    my %standard = map { $_ => 1 } qw(
        unistd.h sys/resource.h sys/stat.h sys/utsname.h sys/time.h
        malloc.h pwd.h dlfcn.h stdlib.h stdio.h string.h time.h errno.h
        limits.h ctype.h math.h assert.h signal.h fcntl.h
    );
    if ($standard{$header} && -f "/usr/include/$header") {
        $scope->{vars}{$var} = 1;
        return;
    }
    $scope->{vars}{$var} = '';  # not found
}

$builtins{'check_include_file'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($header, $var) = @$args;
    _check_include($header, $var, 'C', $scope);
};

$builtins{'check_include_file_cxx'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($header, $var) = @$args;
    _check_include($header, $var, 'CXX', $scope);
};

$builtins{'check_include_files'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($headers, $var) = @$args;
    # All headers must be found
    for my $h (split /;/, $headers) {
        _check_include($h, $var, 'C', $scope);
        return unless $scope->{vars}{$var};
    }
};

# Symbol check — we only verify header exists, not the symbol.
# Most cmake projects use these for optional features; being permissive
# (symbol found if header exists) is safer than conservatively saying no.
$builtins{'check_symbol_exists'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($symbol, $files, $var) = @$args;
    my @headers = split /;/, ($files // '');
    my $found = 1;
    for my $h (@headers) {
        my $exists;
        _check_include($h, "_tmp_check_$var", 'C', $scope);
        $exists = $scope->{vars}{"_tmp_check_$var"};
        delete $scope->{vars}{"_tmp_check_$var"};
        unless ($exists) { $found = 0; last; }
    }
    $scope->{vars}{$var} = $found ? 1 : '';
};

$builtins{'check_cxx_symbol_exists'} = $builtins{'check_symbol_exists'};
$builtins{'check_function_exists'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($fn, $var) = @$args;
    # Permissive: assume yes for common POSIX functions
    $scope->{vars}{$var} = 1;
};
$builtins{'check_cxx_source_compiles'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($source, $var) = @$args;
    $scope->{vars}{$var} = 1;  # assume yes
};

$builtins{'cmake_parse_arguments'} = sub { };  # TODO
$builtins{'cmake_print_variables'} = sub { };
$builtins{'cmake_print_properties'} = sub { };
$builtins{'block'} = sub { };    # CMake 3.25+ scoping
$builtins{'endblock'} = sub { };

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
    my $name = shift @$args;
    push @{$state->{find_package_requests}}, $name;

    # Parse remaining args (version, REQUIRED, QUIET, CONFIG/MODULE, COMPONENTS...)
    my $required = grep { $_ eq 'REQUIRED' } @$args;
    my $config_mode = grep { $_ eq 'CONFIG' || $_ eq 'NO_MODULE' } @$args;
    my $module_mode = grep { $_ eq 'MODULE' } @$args;

    # Try config-mode: <Pkg>Config.cmake or <pkg>-config.cmake
    my @search_paths = _find_package_search_paths($name, $scope);
    my $config_file;
    for my $dir (@search_paths) {
        for my $suffix ("${name}Config.cmake", lc($name) . "-config.cmake") {
            if (-f "$dir/$suffix") {
                $config_file = "$dir/$suffix";
                last;
            }
        }
        last if $config_file;
    }

    if ($config_file) {
        $scope->{vars}{"${name}_FOUND"} = 'TRUE';
        $scope->{vars}{"${name}_DIR"} = dirname($config_file);
        warn "SmakCMake: find_package($name) → $config_file\n"
            if $ENV{SMAK_CMAKE_DEBUG};
        my $sub = parse_file($config_file);
        my $saved_ld = $scope->{vars}{CMAKE_CURRENT_LIST_DIR};
        my $saved_lf = $scope->{vars}{CMAKE_CURRENT_LIST_FILE};
        $scope->{vars}{CMAKE_CURRENT_LIST_DIR} = dirname($config_file);
        $scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $config_file;
        eval_commands($sub, $state, $scope);
        $scope->{vars}{CMAKE_CURRENT_LIST_DIR} = $saved_ld;
        $scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $saved_lf;
        return;
    }

    # Try module-mode: Find<Name>.cmake in CMAKE_MODULE_PATH + our own modules dir
    unless ($config_mode) {
        my @mod_paths = split /;/, (_lookup('CMAKE_MODULE_PATH', $scope) // '');
        push @mod_paths, "/usr/local/src/smak/cmake-modules";
        for my $dir (@mod_paths) {
            my $mod = "$dir/Find$name.cmake";
            if (-f $mod) {
                warn "SmakCMake: find_package($name) module → $mod\n"
                    if $ENV{SMAK_CMAKE_DEBUG};
                my $sub = parse_file($mod);
                eval_commands($sub, $state, $scope);
                return;
            }
        }
        # Built-in FindXxx handlers for common packages
        if (_find_package_builtin($name, $state, $scope)) {
            return;
        }
    }

    $scope->{vars}{"${name}_FOUND"} = 'FALSE';
    if ($required) {
        warn "SmakCMake: find_package($name) REQUIRED but not found\n";
    }
};

sub _find_package_search_paths {
    my ($name, $scope) = @_;
    my @paths;
    # <Pkg>_DIR (if set)
    my $dir_var = _lookup("${name}_DIR", $scope);
    push @paths, $dir_var if $dir_var && -d $dir_var;
    # ROOT env var
    my $root = $ENV{"${name}_ROOT"} || _lookup("${name}_ROOT", $scope);
    if ($root) {
        push @paths, "$root/lib/cmake/$name",
                     "$root/cmake/$name",
                     "$root/share/$name/cmake",
                     $root;
    }
    # Common install locations
    push @paths, (
        "/usr/local/$name/lib/cmake/$name",
        "/usr/local/lib/cmake/$name",
        "/usr/lib/cmake/$name",
        "/usr/lib/x86_64-linux-gnu/cmake/$name",
    );
    # Trilinos-specific convenience: we maintain a local install
    if ($name eq 'Trilinos') {
        push @paths, '/usr/local/trilinos/lib/cmake/Trilinos',
                     '/usr/local/trilinos/include',
                     '/usr/local/src/Trilinos-Build';
    }
    return @paths;
}

sub _find_package_builtin {
    my ($name, $state, $scope) = @_;
    my %builtins = (
        Threads => sub {
            $scope->{vars}{Threads_FOUND} = 'TRUE';
            $scope->{vars}{CMAKE_THREAD_LIBS_INIT} = '-lpthread';
        },
        MPI => sub {
            $scope->{vars}{MPI_FOUND} = 'FALSE';  # no MPI in this sandbox
        },
        PythonInterp => sub {
            if (-x '/usr/bin/python3') {
                $scope->{vars}{PYTHONINTERP_FOUND} = 'TRUE';
                $scope->{vars}{PYTHON_EXECUTABLE} = '/usr/bin/python3';
            }
        },
        Python => sub {
            if (-x '/usr/bin/python3') {
                $scope->{vars}{Python_FOUND} = 'TRUE';
                $scope->{vars}{Python_EXECUTABLE} = '/usr/bin/python3';
            }
        },
        Python3 => sub {
            if (-x '/usr/bin/python3') {
                $scope->{vars}{Python3_FOUND} = 'TRUE';
                $scope->{vars}{Python3_EXECUTABLE} = '/usr/bin/python3';
            }
        },
        BISON => sub {
            if (-x '/usr/bin/bison') {
                $scope->{vars}{BISON_FOUND} = 'TRUE';
                $scope->{vars}{BISON_EXECUTABLE} = '/usr/bin/bison';
                $scope->{vars}{BISON_VERSION} = '3.8.2';
            }
        },
        FLEX => sub {
            if (-x '/usr/bin/flex') {
                $scope->{vars}{FLEX_FOUND} = 'TRUE';
                $scope->{vars}{FLEX_EXECUTABLE} = '/usr/bin/flex';
            }
        },
        GTest => sub {
            if (-f '/usr/include/gtest/gtest.h') {
                $scope->{vars}{GTest_FOUND} = 'TRUE';
                $scope->{vars}{GTEST_FOUND} = 'TRUE';
                $scope->{vars}{GTEST_INCLUDE_DIRS} = '/usr/include';
                $scope->{vars}{GTEST_LIBRARIES} = '-lgtest';
            }
        },
    );
    if ($builtins{$name}) {
        $builtins{$name}->();
        return 1;
    }
    return 0;
}

$builtins{'add_subdirectory'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $subdir = $args->[0];
    # If subdir is absolute use as-is, else relative to current_source_dir
    my $source_subdir = $subdir =~ m{^/} ? $subdir
        : File::Spec->catdir($state->{current_source_dir}, $subdir);
    my $binary_subdir = $args->[1];
    if ($binary_subdir) {
        $binary_subdir = File::Spec->catdir($state->{current_binary_dir}, $binary_subdir)
            unless $binary_subdir =~ m{^/};
    } else {
        $binary_subdir = File::Spec->catdir($state->{current_binary_dir}, $subdir);
    }
    my $sub_cmake = "$source_subdir/CMakeLists.txt";
    return unless -f $sub_cmake;

    my $sub_commands = parse_file($sub_cmake);
    my $sub_scope = new_scope($scope);
    # CMAKE_CURRENT_SOURCE_DIR/BINARY_DIR get the new values in the sub-scope
    $sub_scope->{vars}{CMAKE_CURRENT_SOURCE_DIR} = $source_subdir;
    $sub_scope->{vars}{CMAKE_CURRENT_BINARY_DIR} = $binary_subdir;

    my $saved_src = $state->{current_source_dir};
    my $saved_bin = $state->{current_binary_dir};
    $state->{current_source_dir} = $source_subdir;
    $state->{current_binary_dir} = $binary_subdir;

    eval_commands($sub_commands, $state, $sub_scope);
    delete $sub_scope->{_return};

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

    # Per-target metadata
    for my $name (sort keys %{$state->{targets}}) {
        my $t = $state->{targets}{$name};
        # Skip interface/imported/alias libraries (no build rules)
        next if $t->{libtype} && $t->{libtype} =~ /^(interface|imported|alias)$/;
        next if $t->{imported};
        # Skip targets with :: in the name (conventional for imported targets)
        next if $name =~ /::/;
        # Skip targets with no sources unless they're custom
        next if !@{$t->{sources}} && $t->{type} ne 'custom';

        # Place .dir under the target's binary_dir (matches cmake's layout)
        my $tbin = $t->{binary_dir} // $build_dir;
        my $tdir = "$tbin/CMakeFiles/$name.dir";
        make_path($tdir);

        _write_flags_make($t, $tdir, $state, $name);
        _write_depend_info($t, $tdir, $state, $name);
        _write_link_txt($t, $tdir, $state, $name);
    }

    # Inter-target dependency graph
    _write_makefile2($state);

    # Custom command rules
    _write_custom_rules($state);

    # CMakeCache.txt (minimal - just what SmakCMake reads)
    _write_cmake_cache($state);

    # Top-level Makefile (for `make` compatibility — not strictly needed
    # for smak since SmakCMake reads CMakeFiles/ directly)
    _write_top_makefile($state);
}

# Write rules for add_custom_command outputs into a single rules.make.
# SmakCMake doesn't read this yet — but make can use it, and we can
# later hook it into SmakCMake's rule tables directly.
sub _write_custom_rules {
    my ($state) = @_;
    my $build_dir = $state->{build_dir};
    my @cmds = @{$state->{custom_commands} // []};
    return unless @cmds;

    use File::Path qw(make_path);
    open(my $fh, '>', "$build_dir/CMakeFiles/custom_rules.make")
        or die "write custom_rules.make: $!";
    print $fh "# CMAKE generated file: DO NOT EDIT!\n";
    print $fh "# Generated by SmakCMakeInterp\n\n";
    for my $c (@cmds) {
        my @outs = @{$c->{output} // []};
        next unless @outs;
        my @deps = @{$c->{depends} // []};
        my $primary = shift @outs;
        my $dir = $c->{working_dir} // $c->{binary_dir} // $build_dir;
        # Ensure output dir exists so bison/flex can write to it
        my $outdir = $primary;
        $outdir =~ s{/[^/]*$}{};
        make_path($outdir) if $outdir && $outdir ne $primary;

        # Primary rule
        print $fh "$primary: " . join(' ', @deps) . "\n";
        print $fh "\t\@mkdir -p " . _shell_quote($outdir) . "\n" if $outdir;
        print $fh "\tcd " . _shell_quote($dir) . " && ";
        print $fh join(" && ", @{$c->{commands} // []});
        print $fh "\n\n";

        # Side-output rules — depend on primary (so building primary produces them)
        for my $o (@outs) {
            print $fh "$o: $primary\n\n";
        }
    }
    close($fh);
}

sub _shell_quote {
    my $s = shift // '';
    return "'$s'" if $s =~ /[\s\$'"()\\]/;
    return $s;
}

sub _write_makefile2 {
    my ($state) = @_;
    my $build_dir = $state->{build_dir};
    open(my $fh, '>', "$build_dir/CMakeFiles/Makefile2") or die "write Makefile2: $!";
    print $fh "# CMAKE generated file: DO NOT EDIT!\n";
    print $fh "# Generated by SmakCMakeInterp\n\n";
    print $fh "default_target: all\n.PHONY: default_target\n\n";

    # Collect real build targets (with sources)
    my @real = grep {
        my $t = $state->{targets}{$_};
        @{$t->{sources}} > 0 && $t->{type} ne 'custom'
    } sort keys %{$state->{targets}};

    # all: depends on all real targets
    print $fh "all:";
    for my $n (@real) {
        my $t = $state->{targets}{$n};
        print $fh " ", _target_all_key($t, $n, $build_dir);
    }
    print $fh "\n.PHONY: all\n\n";

    # Per-target "all" rules (with inter-target deps from link_libraries)
    for my $n (@real) {
        my $t = $state->{targets}{$n};
        my $all_key = _target_all_key($t, $n, $build_dir);

        # Dependencies: each link_libraries target's own /all
        my @deps;
        for my $lib (@{$t->{link_libraries} // []}) {
            if ($state->{targets}{$lib}) {
                push @deps, _target_all_key($state->{targets}{$lib}, $lib, $build_dir);
            }
        }
        if (@deps) {
            for my $d (@deps) {
                print $fh "$all_key: $d\n";
            }
        }
        print $fh "$all_key:\n\n";
    }

    close($fh);
}

sub _target_rel_dir {
    my ($t, $build_dir) = @_;
    my $dir = $t->{binary_dir} // $build_dir;
    my $rel = File::Spec->abs2rel($dir, $build_dir);
    return '.' if $rel eq '' || $rel eq '.';
    return $rel;
}

sub _target_all_key {
    my ($t, $name, $build_dir) = @_;
    my $rel = _target_rel_dir($t, $build_dir);
    return $rel eq '.' ? "CMakeFiles/$name.dir/all" : "$rel/CMakeFiles/$name.dir/all";
}

sub _write_cmake_cache {
    my ($state) = @_;
    my $build_dir = $state->{build_dir};
    open(my $fh, '>', "$build_dir/CMakeCache.txt") or die "write CMakeCache.txt: $!";
    print $fh "# Generated by SmakCMakeInterp\n";
    print $fh "CMAKE_HOME_DIRECTORY:INTERNAL=$state->{source_dir}\n";
    print $fh "CMAKE_COMMAND:INTERNAL=/usr/local/src/smak/cmake-install/bin/cmake\n";
    print $fh "CMAKE_C_COMPILER:FILEPATH=/usr/bin/cc\n";
    print $fh "CMAKE_CXX_COMPILER:FILEPATH=/usr/bin/c++\n";
    print $fh "CMAKE_Fortran_COMPILER:FILEPATH=/usr/bin/gfortran\n";
    print $fh "CMAKE_AR:FILEPATH=/usr/bin/ar\n";
    print $fh "CMAKE_RANLIB:FILEPATH=/usr/bin/ranlib\n";
    close($fh);
}

sub _write_top_makefile {
    my ($state) = @_;
    my $build_dir = $state->{build_dir};
    open(my $fh, '>', "$build_dir/Makefile") or die "write Makefile: $!";
    print $fh "# Generated by SmakCMakeInterp — minimal stub.\n";
    print $fh "# smak reads CMakeFiles/ directly; this file is for `make` compatibility.\n\n";
    print $fh "all:\n\t\@echo 'Use smak to build this project (or run cmake).'\n";
    print $fh ".PHONY: all clean\n";
    print $fh "clean:\n\t\@echo 'clean not implemented by SmakCMakeInterp yet'\n";
    close($fh);
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
    my ($t, $tdir, $state, $name) = @_;
    open(my $fh, '>', "$tdir/flags.make") or die "write $tdir/flags.make: $!";
    print $fh "# CMAKE generated file: DO NOT EDIT!\n";
    print $fh "# Generated by SmakCMakeInterp\n\n";

    # Emit flags for each language the target uses
    my %langs;
    for my $src (@{$t->{sources}}) {
        $langs{ _src_lang($src) }++;
    }
    for my $lang (sort keys %langs) {
        print $fh "# compile $lang with ", _compiler_for_lang($lang), "\n";
        print $fh "${lang}_DEFINES = ", ($t->{compile_definitions} // ''), "\n";
        print $fh "${lang}_INCLUDES = ", _include_flags($t), "\n";
        print $fh "${lang}_FLAGS = ", ($t->{compile_options} // ''), "\n\n";
    }
    close($fh);
}

sub _src_lang {
    my $src = shift;
    return 'Fortran' if $src =~ /\.f(\d+)?$/i;
    return 'C'       if $src =~ /\.c$/;
    return 'CXX';    # default for .cc/.cpp/.cxx/.C
}

sub _write_depend_info {
    my ($t, $tdir, $state, $name) = @_;
    my $lang = _primary_lang($t);
    # CMake writes obj paths in DependInfo.cmake relative to the TOP
    # build dir (e.g., "src/CMakeFiles/XyceLib.dir/foo.o").
    my $build_dir = $state->{build_dir};
    my $tbin = $t->{binary_dir} // $build_dir;
    my $rel_bin = File::Spec->abs2rel($tbin, $build_dir);
    $rel_bin = '' if $rel_bin eq '.';
    my $obj_prefix = $rel_bin eq '' ? "CMakeFiles/$name.dir"
                                    : "$rel_bin/CMakeFiles/$name.dir";

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
        my $obj = "$obj_prefix/$obj_base.o";
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
        my @libs = _resolve_link_libraries($t, $state);
        # Wrap static libs in --start-group/--end-group so the linker can
        # resolve circular references between them (common with Trilinos).
        # Linker flags (-lm, -pthread) and shared libs stay outside.
        my $libs_str = '';
        if (@libs) {
            my @static = grep { /\.a$/ } @libs;
            my @rest = grep { !/\.a$/ } @libs;
            if (@static) {
                $libs_str .= ' -Wl,--start-group ' . join(' ', @static) . ' -Wl,--end-group';
            }
            $libs_str .= ' ' . join(' ', @rest) if @rest;
        }
        $link_cmd = "$compiler " . join(' ', @objs) . " -o $name" . $libs_str;
    } else {
        $link_cmd = "# unsupported target type: $t->{type}";
    }

    open(my $fh, '>', "$tdir/link.txt") or die "write $tdir/link.txt: $!";
    print $fh $link_cmd, "\n";
    close($fh);
}

# Resolve a target's link_libraries (and transitive INTERFACE_LINK_LIBRARIES)
# to an ordered, deduplicated list of linker flags.  Each library is either:
#   - a filesystem path (.a, .so) -- used as-is
#   - "-lfoo" style flag -- passed through
#   - a bareword "-lfoo" (no leading slash) -- treat as -lX
#   - a known target name -- resolved to its output path or IMPORTED_LOCATION
sub _resolve_link_libraries {
    my ($t, $state) = @_;
    my @out;
    my %seen;
    my @queue = @{$t->{link_libraries} // []};
    while (@queue) {
        my $lib = shift @queue;
        next unless defined $lib;
        next if $seen{$lib}++;

        # Known target?
        my $lt = $state->{targets}{$lib};
        if ($lt) {
            # Expand transitive interface deps
            push @queue, @{$lt->{interface_link_libraries} // []};
            # Does it have an IMPORTED_LOCATION?
            if ($lt->{imported_location}) {
                push @out, $lt->{imported_location};
                next;
            }
            # Skip interface/alias/:: targets with no output
            next if $lib =~ /::/;
            next if $lt->{libtype} && $lt->{libtype} eq 'interface';
            next unless @{$lt->{sources} // []};
            # Our own target — point at where the link will produce the .a
            my $bin = $lt->{binary_dir} // $state->{build_dir};
            push @out, "$bin/lib$lib.a";
            next;
        }
        # Starts with /  → filesystem path
        if ($lib =~ m{^/}) {
            push @out, $lib;
            next;
        }
        # Starts with - → linker flag (-lm, -pthread, etc.)
        if ($lib =~ /^-/) {
            push @out, $lib;
            next;
        }
        # Bare name — pass as -lname
        push @out, "-l$lib";
    }
    return @out;
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
    my %seen;
    @inc = grep { $_ ne '' && !$seen{$_}++ } @inc;
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
    $root_scope->{_state} = $state;  # for predicates like TARGET that need state access
    # Predefined CMake variables
    $root_scope->{vars}{CMAKE_SOURCE_DIR} = $source_dir;
    $root_scope->{vars}{CMAKE_BINARY_DIR} = $build_dir;
    $root_scope->{vars}{CMAKE_CURRENT_SOURCE_DIR} = $source_dir;
    $root_scope->{vars}{CMAKE_CURRENT_BINARY_DIR} = $build_dir;
    $root_scope->{vars}{CMAKE_CURRENT_LIST_DIR} = $source_dir;
    $root_scope->{vars}{CMAKE_CURRENT_LIST_FILE} = "$source_dir/CMakeLists.txt";
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
