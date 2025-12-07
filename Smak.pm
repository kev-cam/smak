package Smak;

use strict;
use warnings;
use Exporter qw(import);
use POSIX ":sys_wait_h";
use Term::ReadLine;

our $VERSION = '1.0';

our @EXPORT_OK = qw(
    parse_makefile
    build_target
    dry_run_target
    interactive_debug
    execute_script
    get_default_target
    get_rules
    set_report_mode
    set_dry_run_mode
    set_silent_mode
    tee_print
    expand_vars
    add_rule
    modify_rule
    modify_deps
    delete_rule
    save_modifications
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

# Separate hashes for different rule types
our %fixed_rule;
our %fixed_deps;
our %pattern_rule;
our %pattern_deps;
our %pseudo_rule;
our %pseudo_deps;

# Hash for Makefile variables
our %MV;

# Command-line variable overrides (VAR=VALUE from command line)
our %cmd_vars;

# Track phony targets (from ninja builds)
our %phony_targets;

# Track modifications for saving
our @modifications;

# Control variables
our $timeout = 5;  # Timeout for print command evaluation in seconds
our $prompt = "smak> ";  # Prompt string for interactive mode
our $echo = 0;  # Echo command lines (including prompt)

# Internal state
our $makefile;
our $default_target;
our $report_mode = 0;
our $log_fh;
our $dry_run_mode = 0;
our $silent_mode = 0;

sub set_report_mode {
    my ($enabled, $fh) = @_;
    $report_mode = $enabled;
    $log_fh = $fh if $fh;
}

sub set_dry_run_mode {
    my ($enabled) = @_;
    $dry_run_mode = $enabled;
}

sub set_silent_mode {
    my ($enabled) = @_;
    $silent_mode = $enabled;
}

sub set_cmd_var {
    my ($var, $value) = @_;
    $cmd_vars{$var} = $value;
}

sub get_cmd_vars {
    return \%cmd_vars;
}

sub tee_print {
    my ($msg) = @_;
    print STDOUT $msg;
    print $log_fh $msg if $report_mode && $log_fh;
}

sub classify_target {
    my ($target) = @_;
    if ($target =~ /^\./) {
        return 'pseudo';
    } elsif ($target =~ /%/) {
        return 'pattern';
    } else {
        return 'fixed';
    }
}

sub expand_vars {
    my ($text, $depth) = @_;
    $depth ||= 0;
    return $text if $depth > 10;  # Prevent infinite recursion

    # Expand $(function args) and $(VAR) references
    while ($text =~ /\$\(([^)]+)\)/) {
        my $content = $1;
        my $replacement;

        # Check if it's a function call (contains space or comma)
        if ($content =~ /^(\w+)\s+(.+)$/ || $content =~ /^(\w+),(.+)$/) {
            my $func = $1;
            my $args_str = $2;

            # Split arguments by comma, but not within nested $()
            my @args;
            my $depth = 0;
            my $current = '';
            for my $char (split //, $args_str) {
                if ($char eq '(' && substr($current, -1) eq '$') {
                    $depth++;
                    $current .= $char;
                } elsif ($char eq ')') {
                    $depth--;
                    $current .= $char;
                } elsif ($char eq ',' && $depth == 0) {
                    push @args, $current;
                    $current = '';
                } else {
                    $current .= $char;
                }
            }
            push @args, $current if $current ne '';

            # Trim whitespace from arguments
            @args = map { s/^\s+|\s+$//gr } @args;

            # Recursively expand variables in arguments
            @args = map { expand_vars($_, $depth + 1) } @args;

            # Process gmake functions
            if ($func eq 'patsubst') {
                # $(patsubst pattern,replacement,text)
                if (@args >= 3) {
                    my ($pattern, $repl, $text) = @args;
                    # Convert gmake pattern to regex
                    my $regex = $pattern;
                    $regex =~ s/%/(.+)/g;
                    $regex = "^$regex\$";
                    # Convert replacement pattern
                    $repl =~ s/%/\$1/g;
                    my @words = split /\s+/, $text;
                    @words = map { s/$regex/$repl/r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'subst') {
                # $(subst from,to,text)
                if (@args >= 3) {
                    my ($from, $to, $text) = @args;
                    $replacement = $text;
                    $replacement =~ s/\Q$from\E/$to/g;
                }
            } elsif ($func eq 'strip') {
                # $(strip string)
                if (@args >= 1) {
                    $replacement = $args[0];
                    $replacement =~ s/^\s+|\s+$//g;
                    $replacement =~ s/\s+/ /g;
                }
            } elsif ($func eq 'findstring') {
                # $(findstring find,in)
                if (@args >= 2) {
                    my ($find, $in) = @args;
                    $replacement = index($in, $find) >= 0 ? $find : '';
                }
            } elsif ($func eq 'filter') {
                # $(filter pattern...,text)
                if (@args >= 2) {
                    my $patterns = $args[0];
                    my $text = $args[1];
                    my @patterns = split /\s+/, $patterns;
                    my @words = split /\s+/, $text;
                    my @result;
                    for my $word (@words) {
                        for my $pat (@patterns) {
                            my $regex = $pat;
                            $regex =~ s/%/.*?/g;
                            if ($word =~ /^$regex$/) {
                                push @result, $word;
                                last;
                            }
                        }
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'filter-out') {
                # $(filter-out pattern...,text)
                if (@args >= 2) {
                    my $patterns = $args[0];
                    my $text = $args[1];
                    my @patterns = split /\s+/, $patterns;
                    my @words = split /\s+/, $text;
                    my @result;
                    for my $word (@words) {
                        my $matched = 0;
                        for my $pat (@patterns) {
                            my $regex = $pat;
                            $regex =~ s/%/.*?/g;
                            if ($word =~ /^$regex$/) {
                                $matched = 1;
                                last;
                            }
                        }
                        push @result, $word unless $matched;
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'sort') {
                # $(sort list)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    my %seen;
                    @words = grep { !$seen{$_}++ } sort @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'word') {
                # $(word n,text)
                if (@args >= 2) {
                    my ($n, $text) = @args;
                    my @words = split /\s+/, $text;
                    $replacement = $words[$n - 1] || '';
                }
            } elsif ($func eq 'wordlist') {
                # $(wordlist s,e,text)
                if (@args >= 3) {
                    my ($s, $e, $text) = @args;
                    my @words = split /\s+/, $text;
                    my @result = @words[($s-1)..($e-1)];
                    $replacement = join(' ', grep defined, @result);
                }
            } elsif ($func eq 'words') {
                # $(words text)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = scalar(@words);
                }
            } elsif ($func eq 'firstword') {
                # $(firstword names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = $words[0] || '';
                }
            } elsif ($func eq 'lastword') {
                # $(lastword names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    $replacement = $words[-1] || '';
                }
            } elsif ($func eq 'dir') {
                # $(dir names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { m{(.*/)} ? $1 : './' } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'notdir') {
                # $(notdir names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { s{.*/}{}r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'suffix') {
                # $(suffix names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { /(\.[^.\/]*)$/ ? $1 : '' } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'basename') {
                # $(basename names...)
                if (@args >= 1) {
                    my @words = split /\s+/, $args[0];
                    @words = map { s/\.[^.\/]*$//r } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'addsuffix') {
                # $(addsuffix suffix,names...)
                if (@args >= 2) {
                    my ($suffix, $names) = @args;
                    my @words = split /\s+/, $names;
                    @words = map { $_ . $suffix } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'addprefix') {
                # $(addprefix prefix,names...)
                if (@args >= 2) {
                    my ($prefix, $names) = @args;
                    my @words = split /\s+/, $names;
                    @words = map { $prefix . $_ } @words;
                    $replacement = join(' ', @words);
                }
            } elsif ($func eq 'join') {
                # $(join list1,list2)
                if (@args >= 2) {
                    my @list1 = split /\s+/, $args[0];
                    my @list2 = split /\s+/, $args[1];
                    my @result;
                    for (my $i = 0; $i < @list1 || $i < @list2; $i++) {
                        push @result, ($list1[$i] // '') . ($list2[$i] // '');
                    }
                    $replacement = join(' ', @result);
                }
            } elsif ($func eq 'wildcard') {
                # $(wildcard pattern...)
                if (@args >= 1) {
                    my @patterns = split /\s+/, $args[0];
                    my @files;
                    for my $pattern (@patterns) {
                        push @files, glob($pattern);
                    }
                    $replacement = join(' ', @files);
                }
            } elsif ($func eq 'shell') {
                # $(shell command)
                if (@args >= 1) {
                    my $cmd = $args[0];
                    $replacement = `$cmd`;
                    chomp $replacement;
                }
            } else {
                # Unknown function, leave as-is
                $replacement = "\$($content)";
            }
        } else {
            # Simple variable reference
            # Check command-line variables first, then Makefile variables
            $replacement = $cmd_vars{$content} // $MV{$content} // '';
            # Convert any $MV{...} in the value to $(...) so they can be expanded
            $replacement = format_output($replacement);
        }

        # Replace in text
        $replacement //= '';
        $text =~ s/\Q$(\E\Q$content\E\Q)/$replacement/;
    }

    return $text;
}

sub format_output {
    my ($text) = @_;
    # Convert $MV{VAR} back to $(VAR) for display/expansion
    $text =~ s/\$MV\{([^}]+)\}/\$($1)/g;
    return $text;
}

sub transform_make_vars {
    my ($text) = @_;
    # Transform $(VAR) to $MV{VAR}
    $text =~ s/\$\(([^)]+)\)/\$MV{$1}/g;
    # Transform $X (single-letter variables) to $MV{X}, but not automatic vars like $@, $<, $^, $*, $?
    # Automatic variables are handled separately in expand_vars
    $text =~ s/\$([A-Za-z0-9_])(?![A-Za-z0-9_{])/\$MV{$1}/g;
    return $text;
}

sub parse_makefile {
    my ($makefile_path) = @_;

    $makefile = $makefile_path;
    undef $default_target;

    # Reset state
    %fixed_rule = ();
    %fixed_deps = ();
    %pattern_rule = ();
    %pattern_deps = ();
    %pseudo_rule = ();
    %pseudo_deps = ();
    %MV = ();
    @modifications = ();

    # Set default built-in make variables
    # Use the actual invocation command for recursive makes
    # Check environment variable set by wrapper script, otherwise use $0
    $MV{MAKE} = $ENV{SMAK_INVOKED_AS} || $0;
    $MV{SHELL} = '/bin/sh';
    $MV{RM} = 'rm -f';
    $MV{AR} = 'ar';
    $MV{CC} = 'cc';
    $MV{CXX} = 'c++';

    # Set directory variables (PWD and CURDIR should be the same)
    use Cwd 'getcwd';
    $MV{PWD} = getcwd();
    $MV{CURDIR} = getcwd();

    open(my $fh, '<', $makefile) or die "Cannot open $makefile: $!";

    my $current_target;
    my $current_rule = '';
    my $current_type;  # 'fixed', 'pattern', or 'pseudo'

    my $save_current_rule = sub {
        return unless $current_target;

        my $key = "$makefile\t$current_target";
        if ($current_type eq 'fixed') {
            $fixed_rule{$key} = $current_rule;
        } elsif ($current_type eq 'pattern') {
            $pattern_rule{$key} = $current_rule;
        } elsif ($current_type eq 'pseudo') {
            $pseudo_rule{$key} = $current_rule;
        }

        $current_target = undef;
        $current_rule = '';
        $current_type = undef;
    };

    while (my $line = <$fh>) {
        chomp $line;

        # Handle line continuations
        while ($line =~ /\\$/) {
            $line =~ s/\\$//;
            my $next = <$fh>;
            last unless defined $next;
            chomp $next;
            $line .= $next;
        }

        # Skip comments and empty lines (but not inside rules)
        if (!defined $current_target && ($line =~ /^\s*#/ || $line =~ /^\s*$/)) {
            next;
        }

        # Handle include directives
        if ($line =~ /^-?include\s+(.+)$/) {
            $save_current_rule->();
            my $include_files = $1;
            # Expand variables in the include filename
            $include_files = transform_make_vars($include_files);

            # Handle multiple includes on one line
            for my $include_file (split /\s+/, $include_files) {
                # Expand $MV{...} to actual values
                while ($include_file =~ /\$MV\{([^}]+)\}/) {
                    my $var = $1;
                    my $val = $MV{$var} // '';
                    $include_file =~ s/\$MV\{\Q$var\E\}/$val/;
                }

                # Make path absolute relative to current Makefile's directory
                my $include_path = $include_file;
                unless ($include_path =~ m{^/}) {
                    use File::Basename;
                    use File::Spec;
                    my $makefile_dir = dirname($makefile);
                    $include_path = File::Spec->catfile($makefile_dir, $include_file);
                }

                # Parse the included file (ignore if it doesn't exist and line starts with -)
                if (-f $include_path) {
                    # Save current makefile name
                    my $saved_makefile = $makefile;

                    # Parse included file in-place (variables go into same %MV)
                    parse_included_makefile($include_path);

                    # Restore current makefile name
                    $makefile = $saved_makefile;
                } elsif ($line !~ /^-include/) {
                    warn "Warning: included file not found: $include_path\n";
                }
            }
            next;
        }

        # Variable assignment
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $value) = ($1, $2);
            # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
            $value = transform_make_vars($value);
            $MV{$var} = $value;
            next;
        }

        # Rule definition (target: dependencies)
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            $save_current_rule->();

            my $target = $1;
            my $deps_str = $2;

            # Trim whitespace
            $target =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;

            # Transform $(VAR) and $X to $MV{VAR} and $MV{X} in dependencies
            $deps_str = transform_make_vars($deps_str);

            my @deps = split /\s+/, $deps_str;
            @deps = grep { $_ ne '' } @deps;

            $current_target = $target;
            $current_type = classify_target($target);
            $current_rule = '';

            my $key = "$makefile\t$target";
            if ($current_type eq 'fixed') {
                # Append dependencies if target already exists (like gmake)
                if (exists $fixed_deps{$key}) {
                    push @{$fixed_deps{$key}}, @deps;
                } else {
                    $fixed_deps{$key} = \@deps;
                }
            } elsif ($current_type eq 'pattern') {
                # Append dependencies if target already exists (like gmake)
                if (exists $pattern_deps{$key}) {
                    push @{$pattern_deps{$key}}, @deps;
                } else {
                    $pattern_deps{$key} = \@deps;
                }
            } elsif ($current_type eq 'pseudo') {
                # Append dependencies if target already exists (like gmake)
                if (exists $pseudo_deps{$key}) {
                    push @{$pseudo_deps{$key}}, @deps;
                } else {
                    $pseudo_deps{$key} = \@deps;
                }
            }

            # Set default target to first non-pseudo target (like gmake)
            if (!defined $default_target && $current_type ne 'pseudo') {
                $default_target = $target;
            }

            next;
        }

        # Rule command (starts with tab)
        if ($line =~ /^\t(.*)$/ && defined $current_target) {
            my $cmd = $1;
            # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
            $cmd = transform_make_vars($cmd);
            $current_rule .= "$cmd\n";
            next;
        }

        # If we get here with a current target, save it
        $save_current_rule->() if defined $current_target;
    }

    # Save the last rule if any
    $save_current_rule->();

    close($fh);
}

sub parse_included_makefile {
    my ($include_path) = @_;

    # Parse an included Makefile without resetting global state
    # Variables and rules are added to the existing %MV, %fixed_deps, etc.

    open(my $fh, '<', $include_path) or do {
        warn "Warning: Cannot open included file $include_path: $!\n";
        return;
    };

    # Temporarily update $makefile for proper key generation
    my $saved_makefile = $makefile;
    $makefile = $include_path;

    my $current_target;
    my $current_rule = '';
    my $current_type;

    my $save_current_rule = sub {
        return unless $current_target;

        my $key = "$saved_makefile\t$current_target";  # Use original makefile for keys
        if ($current_type eq 'fixed') {
            $fixed_rule{$key} = $current_rule;
        } elsif ($current_type eq 'pattern') {
            $pattern_rule{$key} = $current_rule;
        } elsif ($current_type eq 'pseudo') {
            $pseudo_rule{$key} = $current_rule;
        }

        $current_target = undef;
        $current_rule = '';
        $current_type = undef;
    };

    while (my $line = <$fh>) {
        chomp $line;

        # Handle line continuations
        while ($line =~ /\\$/) {
            $line =~ s/\\$//;
            my $next = <$fh>;
            last unless defined $next;
            chomp $next;
            $line .= $next;
        }

        # Skip comments and empty lines
        if (!defined $current_target && ($line =~ /^\s*#/ || $line =~ /^\s*$/)) {
            next;
        }

        # Variable assignment (most important for included files like flags.make)
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*)$/) {
            $save_current_rule->();
            my ($var, $value) = ($1, $2);
            $value = transform_make_vars($value);
            $MV{$var} = $value;
            next;
        }

        # Rule definition (included files might have rules too)
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            $save_current_rule->();

            my $target = $1;
            my $deps_str = $2;

            $target =~ s/^\s+|\s+$//g;
            $deps_str =~ s/^\s+|\s+$//g;
            $deps_str = transform_make_vars($deps_str);

            my @deps = split /\s+/, $deps_str;
            @deps = grep { $_ ne '' } @deps;

            $current_target = $target;
            $current_type = classify_target($target);
            $current_rule = '';

            my $key = "$saved_makefile\t$target";
            if ($current_type eq 'fixed') {
                if (exists $fixed_deps{$key}) {
                    push @{$fixed_deps{$key}}, @deps;
                } else {
                    $fixed_deps{$key} = \@deps;
                }
            } elsif ($current_type eq 'pattern') {
                if (exists $pattern_deps{$key}) {
                    push @{$pattern_deps{$key}}, @deps;
                } else {
                    $pattern_deps{$key} = \@deps;
                }
            } elsif ($current_type eq 'pseudo') {
                if (exists $pseudo_deps{$key}) {
                    push @{$pseudo_deps{$key}}, @deps;
                } else {
                    $pseudo_deps{$key} = \@deps;
                }
            }

            next;
        }

        # Rule command
        if ($line =~ /^\t(.*)$/ && defined $current_target) {
            my $cmd = $1;
            $cmd = transform_make_vars($cmd);
            $current_rule .= "$cmd\n";
            next;
        }

        # If we get here with a current target, save it
        $save_current_rule->() if defined $current_target;
    }

    # Save the last rule if any
    $save_current_rule->();

    close($fh);
    $makefile = $saved_makefile;
}

sub get_default_target {
    return $default_target;
}

sub get_rules {
    return {
        fixed_rule => \%fixed_rule,
        fixed_deps => \%fixed_deps,
        pattern_rule => \%pattern_rule,
        pattern_deps => \%pattern_deps,
        pseudo_rule => \%pseudo_rule,
        pseudo_deps => \%pseudo_deps,
        variables => \%MV,
    };
}

sub parse_ninja {
    my ($ninja_file) = @_;

    $makefile = $ninja_file;
    undef $default_target;

    # Reset state
    %fixed_rule = ();
    %fixed_deps = ();
    %pattern_rule = ();
    %pattern_deps = ();
    %pseudo_rule = ();
    %pseudo_deps = ();
    %MV = ();
    %phony_targets = ();

    # Ninja-specific: track rules and their properties
    my %ninja_rules;  # rule_name => {command, description, deps, depfile, ...}
    my %ninja_vars;   # global ninja variables

    open(my $fh, '<', $ninja_file) or die "Cannot open $ninja_file: $!";

    my $current_section = '';  # 'rule', 'build', or ''
    my $current_rule_name = '';
    my $current_build_output = '';
    my %current_build_vars;

    while (my $line = <$fh>) {
        chomp $line;

        # Skip comments and empty lines
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

        # Global variable assignment
        if ($line =~ /^(\w+)\s*=\s*(.*)$/ && $current_section eq '') {
            my ($var, $value) = ($1, $2);
            $ninja_vars{$var} = $value;
            $MV{$var} = $value;
            next;
        }

        # Rule definition
        if ($line =~ /^rule\s+(\S+)/) {
            $current_section = 'rule';
            $current_rule_name = $1;
            $ninja_rules{$current_rule_name} = {};
            next;
        }

        # Rule properties (indented lines after 'rule')
        if ($current_section eq 'rule' && $line =~ /^\s+(\w+)\s*=\s*(.*)$/) {
            my ($prop, $value) = ($1, $2);
            $ninja_rules{$current_rule_name}{$prop} = $value;
            next;
        }

        # Build statement
        if ($line =~ /^build\s+(.+?)\s*:\s*(\S+)(?:\s+(.*))?$/) {
            # End previous build if any
            if ($current_build_output) {
                _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
            }

            $current_section = 'build';
            $current_build_output = $1;
            my $rule_name = $2;
            my $inputs = $3 || '';

            # Parse outputs (can be multiple with |)
            my @outputs = split /\s*\|\s*/, $current_build_output;
            my $output = $outputs[0];  # Use first output as main target

            # Parse inputs (can have implicit deps with |)
            my @input_parts = split /\s*\|\s*/, $inputs;
            my @deps = $input_parts[0] ? (split /\s+/, $input_parts[0]) : ();
            @deps = grep { $_ ne '' } @deps;

            %current_build_vars = (
                rule => $rule_name,
                inputs => \@deps,
                output => $output,
            );
            next;
        }

        # Build variables (indented lines after 'build')
        if ($current_section eq 'build' && $line =~ /^\s+(\w+)\s*=\s*(.*)$/) {
            my ($var, $value) = ($1, $2);
            $current_build_vars{$var} = $value;
            next;
        }

        # Non-indented line ends current section
        if ($line !~ /^\s/ && $current_section ne '') {
            if ($current_section eq 'build' && $current_build_output) {
                _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
                $current_build_output = '';
                %current_build_vars = ();
            }
            $current_section = '';
        }
    }

    # Save last build if any
    if ($current_build_output) {
        _save_ninja_build(\%ninja_rules, $current_build_output, \%current_build_vars);
    }

    close($fh);
}

sub _save_ninja_build {
    my ($ninja_rules, $build_output, $build_vars) = @_;

    my $output = $build_vars->{output};
    my $rule_name = $build_vars->{rule};
    my @inputs = @{$build_vars->{inputs} || []};

    return unless $output && $rule_name;

    # Get rule template
    my $rule = $ninja_rules->{$rule_name} || {};
    my $command = $rule->{command} || '';

    # Expand variables in command
    # Replace ninja variables like $in, $out, $ARGS, etc.
    my %var_map = (
        'in' => join(' ', @inputs),
        'out' => $output,
    );

    # Add build-specific variables
    for my $var (keys %$build_vars) {
        next if $var eq 'rule' || $var eq 'inputs' || $var eq 'output';
        $var_map{$var} = $build_vars->{$var};
    }

    # Expand variables in command
    # First pass: expand known variables
    for my $var (keys %var_map) {
        my $value = $var_map{$var};
        $command =~ s/\$$var\b/$value/g;
        $command =~ s/\$\{$var\}/$value/g;
    }

    # Second pass: expand any remaining $VAR to empty string (undefined variables)
    $command =~ s/\$\{?([A-Z_][A-Z0-9_]*)\}?//g;

    # Extract compiler commands and convert to variables
    # This makes it easier to change compilers in the generated Makefile
    if ($command =~ /^\s*(\S*\/)?(\S+?)\s+/) {
        my $compiler_path = $1 || '';
        my $compiler = $2;

        # Detect C++ compilers
        if ($compiler =~ /^(c\+\+|g\+\+|clang\+\+|icpc|CC)$/) {
            # Store the full compiler command if not already set
            unless (exists $MV{CXX} && $MV{CXX} ne '') {
                $MV{CXX} = $compiler_path . $compiler;
            }
            # Replace compiler in command with $(CXX)
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{CXX}/;
        }
        # Detect C compilers
        elsif ($compiler =~ /^(cc|gcc|clang|icc)$/) {
            # Store the full compiler command if not already set
            unless (exists $MV{CC} && $MV{CC} ne '') {
                $MV{CC} = $compiler_path . $compiler;
            }
            # Replace compiler in command with $(CC)
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{CC}/;
        }
        # Detect linker/archiver commands
        elsif ($compiler =~ /^(ar|ld|ranlib)$/) {
            my $var = uc($compiler);
            unless (exists $MV{$var} && $MV{$var} ne '') {
                $MV{$var} = $compiler_path . $compiler;
            }
            $command =~ s/^\s*\Q$compiler_path$compiler\E/\$MV{$var}/;
        }
    }

    # Handle DEPFILE tracking
    my $depfile = $build_vars->{DEPFILE} || $build_vars->{depfile};
    if ($depfile) {
        # Expand depfile path
        for my $var (keys %var_map) {
            my $value = $var_map{$var};
            $depfile =~ s/\$$var\b/$value/g;
            $depfile =~ s/\$\{$var\}/$value/g;
        }

        # If depfile exists, parse it for additional dependencies
        if (-f $depfile) {
            my @dep_deps = _parse_depfile($depfile);
            push @inputs, @dep_deps;
        }
    }

    # Check if this is a phony target
    if ($rule_name =~ /^phony$/i) {
        $phony_targets{$output} = 1;
    }

    # Store in smak format
    my $key = "$makefile\t$output";
    $fixed_deps{$key} = \@inputs;
    $fixed_rule{$key} = $command;

    # Set default target
    if (!defined $default_target) {
        $default_target = $output;
    }
}

sub _parse_depfile {
    my ($depfile) = @_;

    open(my $fh, '<', $depfile) or return ();

    my @deps;
    my $content = do { local $/; <$fh> };
    close($fh);

    # Dependency files are in Makefile format: target: dep1 dep2 dep3
    # Can span multiple lines with backslash continuation
    $content =~ s/\\\n/ /g;  # Join continuation lines

    if ($content =~ /^[^:]+:\s*(.*)$/m) {
        my $deps_str = $1;
        @deps = split /\s+/, $deps_str;
        @deps = grep { $_ ne '' && -f $_ } @deps;  # Filter to existing files
    }

    return @deps;
}

sub write_makefile {
    my ($output_file) = @_;
    $output_file ||= 'Makefile.generated';

    open(my $fh, '>', $output_file) or die "Cannot write $output_file: $!";

    # Write header
    print $fh "# Generated Makefile from $makefile\n";
    print $fh "# Generated by smak-ninja\n\n";

    # Write command-line variable overrides first (if any)
    my @cmd_var_names = sort keys %cmd_vars;
    if (@cmd_var_names) {
        print $fh "# Command-line variable overrides\n";
        for my $var (@cmd_var_names) {
            my $value = $cmd_vars{$var};
            my $original = $MV{$var} // '';
            if ($original ne '' && $original ne $value) {
                print $fh "$var = $value  # was: $original\n";
            } else {
                print $fh "$var = $value\n";
            }
        }
        print $fh "\n";
    }

    # Write compiler variables first (these are most commonly modified)
    print $fh "# Compiler settings (modify these to change build mode)\n";
    my @compiler_vars = qw(CC CXX AR LD RANLIB);
    my $found_compiler = 0;
    for my $var (@compiler_vars) {
        next if exists $cmd_vars{$var};  # Skip if overridden on command line
        if (exists $MV{$var} && $MV{$var} ne '') {
            print $fh "$var = $MV{$var}\n";
            $found_compiler = 1;
        }
    }
    print $fh "\n" if $found_compiler;

    # Write other variables
    print $fh "# Other variables\n";
    for my $var (sort keys %MV) {
        next if $var eq 'ninja_required_version';  # Skip ninja-specific vars
        next if grep { $_ eq $var } @compiler_vars;  # Skip compiler vars (already written)
        next if exists $cmd_vars{$var};  # Skip command-line overrides (already written)
        my $value = $MV{$var};
        print $fh "$var = $value\n";
    }
    print $fh "\n";

    # Collect all targets (skip PHONY)
    my %all_targets;
    for my $key (keys %fixed_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';  # Skip PHONY target
        $all_targets{$target} = $key;
    }
    for my $key (keys %pattern_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        $all_targets{$target} = $key;
    }
    for my $key (keys %pseudo_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        $all_targets{$target} = $key;
    }

    # Find or create 'all' target
    my $has_all = exists $all_targets{'all'};

    # Write default target
    print $fh "# Default target\n";
    if ($has_all) {
        print $fh ".DEFAULT_GOAL := all\n\n";
    } else {
        # Create 'all' target if it doesn't exist
        print $fh ".DEFAULT_GOAL := all\n\n";
        print $fh "# Default all target\n";
        print $fh "all:\n";
        print $fh "\t\@echo 'Build complete'\n\n";
    }

    # Write .PHONY declarations
    my @phony = sort keys %phony_targets;
    if (@phony) {
        print $fh "# Phony targets (always rebuild)\n";
        print $fh ".PHONY: " . join(' ', @phony) . "\n\n";
    }

    # Write rules
    print $fh "# Build rules\n";
    for my $target (sort keys %all_targets) {
        my $key = $all_targets{$target};

        # Get dependencies and rule
        my $deps_ref = $fixed_deps{$key} || $pattern_deps{$key} || $pseudo_deps{$key};
        my $rule = $fixed_rule{$key} || $pattern_rule{$key} || $pseudo_rule{$key};

        next unless $deps_ref;

        my @deps = @$deps_ref;

        # Convert $MV{VAR} back to $(VAR)
        my $deps_str = join(' ', @deps);
        $deps_str = format_output($deps_str);

        # Write target line
        print $fh "$target: $deps_str\n";

        # Write rule commands
        if ($rule && $rule =~ /\S/) {
            my $formatted_rule = format_output($rule);
            for my $cmd (split /\n/, $formatted_rule) {
                next unless $cmd =~ /\S/;
                print $fh "\t$cmd\n";
            }
        }

        print $fh "\n";
    }

    close($fh);
    print "Makefile written to: $output_file\n";
}

sub get_all_ninja_outputs {
    # Collect all output files from parsed ninja file
    my @outputs;
    my %seen;

    # Collect from fixed_deps (most common for ninja builds)
    for my $key (keys %fixed_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        # Skip special/meta targets
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /^\.DEFAULT_GOAL/;
        # Skip targets that look like variables or directives
        next if $target =~ /^\$/;
        # Skip targets with spaces (multi-file targets from meson)
        next if $target =~ /\s/;
        # Skip paths that point outside the build directory
        next if $target =~ /^\.\./;
        # Skip the ninja file itself and meson internals
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
        # Add if not seen before
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pattern_deps (rare for ninja, but check anyway)
    for my $key (keys %pattern_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /\s/;
        next if $target =~ /^\.\./;
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    # Collect from pseudo_deps
    for my $key (keys %pseudo_deps) {
        my ($file, $target) = split(/\t/, $key, 2);
        next if $target eq 'PHONY';
        next if $target eq 'all';
        next if $target =~ /\s/;
        next if $target =~ /^\.\./;
        next if $target =~ /\.ninja$/;
        next if $target =~ /^meson-/;
        unless ($seen{$target}++) {
            push @outputs, $target;
        }
    }

    return @outputs;
}

# Helper function to parse make/smak command line
sub parse_make_command {
    my ($cmd) = @_;

    my $makefile = '';
    my @targets;

    # Split command line into tokens (simple split, doesn't handle quoted strings)
    my @parts = split /\s+/, $cmd;

    # Skip the command itself (make/smak/path)
    shift @parts;

    # Parse arguments
    for (my $i = 0; $i < @parts; $i++) {
        if ($parts[$i] eq '-f' && $i + 1 < @parts) {
            $makefile = $parts[$i + 1];
            $i++;  # Skip next arg
        } elsif ($parts[$i] =~ /^-/) {
            # Skip other options
            # Handle options that take arguments
            if ($parts[$i] =~ /^-(C|I|j|l|o|W)$/ && $i + 1 < @parts) {
                $i++;  # Skip option argument
            }
        } else {
            # It's a target
            push @targets, $parts[$i];
        }
    }

    return ($makefile, @targets);
}

# Helper function to get first target from a makefile
sub get_first_target {
    my ($mf) = @_;

    # Look for first non-special target in this makefile
    for my $key (keys %fixed_deps) {
        if ($key =~ /^\Q$mf\E\t(.+)$/) {
            my $tgt = $1;
            # Skip special targets that start with .
            next if $tgt =~ /^\./;
            return $tgt;
        }
    }

    # Try pseudo targets
    for my $key (keys %pseudo_deps) {
        if ($key =~ /^\Q$mf\E\t(.+)$/) {
            my $tgt = $1;
            next if $tgt =~ /^\./;
            return $tgt;
        }
    }

    return undef;
}

sub build_target {
    my ($target, $visited, $depth) = @_;
    $visited ||= {};
    $depth ||= 0;

    # Skip RCS/SCCS implicit rule patterns (these create infinite loops)
    # Make's built-in rules try: RCS/file,v, SCCS/s.file, etc.
    if ($target =~ m{(?:^|/)(?:RCS|SCCS)/} ||
        $target =~ /^s\./ ||
        $target =~ /,v+$/) {
        return;
    }

    # Prevent infinite recursion
    if ($depth > 100) {
        warn "Warning: Maximum recursion depth (100) reached building '$target' in $makefile\n";
        warn "         This may indicate a circular dependency or overly deep dependency chain.\n";
        return;
    }

    # Track visited targets per makefile to handle same target names in different makefiles
    my $visit_key = "$makefile\t$target";
    return if $visited->{$visit_key};
    $visited->{$visit_key} = 1;

    # Debug: show what we're building
    warn "DEBUG: Building target '$target' (depth=$depth, makefile=$makefile)\n" if $ENV{SMAK_DEBUG};

    my $key = "$makefile\t$target";
    my @deps;
    my $rule = '';

    # Find target in fixed, pattern, or pseudo rules
    if (exists $fixed_deps{$key}) {
        @deps = @{$fixed_deps{$key} || []};
        $rule = $fixed_rule{$key} || '';
    } elsif (exists $pattern_deps{$key}) {
        @deps = @{$pattern_deps{$key} || []};
        $rule = $pattern_rule{$key} || '';
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try to find pattern rule match
        for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    @deps = @{$pattern_deps{$pkey} || []};
                    $rule = $pattern_rule{$pkey} || '';
                    # Expand % in dependencies
                    my $stem = $1;
                    @deps = map { s/%/$stem/g; $_ } @deps;
                    last;
                }
            }
        }
    }

    # Expand variables in dependencies (which are in $MV{VAR} format)
    @deps = map {
        my $dep = $_;
        # Expand $MV{VAR} references
        while ($dep =~ /\$MV\{([^}]+)\}/) {
            my $var = $1;
            my $val = $MV{$var} // '';
            $dep =~ s/\$MV\{\Q$var\E\}/$val/;
        }
        $dep;
    } @deps;

    # Debug: show dependencies and rule status
    if ($ENV{SMAK_DEBUG}) {
        if (@deps) {
            warn "DEBUG:   Dependencies: " . join(', ', @deps) . "\n";
        }
        if ($rule && $rule =~ /\S/) {
            warn "DEBUG:   Has rule: yes\n";
        } else {
            warn "DEBUG:   Has rule: no\n";
        }
    }

    # Recursively build dependencies
    for my $dep (@deps) {
        build_target($dep, $visited, $depth + 1);
    }

    # Execute rule if it exists
    if ($rule && $rule =~ /\S/) {
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        # Expand variables
        my $expanded = expand_vars($converted);

        # Expand automatic variables
        $expanded =~ s/\$@/$target/g;                     # $@ = target name
        $expanded =~ s/\$</$deps[0] || ''/ge;            # $< = first prerequisite
        $expanded =~ s/\$\^/join(' ', @deps)/ge;         # $^ = all prerequisites

        # Execute each command line
        for my $cmd_line (split /\n/, $expanded) {
            next unless $cmd_line =~ /\S/;  # Skip empty lines

            # Check if command starts with @ (silent mode)
            my $silent = ($cmd_line =~ s/^\s*@//);

            # In dry-run mode, handle recursive make invocations or print commands
            if ($dry_run_mode) {
                # Check if this is a recursive make/smak invocation
                if ($cmd_line =~ /\b(make|smak)\s/ || $cmd_line =~ m{/smak(?:\s|$)}) {
                    # Debug: show what we detected
                    warn "DEBUG: Detected recursive make/smak: $cmd_line\n" if $ENV{SMAK_DEBUG};

                    # Parse the make/smak command line to extract -f and targets
                    my ($sub_makefile, @sub_targets) = parse_make_command($cmd_line);

                    warn "DEBUG: Parsed makefile='$sub_makefile' targets=(" . join(',', @sub_targets) . ")\n" if $ENV{SMAK_DEBUG};

                    if ($sub_makefile) {
                        # Save current makefile state
                        my $saved_makefile = $makefile;

                        # Switch to sub-makefile
                        $makefile = $sub_makefile;

                        # Parse the sub-makefile if not already parsed
                        my $test_key = "$makefile\t" . ($sub_targets[0] || 'all');
                        unless (exists $fixed_deps{$test_key} || exists $pattern_deps{$test_key} || exists $pseudo_deps{$test_key}) {
                            eval {
                                parse_makefile($makefile);
                            };
                            if ($@) {
                                warn "Warning: Could not parse sub-makefile '$makefile': $@\n";
                                # Restore state and fall back to just printing the command
                                $makefile = $saved_makefile;
                                print "$cmd_line\n";
                                next;
                            }
                        }

                        # Build sub-targets recursively in dry-run mode
                        if (@sub_targets) {
                            for my $sub_target (@sub_targets) {
                                build_target($sub_target, $visited, $depth + 1);
                            }
                        } else {
                            # No targets specified, build first target
                            my $first_target = get_first_target($makefile);
                            build_target($first_target, $visited, $depth + 1) if $first_target;
                        }

                        # Restore makefile state
                        $makefile = $saved_makefile;
                        next;
                    }
                }

                # Not a recursive make, just print the command
                print "$cmd_line\n";
                next;
            }

            # Echo command unless silent (like make)
            # Silent mode (-s) suppresses all command echoing
            unless ($silent || $silent_mode) {
                tee_print("$cmd_line\n");
            }

            # Execute the command (capture output if in report mode)
            my $exit_code;
            if ($report_mode) {
                # Capture both stdout and stderr
                my $output = `$cmd_line 2>&1`;
                $exit_code = $? >> 8;  # Extract actual exit code from wait status
                tee_print($output) if $output;
            } else {
                my $status = system($cmd_line);
                $exit_code = $status >> 8;  # Extract actual exit code from wait status
            }

            if ($exit_code != 0) {
                my $err_msg = "smak: *** [$target] Error $exit_code\n";
                tee_print($err_msg);
                die $err_msg;
            }
        }
    }
}

sub dry_run_target {
    my ($target, $visited, $depth) = @_;
    $visited ||= {};
    $depth ||= 0;

    # Skip RCS/SCCS implicit rule patterns (these create infinite loops)
    # Make's built-in rules try: RCS/file,v, SCCS/s.file, etc.
    if ($target =~ m{(?:^|/)(?:RCS|SCCS)/} ||
        $target =~ /^s\./ ||
        $target =~ /,v+$/) {
        return;
    }

    # Prevent infinite recursion
    if ($depth > 100) {
        warn "Warning: Maximum recursion depth (100) reached for target '$target' in $makefile\n";
        warn "         This may indicate a circular dependency or overly deep dependency chain.\n";
        return;
    }

    # Track visited targets per makefile to handle same target names in different makefiles
    my $visit_key = "$makefile\t$target";
    return if $visited->{$visit_key};
    $visited->{$visit_key} = 1;

    my $indent = "  " x $depth;
    print "${indent}Building: $target\n";

    my $key = "$makefile\t$target";
    my @deps;
    my $rule = '';

    # Find target in fixed, pattern, or pseudo rules
    if (exists $fixed_deps{$key}) {
        @deps = @{$fixed_deps{$key} || []};
        $rule = $fixed_rule{$key} || '';
    } elsif (exists $pattern_deps{$key}) {
        @deps = @{$pattern_deps{$key} || []};
        $rule = $pattern_rule{$key} || '';
    } elsif (exists $pseudo_deps{$key}) {
        @deps = @{$pseudo_deps{$key} || []};
        $rule = $pseudo_rule{$key} || '';
    } else {
        # Try to find pattern rule match
        for my $pkey (keys %pattern_rule) {
            if ($pkey =~ /^[^\t]+\t(.+)$/) {
                my $pattern = $1;
                my $pattern_re = $pattern;
                $pattern_re =~ s/%/(.+)/g;
                if ($target =~ /^$pattern_re$/) {
                    @deps = @{$pattern_deps{$pkey} || []};
                    $rule = $pattern_rule{$pkey} || '';
                    # Expand % in dependencies
                    my $stem = $1;
                    @deps = map { s/%/$stem/g; $_ } @deps;
                    last;
                }
            }
        }
    }

    # Print dependencies
    if (@deps) {
        print "${indent}  Dependencies: ", join(', ', @deps), "\n";
    }

    # Recursively dry-run dependencies
    for my $dep (@deps) {
        dry_run_target($dep, $visited, $depth + 1);
    }

    # Print rule if it exists
    if ($rule && $rule =~ /\S/) {
        # Convert $MV{VAR} to $(VAR) for expansion
        my $converted = format_output($rule);
        # Expand variables
        my $expanded = expand_vars($converted);
        print $expanded;
    }
}

sub execute_script {
    my ($filename) = @_;

    open(my $script_fh, '<', $filename) or die "Cannot open script file '$filename': $!\n";

    while (my $line = <$script_fh>) {
        chomp $line;

        # Skip empty lines and comments
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;

        # Process commands (simplified version of interactive_debug command processing)
        if ($line =~ /^\s*add-rule\s+(.+?)\s*:\s*(.+?)\s*:\s*(.+)$/i) {
            my ($target, $deps, $rule_text) = ($1, $2, $3);

            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;

            # Ensure each line starts with a tab (Makefile requirement)
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

            add_rule($target, $deps, $rule_text);
        }
        elsif ($line =~ /^\s*mod-rule\s+(.+?)\s*:\s*(.+)$/i) {
            my ($target, $rule_text) = ($1, $2);

            # Handle escape sequences
            $rule_text =~ s/\\n/\n/g;
            $rule_text =~ s/\\t/\t/g;

            # Ensure each line starts with a tab
            $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

            modify_rule($target, $rule_text);
        }
        elsif ($line =~ /^\s*mod-deps\s+(.+?)\s*:\s*(.+)$/i) {
            my ($target, $deps) = ($1, $2);
            modify_deps($target, $deps);
        }
        elsif ($line =~ /^\s*del-rule\s+(.+)$/i) {
            my $target = $1;
            delete_rule($target);
        }
        else {
            warn "Unknown command in script: $line\n";
        }
    }

    close($script_fh);
}

sub add_rule {
    my ($target, $deps, $rule_text) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $rule_text = transform_make_vars($rule_text);
    $deps = transform_make_vars($deps);

    my @deps_array = split /\s+/, $deps;

    if ($type eq 'fixed') {
        $fixed_rule{$key} = $rule_text . "\n";
        $fixed_deps{$key} = \@deps_array;
    } elsif ($type eq 'pattern') {
        $pattern_rule{$key} = $rule_text . "\n";
        $pattern_deps{$key} = \@deps_array;
    } elsif ($type eq 'pseudo') {
        $pseudo_rule{$key} = $rule_text . "\n";
        $pseudo_deps{$key} = \@deps_array;
    }

    # Track modification
    my $escaped_rule = $rule_text;
    $escaped_rule =~ s/\n/\\n/g;
    $escaped_rule =~ s/\t/\\t/g;
    push @modifications, "add-rule $target : $deps : $escaped_rule\n";

    print "Added rule for '$target'\n";
}

sub modify_rule {
    my ($target, $rule_text) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $rule_text = transform_make_vars($rule_text);

    my $found = 0;
    if ($type eq 'fixed' && exists $fixed_rule{$key}) {
        $fixed_rule{$key} = $rule_text . "\n";
        $found = 1;
    } elsif ($type eq 'pattern' && exists $pattern_rule{$key}) {
        $pattern_rule{$key} = $rule_text . "\n";
        $found = 1;
    } elsif ($type eq 'pseudo' && exists $pseudo_rule{$key}) {
        $pseudo_rule{$key} = $rule_text . "\n";
        $found = 1;
    }

    if ($found) {
        # Track modification
        my $escaped_rule = $rule_text;
        $escaped_rule =~ s/\n/\\n/g;
        $escaped_rule =~ s/\t/\\t/g;
        push @modifications, "mod-rule $target : $escaped_rule\n";
        print "Modified rule for '$target'\n";
    } else {
        print "Rule '$target' not found\n";
    }
}

sub modify_deps {
    my ($target, $deps) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    # Transform $(VAR) and $X to $MV{VAR} and $MV{X}
    $deps = transform_make_vars($deps);

    my @deps_array = split /\s+/, $deps;

    my $found = 0;
    if ($type eq 'fixed' && exists $fixed_deps{$key}) {
        $fixed_deps{$key} = \@deps_array;
        $found = 1;
    } elsif ($type eq 'pattern' && exists $pattern_deps{$key}) {
        $pattern_deps{$key} = \@deps_array;
        $found = 1;
    } elsif ($type eq 'pseudo' && exists $pseudo_deps{$key}) {
        $pseudo_deps{$key} = \@deps_array;
        $found = 1;
    }

    if ($found) {
        # Track modification
        push @modifications, "mod-deps $target : $deps\n";
        print "Modified dependencies for '$target'\n";
    } else {
        print "Target '$target' not found\n";
    }
}

sub delete_rule {
    my ($target) = @_;

    my $type = classify_target($target);
    my $key = "$makefile\t$target";

    my $found = 0;
    if ($type eq 'fixed') {
        delete $fixed_rule{$key} if exists $fixed_rule{$key};
        delete $fixed_deps{$key} if exists $fixed_deps{$key};
        $found = 1;
    } elsif ($type eq 'pattern') {
        delete $pattern_rule{$key} if exists $pattern_rule{$key};
        delete $pattern_deps{$key} if exists $pattern_deps{$key};
        $found = 1;
    } elsif ($type eq 'pseudo') {
        delete $pseudo_rule{$key} if exists $pseudo_rule{$key};
        delete $pseudo_deps{$key} if exists $pseudo_deps{$key};
        $found = 1;
    }

    if ($found) {
        # Track modification
        push @modifications, "del-rule $target\n";
        print "Deleted rule '$target'\n";
    } else {
        print "Rule '$target' not found\n";
    }
}

sub save_modifications {
    my ($output_file) = @_;

    open(my $out_fh, '>', $output_file) or die "Cannot open '$output_file' for writing: $!\n";

    for my $mod (@modifications) {
        print $out_fh $mod;
    }

    close($out_fh);
    print "Saved modifications to '$output_file'\n";
}

sub interactive_debug {
    my $term = Term::ReadLine->new('smak');
    my $OUT = $term->OUT || \*STDOUT;

    print $OUT "Interactive smak debugger. Type 'help' for commands.\n";

    while (defined(my $input = $term->readline($echo ? $prompt : $prompt))) {
        chomp $input;

        # Echo the line if echo mode is enabled
        if ($echo && $input ne '') {
            print "$prompt$input\n";
        }

        # Skip empty input
        next if $input =~ /^\s*$/;

        # Add to history
        $term->addhistory($input) if $input =~ /\S/;

        # Parse command
        my @parts = split /\s+/, $input;
        my $cmd = lc($parts[0]);

        if ($cmd eq 'quit' || $cmd eq 'q' || $cmd eq 'exit') {
            last;
        }
        elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
            print $OUT <<'HELP';
Commands:
  list, l              - List all rules
  build <target>       - Build a target
  dry-run <target>     - Dry run a target
  print <expr>         - Evaluate and print an expression (in isolated subprocess)
  eval <expr>          - Evaluate a Perl expression (in isolated subprocess)
  !<command>           - Run a shell command
  set                  - Show control variables
  set <var> <value>    - Set a control variable (timeout, prompt, echo)
  add-rule <target> : <deps> : <rule>
                       - Add a new rule
  mod-rule <target> : <rule>
                       - Modify rule commands
  mod-deps <target> : <deps>
                       - Modify dependencies
  del-rule <target>    - Delete a rule
  save <file>          - Save modifications to file
  help, h, ?           - Show this help
  quit, q, exit        - Exit debugger
HELP
        }
        elsif ($cmd eq 'list' || $cmd eq 'l') {
            print_rules();
        }
        elsif ($cmd eq 'build') {
            if (@parts < 2) {
                print $OUT "Usage: build <target>\n";
            } else {
                my $target = $parts[1];
                eval { build_target($target); };
                if ($@) {
                    print $OUT "Error building target: $@\n";
                }
            }
        }
        elsif ($cmd eq 'dry-run') {
            if (@parts < 2) {
                print $OUT "Usage: dry-run <target>\n";
            } else {
                my $target = $parts[1];
                dry_run_target($target);
            }
        }
        elsif ($cmd eq 'print') {
            my $expr = $input;
            $expr =~ s/^\s*print\s+//;

            # Fork a subprocess to evaluate the expression with a timeout
            my $pid = fork();
            if (!defined $pid) {
                print $OUT "Failed to fork: $!\n";
                next;
            }

            if ($pid == 0) {
                # Child process
                # Expand variables in the expression
                my $expanded = expand_vars($expr);
                print "$expanded\n";
                exit 0;
            } else {
                # Parent process
                my $start_time = time();
                my $timed_out = 0;

                while (1) {
                    my $kid = waitpid($pid, WNOHANG);
                    if ($kid > 0) {
                        # Child exited
                        last;
                    }
                    if (time() - $start_time > $timeout) {
                        # Timeout
                        kill 'KILL', $pid;
                        waitpid($pid, 0);
                        $timed_out = 1;
                        last;
                    }
                    select(undef, undef, undef, 0.1);  # Sleep 0.1 seconds
                }

                if ($timed_out) {
                    print $OUT "Evaluation timed out after $timeout seconds\n";
                }
            }
        }
        elsif ($cmd eq 'set') {
            if (@parts == 1) {
                print $OUT "Control variables:\n";
                print $OUT "  timeout = $timeout\n";
                print $OUT "  prompt = $prompt\n";
                print $OUT "  echo = $echo\n";
            } elsif (@parts >= 3) {
                my $var = lc($parts[1]);
                my $value = join(' ', @parts[2..$#parts]);

                if ($var eq 'timeout') {
                    $timeout = $value;
                    print $OUT "Set timeout = $timeout\n";
                } elsif ($var eq 'prompt') {
                    # Remove quotes if present
                    $value =~ s/^["']|["']$//g;
                    $prompt = $value;
                    print $OUT "Set prompt = $prompt\n";
                } elsif ($var eq 'echo') {
                    $echo = $value;
                    print $OUT "Set echo = $echo\n";
                } else {
                    print $OUT "Unknown variable: $var\n";
                }
            } else {
                print $OUT "Usage: set <variable> <value>\n";
            }
        }
        elsif ($cmd eq 'add-rule') {
            if ($input =~ /^\s*add-rule\s+(.+?)\s*:\s*(.+?)\s*:\s*(.+)$/i) {
                my ($target, $deps, $rule_text) = ($1, $2, $3);

                # Handle escape sequences
                $rule_text =~ s/\\n/\n/g;
                $rule_text =~ s/\\t/\t/g;

                # Ensure each line starts with a tab
                $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                add_rule($target, $deps, $rule_text);
            } else {
                print $OUT "Usage: add-rule <target> : <deps> : <rule>\n";
            }
        }
        elsif ($cmd eq 'mod-rule') {
            if ($input =~ /^\s*mod-rule\s+(.+?)\s*:\s*(.+)$/i) {
                my ($target, $rule_text) = ($1, $2);

                # Handle escape sequences
                $rule_text =~ s/\\n/\n/g;
                $rule_text =~ s/\\t/\t/g;

                # Ensure each line starts with a tab
                $rule_text = join("\n", map { /^\t/ ? $_ : "\t$_" } split(/\n/, $rule_text));

                modify_rule($target, $rule_text);
            } else {
                print $OUT "Usage: mod-rule <target> : <rule>\n";
            }
        }
        elsif ($cmd eq 'mod-deps') {
            if ($input =~ /^\s*mod-deps\s+(.+?)\s*:\s*(.+)$/i) {
                my ($target, $deps) = ($1, $2);
                modify_deps($target, $deps);
            } else {
                print $OUT "Usage: mod-deps <target> : <deps>\n";
            }
        }
        elsif ($cmd eq 'del-rule') {
            if (@parts >= 2) {
                my $target = $parts[1];
                delete_rule($target);
            } else {
                print $OUT "Usage: del-rule <target>\n";
            }
        }
        elsif ($cmd eq 'save') {
            if (@parts >= 2) {
                my $filename = $parts[1];
                save_modifications($filename);
            } else {
                print $OUT "Usage: save <filename>\n";
            }
        }
        elsif ($cmd eq 'eval') {
            my $expr = $input;
            $expr =~ s/^\s*eval\s+//;

            # Evaluate Perl expression in subprocess with timeout
            my $pid = fork();
            if (!defined $pid) {
                print $OUT "Failed to fork: $!\n";
                next;
            }

            if ($pid == 0) {
                # Child process - evaluate the expression
                my $result = eval $expr;
                if ($@) {
                    print "Error: $@\n";
                } else {
                    print "$result\n" if defined $result;
                }
                exit 0;
            } else {
                # Parent process - wait with timeout
                my $start_time = time();
                my $timed_out = 0;

                while (1) {
                    my $kid = waitpid($pid, WNOHANG);
                    if ($kid > 0) {
                        last;
                    }
                    if (time() - $start_time > $timeout) {
                        kill 'KILL', $pid;
                        waitpid($pid, 0);
                        $timed_out = 1;
                        last;
                    }
                    select(undef, undef, undef, 0.1);
                }

                if ($timed_out) {
                    print $OUT "Evaluation timed out after $timeout seconds\n";
                }
            }
        }
        elsif ($input =~ /^!(.+)/) {
            # Shell command execution
            my $shell_cmd = $1;
            system($shell_cmd);
        }
        else {
            print $OUT "Unknown command: $cmd (type 'help' for commands)\n";
        }
    }
}

sub print_rules {
    print "Rules parsed from $makefile:\n";
    print "=" x 60 . "\n\n";

    # Print pseudo rules
    if (keys %pseudo_rule || keys %pseudo_deps) {
        print "PSEUDO RULES (.PHONY, .PRECIOUS, etc.):\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %pseudo_rule, keys %pseudo_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$pseudo_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($pseudo_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print pattern rules
    if (keys %pattern_rule || keys %pattern_deps) {
        print "PATTERN RULES (with % wildcards):\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %pattern_rule, keys %pattern_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$pattern_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($pattern_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print fixed rules
    if (keys %fixed_rule || keys %fixed_deps) {
        print "FIXED RULES:\n";
        print "-" x 60 . "\n";
        my %seen;
        for my $key (sort keys %fixed_rule, keys %fixed_deps) {
            next if $seen{$key}++;
            print "Key: $key\n";
            print "Dependencies: ", join(', ', @{$fixed_deps{$key} || []}), "\n";
            print "Rule:\n", format_output($fixed_rule{$key} || "(none)\n");
            print "-" x 60 . "\n";
        }
        print "\n";
    }

    # Print variables
    if (keys %MV) {
        print "VARIABLES:\n";
        print "-" x 60 . "\n";
        for my $var (sort keys %MV) {
            my $value = format_output($MV{$var});
            print "$var = $value\n";
        }
    }
}

1;  # Return true to indicate successful module load
