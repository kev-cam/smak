package SmakCMake;
# SmakCMake - Parse CMake build directories directly into smak rule tables.
#
# Instead of interpreting CMake-generated Makefiles (which use cmake -E
# commands for dependency scanning, progress tracking, etc.), we read
# CMake's own metadata files:
#
#   CMakeFiles/Makefile2           - inter-target dependency graph
#   <target>.dir/DependInfo.cmake  - source → object mapping
#   <target>.dir/flags.make        - compiler flags
#   <target>.dir/link.txt          - link command
#   <target>.dir/compiler_depend.make - header dependencies
#
# This produces the same %fixed_deps / %fixed_rule tables that
# parse_makefile() builds from a regular Makefile.

use strict;
use warnings;
use File::Find;
use File::Basename;
use Cwd 'abs_path';

# Detect whether a directory is a CMake build directory.
sub is_cmake_build_dir {
    my ($dir) = @_;
    return -f "$dir/CMakeCache.txt" && -d "$dir/CMakeFiles";
}

# Parse a CMake build directory and return a build description.
# Returns a hashref:
#   {
#     source_dir => '/path/to/source',
#     build_dir  => '/path/to/build',
#     targets    => { target_name => { ... } },
#     target_deps => { target_name => [dep_names] },
#     all_targets => [target_names in dependency order for 'all'],
#   }
sub parse_cmake_build {
    my ($build_dir) = @_;
    $build_dir = abs_path($build_dir) // $build_dir;

    my %info = (
        build_dir  => $build_dir,
        source_dir => '',
        targets    => {},
        target_deps => {},
        all_targets => [],
    );

    # Read CMakeCache for source dir and compiler info
    parse_cmake_cache("$build_dir/CMakeCache.txt", \%info);

    # Parse Makefile2 for the target dependency graph
    parse_makefile2("$build_dir/CMakeFiles/Makefile2", \%info);

    # Find and parse all target directories
    find_target_dirs($build_dir, \%info);

    return \%info;
}

# Parse CMakeCache.txt for key variables.
sub parse_cmake_cache {
    my ($cache_file, $info) = @_;
    open(my $fh, '<', $cache_file) or return;

    my %cache;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        if (/^(\w+):(\w+)=(.*)$/) {
            $cache{$1} = $3;
        }
    }
    close($fh);

    $info->{source_dir} = $cache{CMAKE_HOME_DIRECTORY} // '';
    $info->{cmake_command} = $cache{CMAKE_COMMAND} // 'cmake';
    $info->{c_compiler} = $cache{CMAKE_C_COMPILER} // 'cc';
    $info->{cxx_compiler} = $cache{CMAKE_CXX_COMPILER} // 'c++';
    $info->{fortran_compiler} = $cache{CMAKE_Fortran_COMPILER} // 'gfortran';
    $info->{ar} = $cache{CMAKE_AR} // 'ar';
    $info->{ranlib} = $cache{CMAKE_RANLIB} // 'ranlib';
    $info->{cache} = \%cache;
}

# Parse CMakeFiles/Makefile2 for the target dependency graph.
# Lines like:
#   packages/kokkos/core/src/CMakeFiles/kokkoscore.dir/all: packages/teuchos/core/src/CMakeFiles/teuchoscore.dir/all
#   all: packages/kokkos/all
sub parse_makefile2 {
    my ($makefile2, $info) = @_;
    open(my $fh, '<', $makefile2) or do {
        warn "SmakCMake: Cannot open $makefile2: $!\n";
        return;
    };

    my %target_deps;  # raw: "kokkoscore.dir/all" => ["dep.dir/all", ...]
    my %all_deps;     # top-level "all" deps

    while (<$fh>) {
        chomp;
        # target.dir/all: dep.dir/all
        if (m{^(\S+/CMakeFiles/(\w+)\.dir/all):\s*(\S+/CMakeFiles/(\w+)\.dir/all)?\s*$}) {
            my ($target_path, $target_name, $dep_path, $dep_name) = ($1, $2, $3, $4);
            $target_deps{$target_name} //= [];
            push @{$target_deps{$target_name}}, $dep_name if defined $dep_name;
        }
        # all: packages/foo/all  (top-level)
        elsif (/^all:\s+(\S+)\/all\s*$/) {
            my $pkg_path = $1;
            # Resolve to actual target names via sub-targets
            $all_deps{$pkg_path} = 1;
        }
    }
    close($fh);

    $info->{target_deps} = \%target_deps;
    $info->{all_deps_raw} = \%all_deps;
}

# Find all CMakeFiles/<target>.dir/ directories and parse their metadata.
sub find_target_dirs {
    my ($build_dir, $info) = @_;

    my @target_dirs;
    File::Find::find({
        wanted => sub {
            if (/\/CMakeFiles\/(\w+)\.dir$/ && -d $_) {
                my $name = $1;
                my $dir = $_;
                # Must have DependInfo.cmake to be a real build target
                if (-f "$dir/DependInfo.cmake") {
                    push @target_dirs, { name => $name, dir => $dir };
                }
            }
        },
        no_chdir => 1,
    }, $build_dir);

    for my $td (@target_dirs) {
        my $target = parse_target_dir($td->{name}, $td->{dir}, $build_dir, $info);
        $info->{targets}{$td->{name}} = $target if $target;
    }
}

# Parse a single target directory's metadata files.
sub parse_target_dir {
    my ($name, $dir, $build_dir, $info) = @_;

    my %target = (
        name     => $name,
        dir      => $dir,
        sources  => [],   # [{src => path, obj => path, depfile => path}, ...]
        flags    => {},    # {CXX_FLAGS => "...", CXX_DEFINES => "...", ...}
        link_cmd => '',    # full link command
        objects  => [],    # object file paths
    );

    # Parse DependInfo.cmake for source → object mapping
    parse_depend_info("$dir/DependInfo.cmake", \%target, $build_dir);

    # Parse flags.make for compiler flags
    parse_flags("$dir/flags.make", \%target);

    # Read link.txt for the link command
    if (-f "$dir/link.txt") {
        open(my $fh, '<', "$dir/link.txt") or return \%target;
        local $/;
        $target{link_cmd} = <$fh>;
        chomp $target{link_cmd};
        close($fh);
    }

    return \%target;
}

# Parse DependInfo.cmake.
# Format:
#   set(CMAKE_DEPENDS_DEPENDENCY_FILES
#     "/path/to/source.cpp" "relative/obj.o" "gcc" "relative/obj.o.d"
#     ...
#   )
sub parse_depend_info {
    my ($file, $target, $build_dir) = @_;
    open(my $fh, '<', $file) or return;

    my $in_deps = 0;
    my $in_check = '';  # language for CMAKE_DEPENDS_CHECK_<lang>
    while (<$fh>) {
        chomp;
        if (/set\(CMAKE_DEPENDS_DEPENDENCY_FILES/) {
            $in_deps = 1;
            $in_check = '';
            next;
        }
        # Older format: set(CMAKE_DEPENDS_CHECK_Fortran "src" "obj" ...)
        if (/set\(CMAKE_DEPENDS_CHECK_(\w+)/) {
            $in_check = $1;
            $in_deps = 0;
            next;
        }
        if ($in_deps || $in_check) {
            if (/^\s*\)/) {
                $in_deps = 0;
                $in_check = '';
                next;
            }
            my @fields;
            while (/\"([^\"]*)\"/g) {
                push @fields, $1;
            }
            if ($in_deps && @fields >= 4) {
                # New format: src obj compiler depfile
                my ($src, $obj, $compiler, $depfile) = @fields;
                push @{$target->{sources}}, {
                    src     => $src,
                    obj     => $obj,
                    compiler => $compiler,
                    depfile => $depfile,
                };
                push @{$target->{objects}}, $obj;
            } elsif ($in_check && @fields >= 2) {
                # Old format: src obj (language from variable name)
                my ($src, $obj) = @fields;
                push @{$target->{sources}}, {
                    src     => $src,
                    obj     => $obj,
                    compiler => lc($in_check),
                    depfile => "$obj.d",
                };
                push @{$target->{objects}}, $obj;
            }
        }
    }
    close($fh);
}

# Parse flags.make.
# Format:
#   CXX_DEFINES = -DFOO
#   CXX_INCLUDES = -I/path ...
#   CXX_FLAGS = -O3 -std=c++17
sub parse_flags {
    my ($file, $target) = @_;
    open(my $fh, '<', $file) or return;
    while (<$fh>) {
        chomp;
        if (/^(\w+)\s*=\s*(.*)$/) {
            $target->{flags}{$1} = $2;
        }
    }
    close($fh);
}

# Generate smak rules from parsed CMake data.
# Populates the caller's %fixed_deps, %fixed_rule, %MV tables.
#
# For each target:
#   - One rule per source file: obj.o depends on src.cpp
#     Command: compiler $(DEFINES) $(INCLUDES) $(FLAGS) -MD -MT obj.o -MF obj.o.d -o obj.o -c src.cpp
#   - One link rule: lib.a depends on all obj.o files
#     Command: contents of link.txt
#
# For target-level deps:
#   - lib.a depends on dep_lib.a (from Makefile2 graph)
sub generate_smak_rules {
    my ($cmake_info, $fixed_deps, $fixed_rule, $MV, $makefile_key) = @_;
    $makefile_key //= 'CMakeLists.txt';

    my $build_dir = $cmake_info->{build_dir};
    my $targets = $cmake_info->{targets};
    my $target_deps = $cmake_info->{target_deps};

    # Map target name → output file (library or executable)
    my %target_output;

    for my $name (sort keys %$targets) {
        my $t = $targets->{$name};
        my $flags = $t->{flags};

        # Determine the target's sub-directory (absolute for cd commands)
        my $target_dir = $t->{dir};
        $target_dir =~ s{/CMakeFiles/\w+\.dir$}{};
        my $rel_dir = $target_dir;
        $rel_dir =~ s{^\Q$build_dir\E/?}{};
        $rel_dir = '.' if $rel_dir eq '';
        # Use absolute path for cd in compile/link commands
        my $abs_dir = $rel_dir eq '.' ? $build_dir : "$build_dir/$rel_dir";

        # Objects from DependInfo are relative to build_dir (e.g.,
        # "packages/foo/CMakeFiles/bar.dir/baz.o"), NOT relative to rel_dir.
        # All rule keys must use build_dir-relative paths consistently.

        # Build compile commands for each source
        for my $src_info (@{$t->{sources}}) {
            my $src = $src_info->{src};
            my $obj = $src_info->{obj};      # already build_dir-relative
            my $depfile = $src_info->{depfile};

            # Determine compiler from source extension
            my $compiler;
            # Obj/depfile may be absolute (old CMAKE_DEPENDS_CHECK format)
            # or relative to build_dir (new CMAKE_DEPENDS_DEPENDENCY_FILES)
            my $abs_obj = $obj =~ m{^/} ? $obj : "$build_dir/$obj";
            my $abs_depfile = $depfile =~ m{^/} ? $depfile : "$build_dir/$depfile";

            # Pick compiler and flags based on source extension
            my (@parts, $lang);
            if ($src =~ /\.f(?:90|95|03|08)?$/i || $src =~ /\.F(?:90|95|03|08)?$/i) {
                $lang = 'Fortran';
                @parts = ($cmake_info->{fortran_compiler});
                push @parts, $flags->{Fortran_DEFINES} // '';
                push @parts, $flags->{Fortran_INCLUDES} // '';
                push @parts, $flags->{Fortran_FLAGS} // '';
            } elsif ($src =~ /\.c$/) {
                $lang = 'C';
                @parts = ($cmake_info->{c_compiler});
                push @parts, $flags->{C_DEFINES} // '';
                push @parts, $flags->{C_INCLUDES} // '';
                push @parts, $flags->{C_FLAGS} // '';
            } else {
                $lang = 'CXX';
                @parts = ($cmake_info->{cxx_compiler});
                push @parts, $flags->{CXX_DEFINES} // '';
                push @parts, $flags->{CXX_INCLUDES} // '';
                push @parts, $flags->{CXX_FLAGS} // '';
            }
            # Fortran doesn't use -MD dependency tracking
            if ($lang eq 'Fortran') {
                push @parts, "-o $abs_obj -c $src";
            } else {
                push @parts, "-MD -MT $abs_obj -MF $abs_depfile -o $abs_obj -c $src";
            }
            {
                my $compile_cmd = "mkdir -p " . dirname($abs_obj) . " && " .
                    join(' ', grep { $_ ne '' } @parts);

                my $dep_key = "$makefile_key\t$obj";
                $fixed_deps->{$dep_key} = [$src];
                $fixed_rule->{$dep_key} = $compile_cmd;
            }
        }

        # Build link rule
        if ($t->{link_cmd}) {
            # Determine output file from link command
            my $output;
            my $link = $t->{link_cmd};
            if ($link =~ /\bar\b.*?\s(\S+\.a)\b/) {
                $output = $1;
            } elsif ($link =~ /-o\s+(\S+)/) {
                $output = $1;
            }

            if ($output) {
                # Qualify output with rel_dir, objects are already build_dir-relative
                my $qualified_output = $rel_dir ne '.' ? "$rel_dir/$output" : $output;
                $target_output{$name} = $qualified_output;

                my $dep_key = "$makefile_key\t$qualified_output";
                # Objects are already build_dir-relative — don't add rel_dir again
                $fixed_deps->{$dep_key} = [@{$t->{objects}}];

                # Absolutize paths in link command (link.txt paths are
                # relative to the target's subdirectory)
                my $link_cmd = $t->{link_cmd};
                if ($rel_dir ne '.') {
                    # Replace relative object/library paths with absolute ones
                    # CMakeFiles/foo.dir/bar.o → /abs/build/rel_dir/CMakeFiles/...
                    $link_cmd =~ s{(CMakeFiles/\S+)}{$abs_dir/$1}g;
                    # Library output: libfoo.a → /abs/build/rel_dir/libfoo.a
                    $link_cmd =~ s{\b(lib\w+\.a)\b}{$abs_dir/$1}g;
                    # Executable output: -o foo → -o /abs/build/rel_dir/foo
                    $link_cmd =~ s{-o\s+(\S+)}{-o $abs_dir/$1}g
                        unless $link_cmd =~ /\bar\b/;
                }
                $fixed_rule->{$dep_key} = $link_cmd;
            }
        }
    }

    # Add inter-target dependencies (library depends on other libraries)
    for my $name (keys %$target_deps) {
        my $output = $target_output{$name} or next;
        my $dep_key = "$makefile_key\t$output";
        my $existing = $fixed_deps->{$dep_key} // [];

        for my $dep_name (@{$target_deps->{$name}}) {
            my $dep_output = $target_output{$dep_name};
            next unless $dep_output;
            # Add as order-only dep (must exist, doesn't trigger rebuild)
            push @$existing, $dep_output unless grep { $_ eq $dep_output } @$existing;
        }
        $fixed_deps->{$dep_key} = $existing;
    }

    # Build top-level 'all' target
    my @all_outputs;
    for my $name (sort keys %target_output) {
        push @all_outputs, $target_output{$name};
    }
    if (@all_outputs) {
        my $dep_key = "$makefile_key\tall";
        $fixed_deps->{$dep_key} = \@all_outputs;
        $fixed_rule->{$dep_key} = '';  # no recipe — just deps
    }

    return \%target_output;
}

# One-shot: detect, parse, and generate rules for a CMake build dir.
# Returns true if it was a CMake project and rules were generated.
sub try_cmake_project {
    my ($dir, $fixed_deps, $fixed_rule, $MV, $makefile_key) = @_;

    return 0 unless is_cmake_build_dir($dir);

    my $info = parse_cmake_build($dir);
    my $n_targets = scalar keys %{$info->{targets}};
    my $n_sources = 0;
    for my $t (values %{$info->{targets}}) {
        $n_sources += scalar @{$t->{sources}};
    }

    print STDERR "SmakCMake: $dir — $n_targets targets, $n_sources sources\n"
        if $ENV{SMAK_DEBUG};

    generate_smak_rules($info, $fixed_deps, $fixed_rule, $MV, $makefile_key);
    return 1;
}

1;
