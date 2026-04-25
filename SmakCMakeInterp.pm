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

# Locate the cmake-install that ships alongside smak. Works whether
# smak lives in /usr/local/src/smak (dev checkout) or
# /.../share/smak (installed). Falls back to the hard-coded path.
sub _cmake_install_root {
    my $this = __FILE__;
    my $dir  = dirname($this);
    for my $cand ("$dir/cmake-install", '/usr/local/src/smak/cmake-install') {
        return $cand if -d "$cand/bin" && -x "$cand/bin/cmake";
    }
    return "$dir/cmake-install";
}
sub _cmake_modules_dir {
    my $root = _cmake_install_root();
    my ($ver) = glob("$root/share/cmake-*");
    return $ver ? "$ver/Modules" : "$root/share/cmake-3.31/Modules";
}

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
            # Special-case `\$`: per CMake docs, an escaped dollar
            # disables the following `${...}` from being expanded as a
            # variable reference. Encode it as a sentinel ("\x01") so
            # expand() can skip past it, then convert back to '$'.
            if ($nc eq '$') { $text .= "\x01"; next; }
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
    # CMake variable expansion: ONE left-to-right pass. The text
    # introduced by a substitution is NOT re-scanned — that's how
    # `set(DOLLAR "$") ; "${DOLLAR}{X}"` produces literal `${X}`. But
    # within a single `${...}`, nested forms like `${${var}_libs}` are
    # evaluated inside-out.
    my @out;
    my $i = 0;
    my $len = length($str);
    while ($i < $len) {
        my $c = substr($str, $i, 1);
        if ($c eq '$' && $i + 1 < $len) {
            my $next = substr($str, $i + 1, 1);
            if ($next eq '{') {
                # Find matching }
                my $start = $i + 2;
                my $j = $start;
                my $depth = 1;
                while ($j < $len && $depth > 0) {
                    my $c2 = substr($str, $j, 1);
                    if ($c2 eq '{') { $depth++; }
                    elsif ($c2 eq '}') { $depth--; }
                    $j++;
                }
                if ($depth == 0) {
                    my $inner = substr($str, $start, $j - $start - 1);
                    # Evaluate inner recursively (so ${${var}_libs} works)
                    my $name = expand($inner, $scope);
                    push @out, _lookup($name, $scope) // '';
                    $i = $j;
                    next;
                }
            } elsif ($next eq 'E' && substr($str, $i, 5) eq '$ENV{') {
                my $start = $i + 5;
                my $j = index($str, '}', $start);
                if ($j >= 0) {
                    my $name = expand(substr($str, $start, $j - $start), $scope);
                    push @out, $ENV{$name} // '';
                    $i = $j + 1;
                    next;
                }
            } elsif ($next eq 'C' && substr($str, $i, 7) eq '$CACHE{') {
                my $start = $i + 7;
                my $j = index($str, '}', $start);
                if ($j >= 0) {
                    my $name = expand(substr($str, $start, $j - $start), $scope);
                    push @out, _lookup_cache($name, $scope) // '';
                    $i = $j + 1;
                    next;
                }
            }
        }
        push @out, $c;
        $i++;
    }
    my $result = join('', @out);
    # Convert sentinel back to literal '$' (set by _read_quoted_string for `\$`).
    $result =~ s/\x01/\$/g;
    return $result;
}

sub _lookup {
    my ($name, $scope) = @_;
    # Walk scope chain
    my $depth = 0;
    while ($scope) {
        if (exists $scope->{vars}{$name}) {
            if ($ENV{SMAK_CMAKE_TRACE_LOOKUP} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_LOOKUP}\E$/) {
                warn "TRACE-lookup: $name at depth $depth = [" . ($scope->{vars}{$name}//"undef") . "]\n";
            }
            return $scope->{vars}{$name};
        }
        $scope = $scope->{parent};
        $depth++;
    }
    warn "TRACE-lookup: $name not found\n"
        if $ENV{SMAK_CMAKE_TRACE_LOOKUP} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_LOOKUP}\E$/;
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
            # For if() we need to know which args were quoted so STREQUAL
            # etc. don't re-dereference already-expanded quoted strings.
            # Produce a parallel list of "is quoted" flags aligned with
            # the flat expanded args.
            my (@args, @quoted);
            for my $a (@{$branches[$b]{args}}) {
                my $q = ($a->{type} eq 'quoted' || $a->{type} eq 'bracket');
                my @vs = expand_arg($a, $scope);
                for my $v (@vs) { push @args, $v; push @quoted, $q; }
            }
            $truthy = _if_test(\@args, $scope, \@quoted);
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
    my ($args, $scope, $quoted) = @_;
    $quoted //= [(0) x scalar @$args];
    return _if_expr($args, $scope, $quoted);
}

# _deref_q: like _deref, but if $was_quoted, the value is a literal and we
# don't attempt a second lookup. CMake's if() rule: quoted strings are
# literals for STREQUAL etc.; only bare (unquoted) operands are looked up.
sub _deref_q {
    my ($v, $scope, $was_quoted) = @_;
    return $v if $was_quoted;
    return _deref($v, $scope);
}

sub _if_expr {
    my ($args, $scope, $quoted) = @_;
    $quoted //= [(0) x scalar @$args];

    # Strip a single enclosing pair of parens: ( expr ). Detect the pair by
    # scanning to the matching close paren. If it equals $#args, strip it.
    while (@$args >= 2 && !$quoted->[0] && $args->[0] eq '('
           && !$quoted->[-1] && $args->[-1] eq ')') {
        my $depth = 0; my $matched_end = -1;
        for my $i (0 .. $#$args) {
            next if $quoted->[$i];
            $depth++ if $args->[$i] eq '(';
            $depth-- if $args->[$i] eq ')';
            if ($depth == 0) { $matched_end = $i; last; }
        }
        last if $matched_end != $#$args;   # outer ( not matched to outer )
        shift @$args; shift @$quoted;
        pop @$args;   pop @$quoted;
    }

    # Recursively evaluate any parenthesized subgroup and replace it with
    # its truthy value ('1' or '0'). Repeat until no bare parens remain.
    while (1) {
        my $open = -1;
        for my $i (0 .. $#$args) {
            if (!$quoted->[$i] && $args->[$i] eq '(') { $open = $i; last; }
        }
        last if $open < 0;
        my $depth = 0; my $close = -1;
        for my $i ($open .. $#$args) {
            next if $quoted->[$i];
            $depth++ if $args->[$i] eq '(';
            $depth-- if $args->[$i] eq ')';
            if ($depth == 0) { $close = $i; last; }
        }
        last if $close < 0;
        my @inner  = @$args[$open+1 .. $close-1];
        my @innerq = @$quoted[$open+1 .. $close-1];
        my $val = _if_expr(\@inner, $scope, \@innerq) ? '1' : '0';
        splice(@$args,   $open, $close - $open + 1, $val);
        splice(@$quoted, $open, $close - $open + 1, 0);
    }

    # Handle OR (lowest precedence) — but only when OR is an UNQUOTED keyword
    for (my $i = 0; $i < @$args; $i++) {
        if (!$quoted->[$i] && uc($args->[$i]) eq 'OR') {
            my @l  = @$args[0..$i-1];
            my @r  = @$args[$i+1..$#$args];
            my @lq = @$quoted[0..$i-1];
            my @rq = @$quoted[$i+1..$#$quoted];
            return _if_expr(\@l, $scope, \@lq) || _if_expr(\@r, $scope, \@rq);
        }
    }
    for (my $i = 0; $i < @$args; $i++) {
        if (!$quoted->[$i] && uc($args->[$i]) eq 'AND') {
            my @l  = @$args[0..$i-1];
            my @r  = @$args[$i+1..$#$args];
            my @lq = @$quoted[0..$i-1];
            my @rq = @$quoted[$i+1..$#$quoted];
            return _if_expr(\@l, $scope, \@lq) && _if_expr(\@r, $scope, \@rq);
        }
    }
    # NOT
    if (@$args >= 1 && !$quoted->[0] && uc($args->[0]) eq 'NOT') {
        my @r  = @$args[1..$#$args];
        my @rq = @$quoted[1..$#$quoted];
        return !_if_expr(\@r, $scope, \@rq);
    }
    # Binary predicates
    if (@$args == 3) {
        my ($l, $op, $r)    = @$args;
        my ($lq, $oq, $rq)  = @$quoted;
        my $uop = !$oq ? uc($op) : '';
        return _deref_q($l, $scope, $lq) eq _deref_q($r, $scope, $rq) if $uop eq 'STREQUAL';
        return _deref_q($l, $scope, $lq) ne _deref_q($r, $scope, $rq) if $uop eq 'STRNOTEQUAL';
        return _deref_q($l, $scope, $lq) == _deref_q($r, $scope, $rq) if $uop eq 'EQUAL';
        return _deref_q($l, $scope, $lq) <  _deref_q($r, $scope, $rq) if $uop eq 'LESS';
        return _deref_q($l, $scope, $lq) <= _deref_q($r, $scope, $rq) if $uop eq 'LESS_EQUAL';
        return _deref_q($l, $scope, $lq) >  _deref_q($r, $scope, $rq) if $uop eq 'GREATER';
        return _deref_q($l, $scope, $lq) >= _deref_q($r, $scope, $rq) if $uop eq 'GREATER_EQUAL';
        if ($uop eq 'MATCHES') {
            my $s = _deref_q($l, $scope, $lq);
            return $s =~ /$r/;
        }
        if ($uop =~ /^VERSION_/) {
            return _version_cmp(_deref_q($l, $scope, $lq), $uop,
                                _deref_q($r, $scope, $rq));
        }
        if ($uop eq 'IN_LIST') {
            # Left is value (deref if unquoted id), right is list var name.
            my $needle = _deref_q($l, $scope, $lq);
            my $listval = _lookup($r, $scope) // '';
            for my $item (split /;/, $listval) {
                return 1 if $item eq $needle;
            }
            return 0;
        }
    }
    # Unary predicates
    if (@$args == 2) {
        my ($op, $arg) = @$args;
        my $uop = !$quoted->[0] ? uc($op) : '';
        if ($uop eq 'DEFINED') {
            # DEFINED CACHE{X} / ENV{X} / normal VAR
            if ($arg =~ /^CACHE\{([^}]+)\}$/) {
                my $s = $scope;
                while ($s->{parent}) { $s = $s->{parent}; }
                return exists $s->{cache}{$1} ? 1 : 0;
            }
            if ($arg =~ /^ENV\{([^}]+)\}$/) {
                return exists $ENV{$1} ? 1 : 0;
            }
            return exists _find_var($arg, $scope)->{$arg} ? 1 : 0;
        }
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
        # Quoted single value: the string IS the value; only the
        # false-constant short-list counts as false. No var lookup.
        if ($quoted->[0]) {
            return 0 if !defined $v;
            return 1 if $v =~ /^(1|ON|YES|TRUE|Y)$/i;
            return 0 if $v =~ /^(0|OFF|NO|FALSE|N|IGNORE|NOTFOUND|)$/i;
            return 0 if $v =~ /-NOTFOUND$/;
            return 1;  # any other non-empty string is truthy when quoted
        }
        return _truthy($v, $scope);
    }
    # Empty
    return 0;
}

# Is a bare value "truthy" in cmake if() context?
# Per CMake: a value is false if it's 0, OFF, NO, FALSE, N, IGNORE, NOTFOUND,
# empty, or ends in -NOTFOUND. A value like "/foo" is TRUE. For a bare word,
# we dereference once: if it names a variable, the variable's value is the
# final answer (no second dereference — paths shouldn't be looked up as vars).
sub _truthy {
    my ($v, $scope) = @_;
    return 0 if !defined $v;
    return 1 if $v =~ /^(1|ON|YES|TRUE|Y)$/i;
    return 0 if $v =~ /^(0|OFF|NO|FALSE|N|IGNORE|NOTFOUND|)$/i;
    return 0 if $v =~ /-NOTFOUND$/;
    # If $v looks like a plain identifier, resolve it as a variable once.
    # Otherwise it's already a literal (path, number, string) → truthy.
    if ($v =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        my $lookup = _lookup($v, $scope);
        return 0 unless defined $lookup;
        return 0 if $lookup eq '';
        return 0 if $lookup =~ /^(0|OFF|NO|FALSE|N|IGNORE|NOTFOUND)$/i;
        return 0 if $lookup =~ /-NOTFOUND$/;
        return 1;
    }
    return 1;
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
        # CMake: inside a function/macro body, ${CMAKE_CURRENT_LIST_DIR}
        # refers to the file containing the *definition*, not the caller.
        # Capture it now so _call_function can restore it.
        list_dir => _lookup('CMAKE_CURRENT_LIST_DIR', $scope),
        list_file => _lookup('CMAKE_CURRENT_LIST_FILE', $scope),
    };
    return $end + 1;
}

sub eval_command {
    my ($cmd, $state, $scope) = @_;
    if ($ENV{SMAK_CMAKE_TRACE_RAW} && $cmd->{name} =~ /^\Q$ENV{SMAK_CMAKE_TRACE_RAW}\E$/) {
        warn "RAW $cmd->{name} at $cmd->{source}:$cmd->{line}: "
             . scalar(@{$cmd->{args}}) . " raw args [",
             join(' | ', map { "($_->{type}:$_->{text})" } @{$cmd->{args}}), "]\n";
    }
    my @expanded = expand_args($cmd->{args}, $scope);
    if ($ENV{SMAK_CMAKE_TRACE_RAW} && $cmd->{name} =~ /^\Q$ENV{SMAK_CMAKE_TRACE_RAW}\E$/) {
        warn "RAW expanded: " . scalar(@expanded) . " args ["
             . join(' | ', map { $_ // '' } @expanded) . "]\n";
    }
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
    if ($ENV{SMAK_CMAKE_TRACE} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE}\E$/) {
        my @dbg = map { defined $_ ? "[$_]" : "[undef]" } @$args;
        warn "TRACE: $name(" . join(' ', @dbg) . ")\n";
    }
    if ($ENV{SMAK_CMAKE_TRACE_ARGS} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_ARGS}\E$/) {
        warn "TRACE-args $name: " . scalar(@$args) . " args -> ["
             . join("|", map { $_ // '' } @$args) . "]\n";
    }
    if ($ENV{SMAK_CMAKE_TRACE_IN} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_IN}\E$/
        && $args->[0] && $ENV{SMAK_CMAKE_TRACE_PKG}
        && $args->[0] eq $ENV{SMAK_CMAKE_TRACE_PKG}) {
        warn "==== enter $name for " . $args->[0] . " ====\n";
        $scope->{_trace_fn} = 1;
    }
    my $fn = $state->{functions}{$name};
    my $call_scope = $fn->{is_macro} ? $scope : new_scope($scope);
    $args = [] unless ref($args) eq 'ARRAY';
    my $params = (ref($fn->{params}) eq 'ARRAY') ? $fn->{params} : [];

    # For macros, parameter names (ARGC/ARGV/ARGVn/ARGN + named params) are
    # technically textual substitutions in CMake. We simulate by binding
    # them as vars, then restoring on exit so inner macro calls that share
    # param names don't clobber the outer macro's bindings.
    my %saved;
    my $remember = sub {
        my $n = shift;
        return if exists $saved{$n};
        $saved{$n} = exists $call_scope->{vars}{$n}
            ? $call_scope->{vars}{$n}
            : undef;  # means: wasn't set, delete on restore
    };

    $remember->('ARGC'); $remember->('ARGV'); $remember->('ARGN');
    $call_scope->{vars}{ARGC} = scalar @$args;
    $call_scope->{vars}{ARGV} = join(';', map { ref($_) ? '' : ($_ // '') } @$args);
    for my $k (0 .. $#$args) {
        $remember->("ARGV$k");
        my $v = $args->[$k];
        $call_scope->{vars}{"ARGV$k"} = ref($v) ? '' : (defined $v ? "$v" : '');
    }
    for my $k (0 .. $#$params) {
        $remember->($params->[$k]);
        my $v = $args->[$k];
        $call_scope->{vars}{$params->[$k]} = ref($v) ? '' : ($v // '');
    }
    # ARGN = extra args beyond named params. Must be set even when empty,
    # otherwise _lookup falls through to an outer function's ARGN, which
    # then gets iterated inside this function's foreach(... ${ARGN}).
    my $nparams = scalar @$params;
    if (@$args > $nparams) {
        my @extra = @$args[$nparams..$#$args];
        $call_scope->{vars}{ARGN} = join(';', map { ref($_) ? '' : ($_ // '') } @extra);
    } else {
        $call_scope->{vars}{ARGN} = '';
    }

    # Inside the function body, ${CMAKE_CURRENT_LIST_DIR} should refer to
    # the *defining* file's directory (CMake semantics). Save and restore.
    my $saved_list_dir  = $call_scope->{vars}{CMAKE_CURRENT_LIST_DIR};
    my $saved_list_file = $call_scope->{vars}{CMAKE_CURRENT_LIST_FILE};
    if (defined $fn->{list_dir}) {
        $call_scope->{vars}{CMAKE_CURRENT_LIST_DIR}  = $fn->{list_dir};
    }
    if (defined $fn->{list_file}) {
        $call_scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $fn->{list_file};
    }

    eval_commands($fn->{body}, $state, $call_scope);
    # Clear return flag — it only unwinds to the function boundary
    delete $call_scope->{_return};

    if (defined $saved_list_dir) {
        $call_scope->{vars}{CMAKE_CURRENT_LIST_DIR} = $saved_list_dir;
    } else {
        delete $call_scope->{vars}{CMAKE_CURRENT_LIST_DIR};
    }
    if (defined $saved_list_file) {
        $call_scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $saved_list_file;
    } else {
        delete $call_scope->{vars}{CMAKE_CURRENT_LIST_FILE};
    }

    # Restore ARGC/ARGV/ARGN/ARGVn/named-params to whatever the caller had.
    # (Macros don't open a new scope, so without this, an outer macro's
    # ${param} after a nested-macro call would see the inner macro's
    # bindings — faithful CMake does textual substitution, not lookup.)
    if ($fn->{is_macro}) {
        for my $n (keys %saved) {
            if (defined $saved{$n}) {
                $call_scope->{vars}{$n} = $saved{$n};
            } else {
                delete $call_scope->{vars}{$n};
            }
        }
    }
}

# ─── Built-in commands (minimal) ────────────────────────────────────

$builtins{'set'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    return unless @$args;
    my $name = shift @$args;
    if ($ENV{SMAK_CMAKE_TRACE_SET} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_SET}\E$/) {
        my @dbg = map { defined $_ ? "[$_]" : "[undef]" } @$args;
        warn "TRACE-set: $name = " . join(' ', @dbg) . "\n";
    }
    # Detect CACHE / PARENT_SCOPE / FORCE keywords
    my $cache = 0;
    my $parent = 0;
    my $force = 0;
    my @values;
    my @post_cache;  # args after CACHE: [TYPE DOC ...FORCE?]
    my $after_cache = 0;
    for my $a (@$args) {
        if ($a eq 'CACHE') { $cache = 1; $after_cache = 1; next; }
        if ($a eq 'PARENT_SCOPE') { $parent = 1; last; }
        if ($after_cache) {
            $force = 1 if $a eq 'FORCE';
            push @post_cache, $a;
            next;
        }
        push @values, $a;
    }
    my $value = join(';', @values);
    if ($cache) {
        # Walk to root
        my $s = $scope;
        while ($s->{parent}) { $s = $s->{parent}; }
        # CMake rule: set(X val CACHE TYPE DOC) does NOT overwrite an
        # existing cache entry unless FORCE is specified. Additionally, a
        # regular (non-cache) variable of the same name ALWAYS shadows the
        # cache variable at read time — CMake's cache-set must not clobber
        # an existing normal variable unless FORCE.
        # CMake special case: CACHE INTERNAL is implicitly FORCE.
        my $cache_type = $post_cache[0] // '';
        $force = 1 if $cache_type eq 'INTERNAL';
        my $already = exists $s->{cache}{$name};
        if (!$already || $force) {
            $s->{cache}{$name} = $value;
        }
        # Only update the normal variable if it's not already set in some
        # scope, or if FORCE was given. This mirrors CMake's rule that a
        # normal variable shadows cache; `set(X "" CACHE STRING …)` without
        # FORCE must not clobber a prior `set(X ON)`.
        my $has_normal = 0;
        for (my $sc = $scope; $sc; $sc = $sc->{parent}) {
            if (exists $sc->{vars}{$name}) { $has_normal = 1; last; }
        }
        if ($force) {
            $s->{vars}{$name} = $value;
        } elsif (!$has_normal) {
            $s->{vars}{$name} = $s->{cache}{$name};
        }
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
    if ($ENV{SMAK_CMAKE_TRACE_SET} && $name =~ /^\Q$ENV{SMAK_CMAKE_TRACE_SET}\E$/) {
        warn "TRACE-unset: $name\n";
    }
    delete $scope->{vars}{$name};
};

$builtins{'message'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    return unless @$args;
    my $mode = $args->[0];
    my $suppress = 0;  # Default: print so TriBITS trace output is visible.
    if ($mode =~ /^(STATUS|NOTICE|VERBOSE|CHECK_START|CHECK_PASS|CHECK_FAIL)$/) {
        shift @$args;
    } elsif ($mode =~ /^(DEBUG|TRACE)$/) {
        shift @$args;
        $suppress = !$ENV{SMAK_CMAKE_DEBUG};
    } elsif ($mode eq 'FATAL_ERROR' || $mode eq 'SEND_ERROR') {
        shift @$args;
        warn "CMake Error: ", join(' ', @$args), "\n";
        # Continue on "fatal" so we can see downstream issues. Callers
        # that want die semantics can set SMAK_CMAKE_FATAL=1.
        die "fatal\n" if $mode eq 'FATAL_ERROR' && $ENV{SMAK_CMAKE_FATAL};
        return;
    } elsif ($mode eq 'WARNING' || $mode eq 'AUTHOR_WARNING' || $mode eq 'DEPRECATION') {
        shift @$args;
        warn "CMake Warning: ", join(' ', @$args), "\n";
        return;
    }
    print STDERR join(' ', @$args), "\n" unless $suppress;
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
    my @sources = grep {
        !/^(IMPORTED|ALIAS|GLOBAL|EXCLUDE_FROM_ALL|WIN32|MACOSX_BUNDLE)$/
        && !/\.(h|hh|hpp|hxx|H)$/
    } @$args;
    $state->{targets}{$name} = _new_target($state, 'executable', \@sources);
};

$builtins{'add_library'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $libtype = 'static';
    my $imported = 0;
    my $global = 0;
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
    # Filter out header files (CMake source lists often include the header
    # via bison output; they're not compile targets)
    my @sources = grep { !/\.(h|hh|hpp|hxx|H)$/ } @$args;
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
        next if $a =~ /\.(h|hh|hpp|hxx|H)$/;  # headers aren't compile sources
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
        my $modules_dir = _cmake_modules_dir();
        for my $try ("$modules_dir/$file", "$modules_dir/$file.cmake") {
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
        $start = 0 unless defined $start && $start ne '';
        $len = -1 unless defined $len && $len ne '';
        $scope->{vars}{$out} = $len < 0 ? substr($in, $start) : substr($in, $start, $len);
    } elsif ($op eq 'FIND') {
        # string(FIND <string> <substring> <out_var> [REVERSE])
        my ($in, $sub, $out, $rev) = @$args;
        my $idx = (defined $rev && $rev eq 'REVERSE') ? rindex($in, $sub) : index($in, $sub);
        $scope->{vars}{$out} = $idx;
    } elsif ($op eq 'TIMESTAMP') {
        # string(TIMESTAMP <out_var> [<format string>] [UTC])
        my $out = shift @$args;
        my $fmt = (@$args && $args->[0] ne 'UTC') ? shift @$args : '%Y-%m-%dT%H:%M:%S';
        my $utc = (@$args && $args->[0] eq 'UTC') ? 1 : 0;
        my @t = $utc ? gmtime() : localtime();
        # Map cmake %Y/%m/%d/%H/%M/%S/%j/%a/%A/%b/%B → strftime
        require POSIX;
        $scope->{vars}{$out} = POSIX::strftime($fmt, @t);
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
    # Snapshot the outer match's capture groups before doing any further
    # regex work in here.
    my @cap = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
    # CMake uses \1..\9 for backrefs. Convert to the captured text.
    $repl =~ s/\\(\d)/defined $cap[$1-1] ? $cap[$1-1] : ''/ge;
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
        my $dir = $path;
        $dir =~ s{/[^/]*$}{};
        if ($dir && $dir ne $path && !-d $dir) {
            use File::Path qw(make_path);
            make_path($dir);
        }
        if (open(my $fh, $op eq 'APPEND' ? '>>' : '>', $path)) {
            print $fh join('', @$args);
            close $fh;
        } else {
            warn "file($op) cannot open $path: $!\n" if $ENV{SMAK_CMAKE_DEBUG};
        }
    } elsif ($op eq 'MAKE_DIRECTORY') {
        use File::Path qw(make_path);
        for my $d (@$args) { make_path($d); }
    }
};

$builtins{'configure_file'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($in, $out) = @$args[0, 1];
    my @opts = @$args[2..$#$args];
    my $copy_only = grep { $_ eq 'COPYONLY' } @opts;
    my $at_only   = grep { $_ eq '@ONLY'    } @opts;
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

    if (!$copy_only) {
        # Substitute @VAR@ (single pass — @ syntax doesn't nest)
        $text =~ s/\@([A-Za-z_][A-Za-z0-9_]*)\@/_lookup($1, $scope) \/\/ ''/ge;
        # Substitute ${VAR} — CMake's configure_file does NOT recurse on
        # text introduced by a substitution (this is how TriBITS uses the
        # `${PDOLLAR}` trick: PDOLLAR="$" turns `${PDOLLAR}{pkg}` into
        # `${pkg}` in the output, which is preserved literally so it's
        # looked up at find_package consume time). Under @ONLY, `${}` is
        # preserved completely.
        unless ($at_only) {
            my @out;
            my $pos = 0;
            while ($pos < length($text)) {
                if (substr($text, $pos, 2) eq '${') {
                    # find matching } with nesting
                    my $start = $pos + 2;
                    my $i = $start;
                    my $depth = 1;
                    while ($i < length($text) && $depth > 0) {
                        my $c = substr($text, $i, 1);
                        if ($c eq '{') { $depth++; }
                        elsif ($c eq '}') { $depth--; }
                        $i++;
                    }
                    if ($depth == 0) {
                        my $inner = substr($text, $start, $i - $start - 1);
                        # recursively substitute INSIDE the braces (handles
                        # ${${FOO}}), but the result is NOT re-scanned for
                        # more ${ outside.
                        my $prev_i = '';
                        while ($inner ne $prev_i) {
                            $prev_i = $inner;
                            $inner =~ s/\$\{([^\{\}\$]+?)\}/_lookup($1, $scope) \/\/ ''/ge;
                        }
                        push @out, _lookup($inner, $scope) // '';
                        $pos = $i;
                        next;
                    }
                }
                push @out, substr($text, $pos, 1);
                $pos++;
            }
            $text = join('', @out);
        }
    }
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
    # get_property(<var> <GLOBAL|DIRECTORY|TARGET|SOURCE|CACHE> [<name>] PROPERTY <prop> [SET])
    my $out = shift @$args;
    my $scope_kw = shift @$args;
    my $target_name;
    if ($scope_kw eq 'TARGET' || $scope_kw eq 'CACHE' || $scope_kw eq 'SOURCE') {
        $target_name = shift @$args;
    }
    while (@$args && $args->[0] ne 'PROPERTY') { shift @$args; }
    shift @$args if @$args && $args->[0] eq 'PROPERTY';
    my $prop = shift @$args;
    my $want_set = (@$args && $args->[0] eq 'SET');

    my $val = '';
    if ($scope_kw eq 'CACHE' && $target_name) {
        my $root = $scope;
        while ($root->{parent}) { $root = $root->{parent}; }
        if ($want_set) {
            $val = exists $root->{cache}{$target_name} ? 1 : '';
        } elsif ($prop eq 'VALUE') {
            $val = $root->{cache}{$target_name} // '';
        } else {
            $val = $root->{cache_props}{$target_name}{$prop} // '';
        }
        $scope->{vars}{$out} = $val;
        return;
    }
    if ($scope_kw eq 'GLOBAL') {
        $val = $state->{global_properties}{$prop} // '';
        $scope->{vars}{$out} = $val;
        return;
    }
    if ($scope_kw eq 'TARGET' && $target_name) {
        my $t = $state->{targets}{$target_name};
        if ($t) {
            if    ($prop eq 'INTERFACE_INCLUDE_DIRECTORIES') {
                $val = join(';', @{$t->{interface_include_directories} // []});
            } elsif ($prop eq 'INTERFACE_LINK_LIBRARIES') {
                $val = join(';', @{$t->{interface_link_libraries} // []});
            } elsif ($prop eq 'INTERFACE_COMPILE_DEFINITIONS') {
                $val = join(';', @{$t->{interface_defines_list} // []});
            } elsif ($prop eq 'INCLUDE_DIRECTORIES') {
                $val = join(';', @{$t->{include_directories} // []});
            } elsif ($prop eq 'LINK_LIBRARIES') {
                $val = join(';', @{$t->{link_libraries} // []});
            } elsif ($prop eq 'SOURCES') {
                $val = join(';', @{$t->{sources} // []});
            } elsif ($prop eq 'IMPORTED_LOCATION') {
                $val = $t->{imported_location} // '';
            } else {
                $val = $t->{properties}{$prop} // '';
            }
        }
    }
    $scope->{vars}{$out} = $val;
};

$builtins{'set_property'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # set_property(<scope> <name>... [APPEND|APPEND_STRING] PROPERTY <prop> <vals>...)
    my $scope_kw = shift @$args;
    my @names;
    if ($scope_kw eq 'TARGET' || $scope_kw eq 'CACHE' || $scope_kw eq 'SOURCE'
        || $scope_kw eq 'DIRECTORY' || $scope_kw eq 'TEST') {
        while (@$args && $args->[0] ne 'APPEND' && $args->[0] ne 'APPEND_STRING'
               && $args->[0] ne 'PROPERTY') {
            push @names, shift @$args;
        }
    }
    my $append = 0;
    if (@$args && $args->[0] eq 'APPEND')        { $append = 1; shift @$args; }
    elsif (@$args && $args->[0] eq 'APPEND_STRING') { $append = 2; shift @$args; }
    shift @$args if @$args && $args->[0] eq 'PROPERTY';
    my $prop = shift @$args;
    my @vals = @$args;

    return unless defined $prop;

    if ($scope_kw eq 'GLOBAL') {
        my $cur = $state->{global_properties}{$prop} // '';
        if ($append) {
            my $sep = $append == 2 ? '' : ';';
            $cur .= ($cur eq '' ? '' : $sep) . join(';', @vals);
        } else {
            $cur = join(';', @vals);
        }
        $state->{global_properties}{$prop} = $cur;
        return;
    }

    # Only TARGET scope is wired up end-to-end.  Others are accepted but
    # only stored in {properties} for later lookup.
    for my $name (@names) {
        my $t = $state->{targets}{$name};
        next unless $t;

        # Map to well-known target fields
        my $field;
        if ($prop eq 'INTERFACE_INCLUDE_DIRECTORIES') { $field = 'interface_include_directories'; }
        elsif ($prop eq 'INCLUDE_DIRECTORIES')        { $field = 'include_directories'; }
        elsif ($prop eq 'INTERFACE_LINK_LIBRARIES')   { $field = 'interface_link_libraries'; }
        elsif ($prop eq 'LINK_LIBRARIES')             { $field = 'link_libraries'; }
        elsif ($prop eq 'INTERFACE_COMPILE_DEFINITIONS') { $field = 'interface_defines_list'; }

        if ($field) {
            my @existing = $append ? @{$t->{$field} // []} : ();
            # Flatten and split on ; (CMake semantics)
            my @new;
            for my $v (@vals) {
                push @new, grep { defined $_ && $_ ne '' } split /;/, $v;
            }
            $t->{$field} = [@existing, @new];
        }

        # Also record in the generic properties hash.
        if ($append) {
            my $cur = $t->{properties}{$prop} // '';
            my $sep = $append == 2 ? '' : ';';
            $cur .= ($cur eq '' ? '' : $sep) . join(';', @vals);
            $t->{properties}{$prop} = $cur;
        } else {
            $t->{properties}{$prop} = join(';', @vals);
        }
    }
};

$builtins{'find_program'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    {
        my $cur = _lookup($out, $scope);
        if (defined $cur && $cur ne '' && $cur !~ /-NOTFOUND$/
            && $cur !~ /^\Q$out\E-NOTFOUND$/) {
            return;
        }
    }
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
    {
        my $cur = _lookup($out, $scope);
        if (defined $cur && $cur ne '' && $cur !~ /-NOTFOUND$/
            && $cur !~ /^\Q$out\E-NOTFOUND$/) {
            return;
        }
    }
    my @names;
    my @paths = (
        '/usr/lib/x86_64-linux-gnu',
        '/usr/lib64',
        '/usr/lib', '/usr/local/lib',
        '/usr/local/lib64',
        '/lib/x86_64-linux-gnu', '/lib64', '/lib',
    );
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'NAMES') {
            while (@$args && $args->[0] !~ /^(PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES|NAMES_PER_DIR)$/) {
                push @names, shift @$args;
            }
        } elsif ($kw eq 'PATHS' || $kw eq 'HINTS') {
            while (@$args && $args->[0] !~ /^(NAMES|PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES|NAMES_PER_DIR)$/) {
                unshift @paths, shift @$args;  # user paths take priority
            }
        } elsif ($kw =~ /^(REQUIRED|NO_DEFAULT_PATH|NAMES_PER_DIR)$/) {
            # flag, no arg
        } elsif (@names == 0) {
            # First positional arg is the name
            push @names, $kw;
        }
    }
    for my $name (@names) {
        for my $ext ('.so', '.a', '.so.0', '.so.1') {
            for my $prefix ('lib', '') {
                for my $dir (@paths) {
                    my $path = "$dir/$prefix$name$ext";
                    if (-f $path) {
                        $scope->{vars}{$out} = $path;
                        return;
                    }
                }
            }
        }
    }
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

$builtins{'find_path'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    # CMake rule: if $out already holds a non-NOTFOUND value, skip the
    # search. TriBITS relies on this — it calls find_path twice (scoped
    # then default), and the second call must not clobber the first.
    {
        my $cur = _lookup($out, $scope);
        if (defined $cur && $cur ne '' && $cur !~ /-NOTFOUND$/
            && $cur !~ /^\Q$out\E-NOTFOUND$/) {
            return;
        }
    }
    my @names;
    my @paths = (
        '/usr/include', '/usr/local/include',
        '/usr/include/x86_64-linux-gnu',
    );
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'NAMES') {
            while (@$args && $args->[0] !~ /^(PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES)$/) {
                push @names, shift @$args;
            }
        } elsif ($kw eq 'PATHS' || $kw eq 'HINTS') {
            while (@$args && $args->[0] !~ /^(NAMES|PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES)$/) {
                unshift @paths, shift @$args;
            }
        } elsif ($kw =~ /^(REQUIRED|NO_DEFAULT_PATH)$/) {
            # flag
        } elsif (@names == 0) {
            push @names, $kw;
        }
    }
    for my $name (@names) {
        for my $dir (@paths) {
            if (-f "$dir/$name") {
                $scope->{vars}{$out} = $dir;
                return;
            }
        }
    }
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

# find_package_handle_standard_args(<name> ...)  — set <name>_FOUND based
# on whether the passed-in variables are valid (not ending in -NOTFOUND).
$builtins{'find_package_handle_standard_args'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my @check_vars;
    while (@$args) {
        my $a = shift @$args;
        if ($a eq 'REQUIRED_VARS') {
            while (@$args && $args->[0] !~ /^(REQUIRED_VARS|VERSION_VAR|HANDLE_COMPONENTS|CONFIG_MODE|FOUND_VAR|FAIL_MESSAGE)$/) {
                push @check_vars, shift @$args;
            }
        } elsif ($a =~ /^(VERSION_VAR|FOUND_VAR|FAIL_MESSAGE)$/) {
            shift @$args;  # skip value
        } elsif ($a =~ /^(HANDLE_COMPONENTS|CONFIG_MODE)$/) {
            # flags
        }
    }
    my $all_ok = 1;
    for my $v (@check_vars) {
        my $val = _lookup($v, $scope);
        if (!defined $val || $val eq '' || $val =~ /-NOTFOUND$/) {
            $all_ok = 0; last;
        }
    }
    $scope->{vars}{"${name}_FOUND"} = $all_ok ? 'TRUE' : 'FALSE';
    $scope->{vars}{uc($name) . "_FOUND"} = $all_ok ? 'TRUE' : 'FALSE';
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
    # Expose variables for dependents (CMake's BISON module uses BISON_<NAME>_*)
    $scope->{vars}{"BISON_${name}_OUTPUTS"} = "$output;$header";
    $scope->{vars}{"BISON_${name}_OUTPUT_SOURCE"} = $output;
    $scope->{vars}{"BISON_${name}_OUTPUT_HEADER"} = $header;
    $scope->{vars}{"${name}_OUTPUTS"} = "$output;$header";  # back-compat
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
    $scope->{vars}{"FLEX_${name}_OUTPUTS"} = $output;
    $scope->{vars}{"${name}_OUTPUTS"} = $output;  # back-compat
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
                 _cmake_install_root() . '/include');
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
    $scope->{vars}{$var} = _try_compile($source, 'CXX', $scope) ? 1 : '';
};

$builtins{'check_c_source_compiles'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my ($source, $var) = @$args;
    $scope->{vars}{$var} = _try_compile($source, 'C', $scope) ? 1 : '';
};

sub _try_compile {
    my ($source, $lang, $scope) = @_;
    my $cc = $lang eq 'CXX'
        ? ($scope->{vars}{CMAKE_CXX_COMPILER} // 'c++')
        : ($scope->{vars}{CMAKE_C_COMPILER}  // 'cc');
    my $ext = $lang eq 'CXX' ? '.cc' : '.c';
    require File::Temp;
    my $tmpdir = $ENV{TMPDIR} || '/tmp';
    my ($fh, $path) = File::Temp::tempfile("smakcheckXXXXXX",
        DIR => $tmpdir, SUFFIX => $ext, UNLINK => 1);
    print $fh $source;
    close $fh;
    my $flags = $scope->{vars}{CMAKE_REQUIRED_FLAGS} // '';
    my $obj = "$path.o";
    my $rc = system("$cc $flags -c $path -o $obj >/dev/null 2>&1");
    unlink $obj;
    return $rc == 0;
}

$builtins{'site_name'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $var = $args->[0] or return;
    my $h = `hostname -s 2>/dev/null`;
    chomp $h;
    $h ||= $ENV{HOSTNAME} // 'localhost';
    $scope->{vars}{$var} = $h;
};

$builtins{'enable_language'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    for my $lang (@$args) {
        next if $lang eq 'OPTIONAL';
        $scope->{vars}{"CMAKE_${lang}_COMPILER_WORKS"} = 1;
        $scope->{vars}{"CMAKE_${lang}_COMPILER_LOADED"} = 1;
        if ($lang eq 'C') {
            $scope->{vars}{CMAKE_C_COMPILER}    //= '/usr/bin/cc';
            $scope->{vars}{CMAKE_C_COMPILER_ID} //= 'GNU';
        } elsif ($lang eq 'CXX') {
            $scope->{vars}{CMAKE_CXX_COMPILER}    //= '/usr/bin/c++';
            $scope->{vars}{CMAKE_CXX_COMPILER_ID} //= 'GNU';
        } elsif ($lang eq 'Fortran') {
            $scope->{vars}{CMAKE_Fortran_COMPILER}    //= '/usr/bin/gfortran';
            $scope->{vars}{CMAKE_Fortran_COMPILER_ID} //= 'GNU';
        }
        $state->{languages}{$lang} = 1;
    }
};

$builtins{'find_file'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $out = shift @$args;
    my @names;
    my @paths = ('/usr/include', '/usr/local/include',
                 '/usr/include/x86_64-linux-gnu');
    my $no_default = 0;
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'NAMES') {
            while (@$args && $args->[0] !~ /^(PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES)$/) {
                push @names, shift @$args;
            }
        } elsif ($kw eq 'PATHS' || $kw eq 'HINTS') {
            while (@$args && $args->[0] !~ /^(NAMES|PATHS|HINTS|DOC|REQUIRED|NO_DEFAULT_PATH|PATH_SUFFIXES)$/) {
                unshift @paths, shift @$args;
            }
        } elsif ($kw eq 'NO_DEFAULT_PATH') {
            $no_default = 1;
        } elsif ($kw =~ /^(REQUIRED|PATH_SUFFIXES|DOC)$/) {
            shift @$args if $kw eq 'DOC' || $kw eq 'PATH_SUFFIXES';
        } elsif (!@names) {
            push @names, $kw;
        }
    }
    @paths = grep { !/^\/usr/ } @paths if $no_default;
    for my $name (@names) {
        # If name has a path separator, try it verbatim in each dir
        for my $dir (@paths) {
            my $p = "$dir/$name";
            if (-f $p) { $scope->{vars}{$out} = $p; return; }
        }
        # Or as absolute path
        if ($name =~ m{^/} && -f $name) {
            $scope->{vars}{$out} = $name; return;
        }
    }
    $scope->{vars}{$out} = "$out-NOTFOUND";
};

$builtins{'execute_process'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my (@commands, $wd, $result_var, $output_var, $error_var, $results_var,
        $output_strip, $error_strip, $output_quiet, $error_quiet, $timeout,
        $input_file, $output_file, $error_file, $fatal);
    my @current;
    my $in_command = 0;
    while (@$args) {
        my $kw = shift @$args;
        if ($kw eq 'COMMAND') {
            push @commands, [@current] if $in_command && @current;
            @current = (); $in_command = 1;
            next;
        }
        if ($kw eq 'WORKING_DIRECTORY')              { $in_command = 0; $wd = shift @$args; next; }
        if ($kw eq 'RESULT_VARIABLE')                { $in_command = 0; $result_var  = shift @$args; next; }
        if ($kw eq 'RESULTS_VARIABLE')               { $in_command = 0; $results_var = shift @$args; next; }
        if ($kw eq 'OUTPUT_VARIABLE')                { $in_command = 0; $output_var  = shift @$args; next; }
        if ($kw eq 'ERROR_VARIABLE')                 { $in_command = 0; $error_var   = shift @$args; next; }
        if ($kw eq 'INPUT_FILE')                     { $in_command = 0; $input_file  = shift @$args; next; }
        if ($kw eq 'OUTPUT_FILE')                    { $in_command = 0; $output_file = shift @$args; next; }
        if ($kw eq 'ERROR_FILE')                     { $in_command = 0; $error_file  = shift @$args; next; }
        if ($kw eq 'TIMEOUT')                        { $in_command = 0; $timeout     = shift @$args; next; }
        if ($kw eq 'OUTPUT_STRIP_TRAILING_WHITESPACE') { $in_command = 0; $output_strip = 1; next; }
        if ($kw eq 'ERROR_STRIP_TRAILING_WHITESPACE')  { $in_command = 0; $error_strip  = 1; next; }
        if ($kw eq 'OUTPUT_QUIET')                   { $in_command = 0; $output_quiet = 1; next; }
        if ($kw eq 'ERROR_QUIET')                    { $in_command = 0; $error_quiet  = 1; next; }
        if ($kw eq 'COMMAND_ERROR_IS_FATAL')         { $in_command = 0; $fatal = shift @$args; next; }
        if ($kw eq 'COMMAND_ECHO' || $kw eq 'ENCODING') { $in_command = 0; shift @$args; next; }
        if ($kw eq 'OUTPUT_STRIP_TRAILING_WHITESPACE' || $kw =~ /^(ANY|LAST)$/) { next; }
        if ($in_command) { push @current, $kw; }
    }
    push @commands, [@current] if $in_command && @current;
    return unless @commands;

    # Build pipeline: cmd1 | cmd2 | ... — implement as a single shell line
    # using proper quoting.  This is good enough for TriBITS/Trilinos use.
    my @shell_parts;
    for my $c (@commands) {
        push @shell_parts, join(' ', map {
            my $a = $_; $a =~ s/'/'\\''/g; "'$a'";
        } @$c);
    }
    my $shell = join(' | ', @shell_parts);
    $shell = "cd " . (_sq($wd) // "'.'") . " && $shell" if defined $wd && $wd ne '';

    my $out = `$shell 2>&1`;
    my $rc = $? == -1 ? -1 : ($? >> 8);
    chomp $out if $output_strip;
    $scope->{vars}{$output_var} = $out if defined $output_var;
    $scope->{vars}{$error_var}  = ''  if defined $error_var;
    $scope->{vars}{$result_var} = $rc if defined $result_var;
    $scope->{vars}{$results_var} = $rc if defined $results_var;
    if (defined $fatal && $fatal =~ /^(ANY|LAST)$/ && $rc != 0) {
        die "execute_process failed (rc=$rc): $shell\n";
    }
};

sub _sq {
    my $s = shift;
    return undef unless defined $s;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# fortrancinterface_verify — we don't actually use Fortran for the paths
# we care about (Xyce's Trilinos build uses C-linkage BLAS/LAPACK), so
# stub as success.
$builtins{'fortrancinterface_verify'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    $scope->{vars}{FortranCInterface_VERIFIED_C}   = 1;
    $scope->{vars}{FortranCInterface_VERIFIED_CXX} = 1;
};

# Cmake-internal / rarely-used commands we stub so TriBITS can run.
$builtins{'_cmake_find_compiler_path'}    = sub { };
$builtins{'_cmake_find_compiler_sysroot'} = sub { };
$builtins{'cmake_determine_compiler_id'}  = sub { };
$builtins{'define_property'}              = sub { };
$builtins{'build_command'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $var = $args->[0];
    $scope->{vars}{$var} = 'smak' if $var;
};

$builtins{'separate_arguments'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # separate_arguments(<var>) — in-place: split current value on spaces
    # separate_arguments(<var> <UNIX|WINDOWS|NATIVE>_COMMAND <str>)
    # separate_arguments(<var> PROGRAM [SEPARATE_ARGS] <str>)
    return unless @$args;
    my $var = shift @$args;
    my $mode = @$args ? $args->[0] : '';
    my $src;
    if ($mode && $mode =~ /_COMMAND$/) {
        shift @$args;
        $src = shift(@$args) // '';
    } elsif ($mode eq 'PROGRAM') {
        shift @$args;
        shift @$args if @$args && $args->[0] eq 'SEPARATE_ARGS';
        $src = shift(@$args) // '';
    } else {
        $src = _lookup($var, $scope) // '';
    }
    # Split on whitespace (cmake is more elaborate but this is enough for
    # TriBITS' library-name patterns like "lapack lapack_win32").
    my @parts = split /\s+/, $src;
    @parts = grep { defined $_ && $_ ne '' } @parts;
    $scope->{vars}{$var} = join(';', @parts);
};

$builtins{'cmake_parse_arguments'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # Forms:
    #   cmake_parse_arguments(PARSE_ARGV <N>          <opts> <one> <multi>)
    #   cmake_parse_arguments(<prefix>                <opts> <one> <multi> <args>...)
    if ($ENV{SMAK_CMAKE_TRACE_PARSE_ARGS}) {
        my $prefix = @$args >= 1 ? ($args->[0] eq 'PARSE_ARGV' ? $args->[2] : $args->[0]) : '';
        if ($prefix eq $ENV{SMAK_CMAKE_TRACE_PARSE_ARGS}) {
            warn "TRACE-parse_args($prefix): " . join(' | ', map { "[$_]" } @$args) . "\n";
        }
    }
    return unless @$args >= 4;
    my $prefix;
    my @args_local = @$args;
    if ($args_local[0] eq 'PARSE_ARGV') {
        # Not supported precisely (we don't have ARGN indexing from here).
        # Take prefix from next arg and use ARGN from scope.
        shift @args_local;  # PARSE_ARGV
        shift @args_local;  # N
        $prefix = shift @args_local;
    } else {
        $prefix = shift @args_local;
    }
    my $opts_str  = shift @args_local;
    my $one_str   = shift @args_local;
    my $multi_str = shift @args_local;
    my @opts  = split /;/, ($opts_str  // '');
    my @one   = split /;/, ($one_str   // '');
    my @multi = split /;/, ($multi_str // '');
    my %is_opt   = map { $_ => 1 } @opts;
    my %is_one   = map { $_ => 1 } @one;
    my %is_multi = map { $_ => 1 } @multi;

    # Remaining are the values to parse. If none given explicitly, use ARGN.
    my @vals;
    if (@args_local) {
        @vals = @args_local;
    } else {
        my $argn = _lookup('ARGN', $scope) // '';
        @vals = split /;/, $argn;
    }

    # Initialize all output vars to empty so the "not set" check works
    $scope->{vars}{"${prefix}_${_}"} = '' for @opts;
    $scope->{vars}{"${prefix}_${_}"} = '' for @one;
    $scope->{vars}{"${prefix}_${_}"} = '' for @multi;
    my @unparsed;
    my @keywords_missing_values;

    my $current_key;
    my $current_kind;  # 'one' or 'multi'
    my @current_multi;
    my $commit = sub {
        return unless defined $current_key;
        if ($current_kind eq 'one') {
            # one-value keyword: value in @current_multi (possibly empty)
            if (@current_multi == 0) {
                push @keywords_missing_values, $current_key;
            } else {
                $scope->{vars}{"${prefix}_${current_key}"} = $current_multi[0];
                # anything extra goes to unparsed
                push @unparsed, @current_multi[1..$#current_multi] if @current_multi > 1;
            }
        } else {
            # multi
            if (@current_multi == 0) {
                push @keywords_missing_values, $current_key;
            } else {
                $scope->{vars}{"${prefix}_${current_key}"} = join(';', @current_multi);
            }
        }
        $current_key = undef;
        $current_kind = undef;
        @current_multi = ();
    };

    for my $v (@vals) {
        if ($is_opt{$v}) {
            $commit->();
            $scope->{vars}{"${prefix}_$v"} = 'TRUE';
        } elsif ($is_one{$v}) {
            $commit->();
            $current_key = $v; $current_kind = 'one';
        } elsif ($is_multi{$v}) {
            $commit->();
            $current_key = $v; $current_kind = 'multi';
        } else {
            if (defined $current_key) {
                push @current_multi, $v;
            } else {
                push @unparsed, $v;
            }
        }
    }
    $commit->();
    $scope->{vars}{"${prefix}_UNPARSED_ARGUMENTS"} = join(';', @unparsed);
    $scope->{vars}{"${prefix}_KEYWORDS_MISSING_VALUES"} = join(';', @keywords_missing_values);
};
$builtins{'cmake_print_variables'} = sub { };
$builtins{'cmake_print_properties'} = sub { };
$builtins{'block'} = sub { };    # CMake 3.25+ scoping
$builtins{'endblock'} = sub { };

$builtins{'install'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    # Minimal install() for TriBITS use. Accumulates entries into
    # $state->{install_rules}; the generator emits an install script.
    #
    # Supported forms:
    #   install(TARGETS tgt... [EXPORT E] [DESTINATION d]
    #     [RUNTIME|LIBRARY|ARCHIVE|INCLUDES DESTINATION d] ...)
    #   install(FILES files... DESTINATION d)
    #   install(PROGRAMS files... DESTINATION d)
    #   install(DIRECTORY dirs... DESTINATION d)
    # Everything else is ignored silently.
    $state->{install_rules} //= [];
    return unless @$args;
    my $kind = shift @$args;

    if ($kind eq 'TARGETS') {
        my @targets;
        while (@$args && $args->[0] !~ /^(EXPORT|DESTINATION|RUNTIME|LIBRARY|ARCHIVE|INCLUDES|FRAMEWORK|BUNDLE|RESOURCE|OBJECTS|PUBLIC_HEADER|OPTIONAL|COMPONENT|NAMELINK_SKIP|NAMELINK_ONLY)$/) {
            push @targets, shift @$args;
        }
        # Default dest per target type
        my %dest_by_type = (RUNTIME=>'bin', LIBRARY=>'lib', ARCHIVE=>'lib',
                             INCLUDES=>'include', PUBLIC_HEADER=>'include');
        my $generic_dest;
        my $export_set;
        while (@$args) {
            my $kw = shift @$args;
            if ($kw eq 'DESTINATION') { $generic_dest = shift @$args; }
            elsif ($kw =~ /^(RUNTIME|LIBRARY|ARCHIVE|INCLUDES|FRAMEWORK|BUNDLE|RESOURCE|OBJECTS|PUBLIC_HEADER)$/) {
                # next is usually DESTINATION <dir>, or more props we skip
                if (@$args && $args->[0] eq 'DESTINATION') {
                    shift @$args;
                    $dest_by_type{$kw} = shift @$args;
                }
            } elsif ($kw eq 'EXPORT') {
                $export_set = shift @$args;
            } elsif ($kw eq 'COMPONENT') {
                shift @$args;
            }
        }
        for my $t (@targets) {
            push @{$state->{install_rules}}, {
                kind => 'target',
                target => $t,
                dest_runtime => $dest_by_type{RUNTIME} // $generic_dest // 'bin',
                dest_library => $dest_by_type{LIBRARY} // $generic_dest // 'lib',
                dest_archive => $dest_by_type{ARCHIVE} // $generic_dest // 'lib',
            };
            if ($export_set) {
                push @{$state->{export_sets}{$export_set} //= []}, $t;
            }
        }
        return;
    }

    if ($kind eq 'EXPORT') {
        # install(EXPORT <set> DESTINATION dir [FILE name] [NAMESPACE ns])
        my $name = shift @$args;
        my ($dest, $file, $namespace);
        while (@$args) {
            my $kw = shift @$args;
            if ($kw eq 'DESTINATION') { $dest = shift @$args; }
            elsif ($kw eq 'FILE')      { $file = shift @$args; }
            elsif ($kw eq 'NAMESPACE') { $namespace = shift @$args; }
            else { shift @$args; }
        }
        push @{$state->{install_rules}}, {
            kind => 'export', name => $name, dest => $dest // '.',
            file => $file // "${name}Targets.cmake",
            namespace => $namespace // '',
        };
        return;
    }

    if ($kind eq 'FILES' || $kind eq 'PROGRAMS') {
        my @files;
        my $dest;
        my $rename;
        while (@$args) {
            my $a = shift @$args;
            if ($a eq 'DESTINATION') { $dest = shift @$args; }
            elsif ($a eq 'RENAME')   { $rename = shift @$args; }
            elsif ($a =~ /^(COMPONENT|PERMISSIONS|OPTIONAL|CONFIGURATIONS)$/) {
                shift @$args;  # skip value (approximation)
            } else {
                push @files, $a;
            }
        }
        push @{$state->{install_rules}}, {
            kind => 'file', files => \@files, dest => $dest // '.',
            mode => ($kind eq 'PROGRAMS' ? '0755' : '0644'),
            rename => $rename,
            source_dir => $state->{current_source_dir},
            binary_dir => $state->{current_binary_dir},
        };
        return;
    }

    if ($kind eq 'DIRECTORY') {
        my @dirs;
        my $dest;
        my @patterns;
        while (@$args) {
            my $a = shift @$args;
            if ($a eq 'DESTINATION') { $dest = shift @$args; }
            elsif ($a eq 'FILES_MATCHING') { next; }
            elsif ($a eq 'PATTERN') {
                my $pat = shift @$args;
                # Optional EXCLUDE / PERMISSIONS after
                while (@$args && $args->[0] =~ /^(EXCLUDE|PERMISSIONS|OWNER_READ|OWNER_WRITE|OWNER_EXECUTE|GROUP_READ|GROUP_EXECUTE|WORLD_READ|WORLD_EXECUTE)$/) {
                    shift @$args;
                }
                push @patterns, $pat;
            } elsif ($a =~ /^(COMPONENT|PERMISSIONS|OPTIONAL|USE_SOURCE_PERMISSIONS|DIRECTORY_PERMISSIONS|FILE_PERMISSIONS)$/) {
                # skip next value if it looks like one
                shift @$args if @$args && $args->[0] !~ /^(DESTINATION|PATTERN)$/;
            } else {
                push @dirs, $a;
            }
        }
        push @{$state->{install_rules}}, {
            kind => 'directory', dirs => \@dirs, dest => $dest // '.',
            patterns => \@patterns,
            source_dir => $state->{current_source_dir},
            binary_dir => $state->{current_binary_dir},
        };
        return;
    }
    # CODE, SCRIPT, EXPORT: unsupported (silently)
};
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
        my $ran_module = 0;
        for my $dir (@mod_paths) {
            my $mod = "$dir/Find$name.cmake";
            if (-f $mod) {
                warn "SmakCMake: find_package($name) module → $mod\n"
                    if $ENV{SMAK_CMAKE_DEBUG};
                my $sub = parse_file($mod);
                eval_commands($sub, $state, $scope);
                $ran_module = 1;
                last;
            }
        }
        # If module didn't find it (or no module exists), try built-in
        my $found_var = "${name}_FOUND";
        my $found = _lookup($found_var, $scope);
        if (!$found || $found =~ /^(0|OFF|NO|FALSE)$/i) {
            if (_find_package_builtin($name, $state, $scope)) {
                return;
            }
        }
        return if $ran_module;
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
        FFTW => sub {
            if (-f '/usr/include/fftw3.h') {
                $scope->{vars}{FFTW_FOUND} = 'TRUE';
                $scope->{vars}{FFTW_INCLUDE_DIRS} = '/usr/include';
                # Probe Debian-style multiarch path then RH-style /usr/lib64.
                my $libpath;
                for my $cand ('/usr/lib/x86_64-linux-gnu/libfftw3.so',
                              '/usr/lib64/libfftw3.so',
                              '/usr/lib/libfftw3.so') {
                    if (-e $cand) { $libpath = $cand; last; }
                }
                if (defined $libpath) {
                    $scope->{vars}{FFTW_DOUBLE_LIB} = $libpath;
                    $scope->{vars}{FFTW_LIBRARIES}  = $libpath;
                }
            }
        },
        CURL => sub {
            if (-f '/usr/include/curl/curl.h') {
                $scope->{vars}{CURL_FOUND} = 'TRUE';
                $scope->{vars}{CURL_INCLUDE_DIRS} = '/usr/include';
                $scope->{vars}{CURL_LIBRARIES} = '-lcurl';
            }
        },
        Boost => sub {
            if (-d '/usr/include/boost') {
                $scope->{vars}{Boost_FOUND} = 'TRUE';
                $scope->{vars}{BOOST_FOUND} = 'TRUE';
                $scope->{vars}{Boost_INCLUDE_DIRS} = '/usr/include';
            }
        },
        Dakota => sub { $scope->{vars}{Dakota_FOUND} = 'FALSE'; },
        OpenMP => sub {
            $scope->{vars}{OpenMP_FOUND} = 'TRUE';
            $scope->{vars}{OpenMP_CXX_FLAGS} = '-fopenmp';
        },
        Git => sub {
            if (-x '/usr/bin/git') {
                $scope->{vars}{Git_FOUND} = 'TRUE';
                $scope->{vars}{GIT_FOUND} = 'TRUE';
                $scope->{vars}{GIT_EXECUTABLE} = '/usr/bin/git';
            }
        },
        Doxygen => sub { $scope->{vars}{Doxygen_FOUND} = 'FALSE'; },
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
    warn "SmakCMake: add_subdirectory($source_subdir)\n" if $ENV{SMAK_CMAKE_DEBUG};
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

    # Custom command rules — also run them now if outputs don't exist
    # or are older than inputs.  These generate source files (bison/flex)
    # that compile rules need at build time.
    _run_custom_commands($state);
    _write_custom_rules($state);

    # CMakeCache.txt (minimal - just what SmakCMake reads)
    _write_cmake_cache($state);

    # Top-level Makefile (for `make` compatibility — not strictly needed
    # for smak since SmakCMake reads CMakeFiles/ directly)
    _write_top_makefile($state);

    # Emit an install.sh script derived from the install() rules we
    # captured during interp. `smak install` runs it.
    _write_install_script($state);
}

sub _write_install_script {
    my ($state) = @_;
    my @rules = @{$state->{install_rules} // []};
    my $path  = $state->{build_dir} . "/install.sh";
    open(my $fh, '>', $path) or die "write $path: $!";
    my $configured_prefix = '/usr/local';
    if ($state->{root_scope}) {
        my $rs = $state->{root_scope};
        my $p = $rs->{vars}{CMAKE_INSTALL_PREFIX} // $rs->{cache}{CMAKE_INSTALL_PREFIX};
        $configured_prefix = $p if defined $p && $p ne '';
    }
    print $fh "#!/bin/bash\n";
    print $fh "# Generated by SmakCMakeInterp\n";
    print $fh ": \"\${CMAKE_INSTALL_PREFIX:=$configured_prefix}\"\n";
    print $fh <<'BANNER';
: "${DESTDIR:=}"
PREFIX="${DESTDIR}${CMAKE_INSTALL_PREFIX}"
_skipped=0
_ok=0
_mkdir() { mkdir -p "$1"; }
_cp_file() { # src dest_dir mode
    if [ ! -e "$1" ]; then _skipped=$((_skipped+1)); return 0; fi
    _mkdir "$2" || return 0
    if install -m "$3" "$1" "$2/" 2>/dev/null; then
        _ok=$((_ok+1))
    else
        _skipped=$((_skipped+1))
    fi
}
_cp_dir() { # src dest_dir [mode: dir|contents, default dir]
    _mode="${3:-dir}"
    if [ ! -d "$1" ]; then _skipped=$((_skipped+1)); return 0; fi
    _mkdir "$2" || return 0
    if [ "$_mode" = "contents" ]; then
        if cp -a "$1/." "$2/" 2>/dev/null; then _ok=$((_ok+1)); else _skipped=$((_skipped+1)); fi
    else
        if cp -a "$1" "$2/" 2>/dev/null; then _ok=$((_ok+1)); else _skipped=$((_skipped+1)); fi
    fi
}
_cp_file_rename() { # src dest_dir new_name mode
    if [ ! -e "$1" ]; then _skipped=$((_skipped+1)); return 0; fi
    _mkdir "$2" || return 0
    if install -m "$4" "$1" "$2/$3" 2>/dev/null; then
        _ok=$((_ok+1))
    else
        _skipped=$((_skipped+1))
    fi
}
BANNER

    for my $r (@rules) {
        if ($r->{kind} eq 'target') {
            my $t = $state->{targets}{$r->{target}};
            next unless $t;
            next if $t->{imported};
            my $tbin = $t->{binary_dir} // $state->{build_dir};
            if ($t->{type} eq 'library' && ($t->{libtype} // 'static') eq 'static') {
                my $src = "$tbin/lib$r->{target}.a";
                my $dest = "\$PREFIX/$r->{dest_archive}";
                print $fh qq(_cp_file "$src" "$dest" 0644\n);
            } elsif ($t->{type} eq 'library' && $t->{libtype} eq 'shared') {
                my $src = "$tbin/lib$r->{target}.so";
                my $dest = "\$PREFIX/$r->{dest_library}";
                print $fh qq(_cp_file "$src" "$dest" 0755\n);
            } elsif ($t->{type} eq 'executable') {
                my $src = "$tbin/$r->{target}";
                my $dest = "\$PREFIX/$r->{dest_runtime}";
                print $fh qq(_cp_file "$src" "$dest" 0755\n);
            }
        } elsif ($r->{kind} eq 'file') {
            my $dest = $r->{dest} =~ m{^/} ? $r->{dest} : "\$PREFIX/$r->{dest}";
            for my $f (@{$r->{files}}) {
                my $src = $f;
                unless ($src =~ m{^/}) {
                    # Try binary_dir first (generated), then source_dir
                    my $cand = "$r->{binary_dir}/$f";
                    if (-e $cand) { $src = $cand; }
                    else { $src = "$r->{source_dir}/$f"; }
                }
                if ($r->{rename}) {
                    print $fh qq(_cp_file_rename "$src" "$dest" "$r->{rename}" $r->{mode}\n);
                } else {
                    print $fh qq(_cp_file "$src" "$dest" $r->{mode}\n);
                }
            }
        } elsif ($r->{kind} eq 'export') {
            # Generate a Targets.cmake file with IMPORTED interface
            # libraries for each target in the export set. Honours each
            # target's EXPORT_NAME property (e.g., TriBITS sets
            # `pkg_all_libs` → exports as `pkg::all_libs`).
            my @targets = @{$state->{export_sets}{$r->{name}} // []};
            next unless @targets;
            my $dest = $r->{dest} =~ m{^/} ? $r->{dest} : "\$PREFIX/$r->{dest}";
            my $here = "$state->{build_dir}/_export_$r->{name}_$r->{file}";
            open(my $efh, '>', $here) or next;
            print $efh "# Generated by SmakCMakeInterp install(EXPORT)\n";
            for my $tname (@targets) {
                my $t = $state->{targets}{$tname};
                next unless $t;
                my $export_name = $t->{properties}{EXPORT_NAME} // $tname;
                my $exported = $r->{namespace} ? "$r->{namespace}$export_name" : $export_name;
                print $efh "if (NOT TARGET $exported)\n";
                print $efh "  add_library($exported INTERFACE IMPORTED)\n";
                # For an INTERFACE-typed target, INTERFACE_LINK_LIBRARIES
                # is what consumers transitively pick up. Translate the
                # original target's link_libraries / interface_link_libraries.
                my @ill = (@{$t->{interface_link_libraries} // []},
                           @{$t->{link_libraries} // []});
                my %seen;
                my @resolved;
                # Build a name→exported map for in-export-set targets so we
                # can rewrite local refs to their namespaced exported names.
                my %export_map;
                for my $tn (@targets) {
                    my $tt = $state->{targets}{$tn} or next;
                    my $en = $tt->{properties}{EXPORT_NAME} // $tn;
                    $export_map{$tn} = $r->{namespace} ? "$r->{namespace}$en" : $en;
                }
                for my $dep (@ill) {
                    next unless defined $dep && $dep ne '';
                    next if $dep =~ /^(PUBLIC|PRIVATE|INTERFACE)$/;
                    next if $seen{$dep}++;
                    my $rep = $export_map{$dep} // $dep;
                    push @resolved, $rep;
                }
                if ($t->{type} eq 'library' && ($t->{libtype} // 'static') ne 'interface') {
                    my $lib_dest = ($t->{libtype} // 'static') eq 'static'
                        ? "lib/lib$tname.a" : "lib/lib$tname.so";
                    unshift @resolved, "\${CMAKE_CURRENT_LIST_DIR}/../../../$lib_dest";
                }
                # Heuristic for TriBITS: a target with EXPORT_NAME=all_libs
                # exports as `${pkg}::all_libs` and is meant to aggregate all
                # OTHER non-`*_all_libs` targets in the same export set.
                # If no link libraries were captured, link it to those.
                if ($export_name eq 'all_libs' && !@resolved) {
                    for my $tn (@targets) {
                        next if $tn eq $tname;
                        next if $tn =~ /_all_libs$/;
                        my $en = $state->{targets}{$tn}{properties}{EXPORT_NAME} // $tn;
                        my $en_full = $r->{namespace} ? "$r->{namespace}$en" : $en;
                        push @resolved, $en_full;
                    }
                }
                if (@resolved) {
                    print $efh "  set_property(TARGET $exported APPEND PROPERTY INTERFACE_LINK_LIBRARIES @resolved)\n";
                }
                # INCLUDE_DIRECTORIES — point at installed include dir
                print $efh "  set_property(TARGET $exported APPEND PROPERTY INTERFACE_INCLUDE_DIRECTORIES \"\${CMAKE_CURRENT_LIST_DIR}/../../../include\")\n";
                print $efh "endif()\n";
            }
            close($efh);
            print $fh qq(_cp_file_rename "$here" "$dest" "$r->{file}" 0644\n);
        } elsif ($r->{kind} eq 'directory') {
            my $dest = $r->{dest} =~ m{^/} ? $r->{dest} : "\$PREFIX/$r->{dest}";
            for my $d (@{$r->{dirs}}) {
                my $src = $d;
                my $trailing = ($src =~ m{/$}) ? 1 : 0;
                unless ($src =~ m{^/}) {
                    $src = "$r->{source_dir}/$d";
                    $trailing = 1 if $d =~ m{/$};
                }
                $src =~ s{/$}{};
                my $mode = $trailing ? 'contents' : 'dir';
                print $fh qq(_cp_dir "$src" "$dest" $mode\n);
            }
        }
    }
    # Post-install: append IMPORTED target shims for system TPLs that
    # TriBITS would normally emit. This makes the installed config
    # compatible with consumers (e.g. Xyce) that look for BLAS::all_libs,
    # LAPACK::all_libs, AMD::all_libs.
    print $fh <<'TPLPATCH';

# Define IMPORTED targets for common system TPLs so consumers' `if (TARGET
# X::all_libs)` checks succeed. Skipped silently if the cmake dir wasn't
# created (no Trilinos install).
_trilinos_dir="$PREFIX/lib/cmake/Trilinos"
if [ -f "$_trilinos_dir/TrilinosConfig.cmake" ]; then
    if ! grep -q "TPL_SHIMS_BEGIN" "$_trilinos_dir/TrilinosConfig.cmake"; then
        cat >> "$_trilinos_dir/TrilinosConfig.cmake" <<'TPL_SHIMS_BEGIN'

# === TPL_SHIMS_BEGIN === appended by smak install ===
# IMPORTED targets for common system TPLs so consumers' `if (TARGET
# X::all_libs)` checks succeed. Probes Debian-multiarch and RH-style
# /usr/lib64 paths; falls back to -l<name> if neither matches so the
# linker's default search picks it up.
foreach(_tpl_pair "BLAS:blas" "LAPACK:lapack" "AMD:amd")
    string(REPLACE ":" ";" _tpl_pair "${_tpl_pair}")
    list(GET _tpl_pair 0 _tpl)
    list(GET _tpl_pair 1 _libname)
    if(NOT TARGET ${_tpl}::all_libs)
        set(_libpath "")
        foreach(_d "/usr/lib/x86_64-linux-gnu" "/usr/lib64" "/usr/lib" "/usr/local/lib64" "/usr/local/lib")
            if(EXISTS "${_d}/lib${_libname}.so")
                set(_libpath "${_d}/lib${_libname}.so")
                break()
            elseif(EXISTS "${_d}/lib${_libname}.a")
                set(_libpath "${_d}/lib${_libname}.a")
                break()
            endif()
        endforeach()
        if(_libpath STREQUAL "")
            set(_libpath "-l${_libname}")
        endif()
        add_library(${_tpl}::all_libs INTERFACE IMPORTED)
        set_target_properties(${_tpl}::all_libs PROPERTIES
            INTERFACE_LINK_LIBRARIES "${_libpath}")
    endif()
endforeach()

# Append the TPL shims to Trilinos::all_libs and Trilinos::all_selected_libs
# so consumers that just link Trilinos::all_selected_libs (e.g., Xyce) pick
# up BLAS/LAPACK/AMD transitively without having to mention them.
foreach(_aggregate Trilinos::all_libs Trilinos::all_selected_libs)
    if(TARGET ${_aggregate})
        set_property(TARGET ${_aggregate} APPEND PROPERTY
            INTERFACE_LINK_LIBRARIES BLAS::all_libs LAPACK::all_libs AMD::all_libs)
    endif()
endforeach()
# === TPL_SHIMS_END ===
TPL_SHIMS_BEGIN
    fi
fi

TPLPATCH
    print $fh qq(echo "install: \$_ok files installed, \$_skipped missing"\n);
    close($fh);
    chmod 0755, $path;
}

# Write rules for add_custom_command outputs into a single rules.make.
# SmakCMake doesn't read this yet — but make can use it, and we can
# later hook it into SmakCMake's rule tables directly.
# Run any add_custom_command whose outputs are missing or out of date.
# We run them at "configure" time (from generate_makefiles) because the
# outputs are source files that subsequent compile rules need.
sub _run_custom_commands {
    my ($state) = @_;
    my @cmds = @{$state->{custom_commands} // []};
    return unless @cmds;

    use File::Path qw(make_path);
    for my $c (@cmds) {
        my @outs = @{$c->{output} // []};
        next unless @outs;
        # Check if all outputs exist and are newer than all deps
        my $needs_run = 0;
        my $newest_dep = 0;
        for my $d (@{$c->{depends} // []}) {
            next unless -e $d;
            my $m = (stat($d))[9] // 0;
            $newest_dep = $m if $m > $newest_dep;
        }
        for my $o (@outs) {
            unless (-e $o) { $needs_run = 1; last; }
            my $m = (stat($o))[9] // 0;
            if ($m < $newest_dep) { $needs_run = 1; last; }
        }
        next unless $needs_run;

        # Ensure output directories exist
        for my $o (@outs) {
            my $d = $o;
            $d =~ s{/[^/]*$}{};
            make_path($d) if $d && $d ne $o;
        }

        my $dir = $c->{working_dir} // $c->{binary_dir} // $state->{build_dir};
        make_path($dir);
        for my $cmd (@{$c->{commands} // []}) {
            my $pid = fork();
            if (!defined $pid) { warn "fork: $!\n"; next; }
            if ($pid == 0) {
                chdir($dir) or do { warn "chdir $dir: $!\n"; POSIX::_exit(1); };
                exec("/bin/sh", "-c", $cmd) or do { warn "exec: $!\n"; POSIX::_exit(127); };
            }
            waitpid($pid, 0);
            my $rc = $? >> 8;
            if ($rc != 0) {
                warn "SmakCMake: custom command failed (exit $rc): $cmd\n";
            }
        }
    }
}

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
    print $fh "CMAKE_COMMAND:INTERNAL=" . _cmake_install_root() . "/bin/cmake\n";
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
        my $src_path = _resolve_source_path($src, $t);
        my $obj_rel = $src;
        $obj_rel =~ s{^.*/}{};  # basename
        my $obj = "CMakeFiles/" . _target_name_from_dir($t) . ".dir/$obj_rel.o";
        push @out, { src => $src_path, obj => $obj };
    }
    return @out;
}

# Resolve a relative source path against the target's binary_dir first
# (for configure_file-generated sources), then source_dir.
sub _resolve_source_path {
    my ($src, $t) = @_;
    return $src if $src =~ m{^/};
    if ($t->{binary_dir}) {
        my $b = File::Spec->catfile($t->{binary_dir}, $src);
        return $b if -e $b;
    }
    return File::Spec->catfile($t->{source_dir}, $src);
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
        print $fh "${lang}_INCLUDES = ", _include_flags($t, $state), "\n";
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
        my $src_path = _resolve_source_path($src, $t);
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
        # Namespaced "Foo::all_libs" or "Foo::Bar" with no matching target —
        # strip namespace and pass the package as -lFoo. Common for find_package
        # imports that didn't resolve to a known IMPORTED target.
        if ($lib =~ /^([^:]+)::/) {
            push @out, "-l$1";
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
    my ($t, $state) = @_;
    my @inc = @{$t->{include_directories} // []};
    # Also merge any TPL_*_INCLUDE_DIRS set in the root scope. Strictly a
    # TriBITS workaround: the proper path is imported-target INTERFACE
    # propagation, which we don't fully model. Adding these globally is
    # harmless for compile lines and avoids manual target wiring.
    if ($state && $state->{root_scope}) {
        my $rs = $state->{root_scope};
        for my $name (keys %{$rs->{vars}}) {
            next unless $name =~ /^TPL_.+_INCLUDE_DIRS$/;
            my $v = $rs->{vars}{$name};
            next unless defined $v && $v ne '';
            next if $v =~ /-NOTFOUND$/;
            for my $d (split /;/, $v) {
                push @inc, $d if $d ne '' && $d !~ /-NOTFOUND$/;
            }
        }
    }
    my %seen;
    @inc = grep { $_ ne '' && !$seen{$_}++ } @inc;
    return join(' ', map { "-I$_" } @inc);
}

# ─── Entry point ────────────────────────────────────────────────────

# Parse + evaluate a project rooted at $source_dir, targeting $build_dir.
# Returns the state hash (targets, variables, etc.).
sub interpret_project {
    my ($source_dir, $build_dir, $cli_defines, $cache_files) = @_;
    $cli_defines //= {};
    $cache_files //= [];
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
    # Use the bare name so $PATH lookup hits smak's `cmake` wrapper at run
    # time. add_custom_command rules that invoke `${CMAKE_COMMAND} -P ...`
    # then route through smak-cmake.pl, which handles -P via the script-eval
    # interp (no bundled cmake binary required).
    $root_scope->{vars}{CMAKE_COMMAND} = 'cmake';

    # Initial cache files from cmake -C
    for my $cache (@$cache_files) {
        next unless -f $cache;
        my $cmds = parse_file($cache);
        eval_commands($cmds, $state, $root_scope);
    }
    # CLI -D overrides (seed as top-scope vars + cache)
    for my $k (sort keys %$cli_defines) {
        $root_scope->{vars}{$k}  = $cli_defines->{$k};
        $root_scope->{cache}{$k} = $cli_defines->{$k};
    }

    my $commands = parse_file("$source_dir/CMakeLists.txt");
    eval_commands($commands, $state, $root_scope);

    # Stash the final scope so the generator can consult vars/cache.
    $state->{root_scope} = $root_scope;
    return $state;
}

# Lightweight cmake -P emulation: evaluate a single .cmake script.
# No project / no build artifacts — just run the commands with the given
# -D variables in scope.
sub run_script {
    my ($script_file, $cli_defines) = @_;
    $cli_defines //= {};
    $script_file = File::Spec->rel2abs($script_file);
    my $script_dir = $script_file;
    $script_dir =~ s{/[^/]*$}{};
    my $state = {
        source_dir => $script_dir,
        build_dir  => '.',
        current_source_dir => $script_dir,
        current_binary_dir => '.',
        targets    => {},
        unknown_commands => [],
    };
    my $root_scope = new_scope(undef);
    $root_scope->{_state} = $state;
    $root_scope->{vars}{CMAKE_CURRENT_LIST_DIR}  = $script_dir;
    $root_scope->{vars}{CMAKE_CURRENT_LIST_FILE} = $script_file;
    $root_scope->{vars}{CMAKE_VERSION} = '3.31.4';
    for my $k (sort keys %$cli_defines) {
        $root_scope->{vars}{$k} = $cli_defines->{$k};
    }
    my $cmds = parse_file($script_file);
    eval_commands($cmds, $state, $root_scope);
    $state->{root_scope} = $root_scope;
    return $state;
}

1;
