# Building CMake Projects with smak

smak can build CMake projects two ways:

1. **Interpret CMakeLists.txt directly** (no cmake needed at all)
2. **Read cmake's generated metadata** (cmake must have run at least once)

The first approach uses `SmakCMakeInterp.pm`; the second uses `SmakCMake.pm`.
They share the same downstream code path — SmakCMakeInterp produces the same
`CMakeFiles/` metadata that cmake would, and SmakCMake reads that into smak's
internal rule tables.

## Quick start

### Option 1: Build a CMake project without cmake

```
cd /path/to/build-dir              # must be an empty dir alongside the source
perl -MSmakCMakeInterp -e '
    my $st = SmakCMakeInterp::interpret_project("/path/to/source", ".");
    SmakCMakeInterp::generate_makefiles($st);
'
smak -j4                           # or: smak src/libfoo.a, smak myexecutable
```

### Option 2: If you already have a CMakeFiles/ tree

Just run `smak` in a directory where cmake has previously run. SmakCMake
detects the `CMakeCache.txt` and `CMakeFiles/` automatically.

```
cd /path/to/cmake-build-dir
smak -j4
```

## What works today

Tested projects:
- **Trilinos** (cmake-generated metadata) — 48 libraries from clean
- **Xyce** (CMakeLists.txt interpretation) — libXyceLib.a + Xyce executable,
  zero undefined references, binary runs and reports version

## How SmakCMakeInterp works

When you call `interpret_project`, it:

1. Parses `CMakeLists.txt` — lexer handles bracket/quoted/unquoted args,
   variable references `${VAR}`, `$ENV{VAR}`, `$CACHE{VAR}`, and comments
   (line and bracket `#[[...]]`).
2. Evaluates CMake commands: `set`, `if/elseif/else/endif`, `foreach`,
   `while`, `function`/`macro` definitions, `include`, `add_subdirectory`,
   `add_library`, `add_executable`, `target_*`, `list()`, `string()`,
   `file()`, `configure_file()`, `find_package()`, etc.
3. Handles generator expressions `$<...>` — `BUILD_INTERFACE`,
   `INSTALL_INTERFACE`, `CONFIG`, `CXX_COMPILER_ID`, `IF`, `AND`/`OR`/`NOT`,
   `STREQUAL`.
4. `find_package(Pkg CONFIG)` searches standard install locations for
   `<Pkg>Config.cmake` and loads it. `find_package(Pkg)` tries
   `Find<Pkg>.cmake` in `CMAKE_MODULE_PATH` and falls back to built-in
   handlers for common packages (Threads, MPI, Python, BISON, FLEX, GTest,
   FFTW, CURL, Boost, OpenMP, Git, Doxygen).
5. Honors PUBLIC/PRIVATE/INTERFACE semantics on `target_*` commands so
   INTERFACE properties propagate correctly through `target_link_libraries`.
6. Runs `add_custom_command` / `bison_target` / `flex_target` immediately
   when their outputs are missing or stale, so generated source files
   exist before compilation.

`generate_makefiles` then writes:
- `CMakeCache.txt` — minimal, for SmakCMake's detection
- `CMakeFiles/Makefile2` — inter-target dependency graph
- `<binary_dir>/CMakeFiles/<target>.dir/flags.make` — compiler flags
- `<binary_dir>/CMakeFiles/<target>.dir/DependInfo.cmake` — source→object
  mapping per language
- `<binary_dir>/CMakeFiles/<target>.dir/link.txt` — full link command
  with resolved library paths and `-Wl,--start-group/--end-group` for
  static libs

## What isn't supported

- `install()`, `export()`, `add_test()` — parsed as no-ops. If you need
  to build, this is fine; installation/testing go through cmake.
- Generator-time configuration (multi-config builds). SmakCMakeInterp
  assumes `Release`.
- `ExternalProject_Add`, `FetchContent_*` — not implemented.
- Cross-compilation toolchains.
- TriBITS macros (Trilinos-specific). Trilinos itself builds fine through
  Option 2, because the cmake-generated Makefiles have the TriBITS output
  already resolved.

## Debug mode

Set `SMAK_CMAKE_DEBUG=1` to see every `include()`, `find_package()`, and
unknown-command invocation.

## Files

| File | Role |
|------|------|
| `SmakCMake.pm` | Reads existing `CMakeFiles/` metadata into smak's rule tables. Used automatically when `CMakeCache.txt` exists. |
| `SmakCMakeInterp.pm` | Parses + evaluates CMakeLists.txt, produces the `CMakeFiles/` tree. Run explicitly via `interpret_project` + `generate_makefiles`. |
| `smak-cmake.pl` | Wrapper that invokes the bundled CMake (`cmake-install/`) if it's available, else prompts to download. The `smak/cmake` symlink points here so generated Makefiles that call `$(CMAKE_COMMAND)` go through smak's managed cmake install. |
