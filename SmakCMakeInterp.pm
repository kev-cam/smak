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
        # End of argument
        last if $c =~ /[\s\"]/;
        last if $c eq '(' && $paren_depth == 0;
        last if $c eq ')' && $paren_depth == 0;
        last if $c eq '#' && $text eq '';
        # Track nested parens inside unquoted args (rare but valid in some command args)
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
    # Unquoted — split on unescaped ;
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
    for my $cmd (@$commands) {
        eval_command($cmd, $state, $scope);
    }
}

sub eval_command {
    my ($cmd, $state, $scope) = @_;
    my @expanded = expand_args($cmd->{args}, $scope);
    my $handler = $builtins{$cmd->{name}};
    if ($handler) {
        $handler->($state, \@expanded, $cmd, $scope);
    } else {
        # Unknown command — record it but don't fail (yet)
        push @{$state->{unknown_commands}}, $cmd->{name};
        warn "SmakCMake: unknown command '$cmd->{name}' at $cmd->{source}:$cmd->{line}\n"
            if $ENV{SMAK_CMAKE_DEBUG};
    }
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
    # Strip IMPORTED/ALIAS keywords
    my @sources = grep { !/^(IMPORTED|ALIAS|GLOBAL|EXCLUDE_FROM_ALL|WIN32|MACOSX_BUNDLE)$/ } @$args;
    $state->{targets}{$name} = {
        type => 'executable',
        sources => \@sources,
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
    };
};

$builtins{'add_library'} = sub {
    my ($state, $args, $cmd, $scope) = @_;
    my $name = shift @$args;
    my $libtype = 'static';  # default
    if (@$args && $args->[0] =~ /^(STATIC|SHARED|MODULE|INTERFACE|OBJECT)$/) {
        $libtype = lc(shift @$args);
    }
    my @sources = grep { !/^(IMPORTED|ALIAS|GLOBAL|EXCLUDE_FROM_ALL)$/ } @$args;
    $state->{targets}{$name} = {
        type => 'library',
        libtype => $libtype,
        sources => \@sources,
        source_dir => $state->{current_source_dir},
        binary_dir => $state->{current_binary_dir},
    };
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

    my $commands = parse_file("$source_dir/CMakeLists.txt");
    eval_commands($commands, $state, $root_scope);

    return $state;
}

1;
