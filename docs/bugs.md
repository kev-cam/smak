# smak bug list

Tracked smak issues. Each entry: short title, symptom, where it surfaces, current
hypothesis. Tick off (replace `- [ ]` with `- [x]`) when fixed.

## Open

<!-- Entries below marked "smak-buildtest" were found by building GitHub
     projects in containers (buildtest/README.md), 2026-09-27, Ubuntu 24.04. -->

### Recursive `$(shell ...)` variable in a prerequisite: rebuild every time / dep `'`
- [x] **FIXED (2026-09-27):** `needs_rebuild` now expands prerequisites with
  `expand_vars(format_output(...))` like `build_target`. The job-master's
  `$MV`-only loops call the new `expand_dep_text`, which runs `expand_vars`
  when a function call is left. Test: `test/test_shell_var_prereq.sh`.
- **Symptom (smak-buildtest, dnsmasq):** a second sequential `smak` recompiled
  all 43 objects. `smak -jN` on the sub-make failed with
  `Job 'x.o' FAILED: dependency ''' cannot be built`.
- **Cause:** dnsmasq names its flags stamp
  `copts_conf = .copts_$(sum)` with
  `sum?=$(shell echo ... | ( md5sum 2>/dev/null || md5 ) | cut -f 1 -d ' ')`.
  `needs_rebuild` and the job-master replaced only `$MV{VAR}` references, then
  split the unexpanded `$(shell ...)` text on spaces into words like `'`.
  `:=` variables were not affected.

### Implicit-rule source ignored when the target has recipe-less prerequisites
- [x] **FIXED (2026-09-27):** `needs_rebuild` adds the source of the suffix or
  pattern rule that builds the target (`implicit_rule_prereqs`). The
  job-master puts the suffix-rule source first so it becomes `$<`. Test:
  `test/test_implicit_source_stale.sh`.
- **Symptom:** with `a.o: a.h` plus `.c.o:` or `%.o: %.c`, touching `a.c` did
  not rebuild `a.o`, sequentially or with `-j`. Under `-j` with the suffix rule
  the recipe ran `cc -c a.h`, creating `a.h.gch` and failing. GNU make treats
  `a.c` as a prerequisite and as `$<`. dnsmasq has this shape
  (`$(objs): $(copts_conf) $(hdrs)` plus `.c.o:`).

### Command-line variables not passed to sub-makes (dnsmasq `COPTS` lost)
- [x] **FIXED (2026-09-27):** smak.pl now reads inherited variables from the
  `MAKEFLAGS` part after `--` and exports all command-line variables there in
  GNU make's format (`-- VAR=val\ with\ spaces`). The sub-make's own
  arguments still win, and it interoperates with GNU make either way. Test:
  `test/test_cmdline_var_submake.sh`.
- **Symptom (smak-buildtest, dnsmasq-full):**
  `smak COPTS='-DHAVE_DNSSEC -DHAVE_DBUS ...'` compiled every object without
  those `-D` flags and linked without their libraries. It exited 0 with a
  binary lacking the requested features. This always happened under `-j`, and
  sequentially whenever the sub-make ran through the shell, as dnsmasq's
  backtick `build_cflags` makes it. With the fix the binary is byte-identical
  to make's.

### smak-attach dies when TERM is unset
- [x] **FIXED (2026-09-27):** default `TERM=dumb` before `Term::ReadLine->new`.
- **Symptom:** in containers, cron or CI, `smak-attach -pid N` died with
  `TERM not set at .../Term/Cap.pm` before connecting. `smak -cli` was fine.

### smak-attach: bare `build` does not build the default goal
- [x] **FIXED (2026-09-28):** the attached CLI asks the job server
  (`DEFAULT_TARGET`) when it has no parsed makefile. Test:
  `test/test_server_reuse.sh`.
- **Symptom (smak-buildtest, every project):** in `smak-attach`, `build` with
  no target printed `No default target found.` and exited 0.

### `reconnect` rc option is a no-op; detached servers pile up
- [x] **FIXED (2026-09-28):** with `set reconnect = 1`, start_job_server
  connects to the server named by `.smak.connect` instead of forking a new
  one, and detaches from it afterwards rather than shutting it down. A server
  serving a later client (reconnect or `smak-attach`) forwards its own output
  to that client, and a detached server drops the stdio of the session that
  started it, so `$(smak -cli ...)` captures no longer hang. Test:
  `test/test_server_reuse.sh`.
- **Symptom:** the old master port was stored but never used, so every
  `smak -cli` started another job server and each `detach` left one more.
- **Also fixed:** a job-master shutting down normally left `.smak.connect`
  pointing at its deleted port file (regression runs left one in
  `projects/nvc`); it now removes the link if it still points at itself, and
  a starting job server deletes port files of job-masters that are gone.

### Only `Makefile` is searched, not `GNUmakefile` / `makefile`
- [x] **FIXED (2026-09-28):** GNU make's order `GNUmakefile`, `makefile`,
  `Makefile`, also for `-C` sub-makes. Test: `test/test_gnu_make_compat.sh`.
- **Symptom (smak-buildtest, lua):** `Cannot open Makefile`.

### GNU make options smak rejects: `--no-print-directory`
- [x] **FIXED (2026-09-28):** `-w`, `--print-directory`,
  `--no-print-directory`, `-r`, `-R`, `--warn-undefined-variables`,
  `--no-silent`, `-l`, `-O` and `--jobserver-auth` are accepted and ignored;
  `--no-keep-going`/`--stop` turn `-k` off. (No `-S`: Getopt::Long is
  case-insensitive, so it would shadow `-s`.) Test: `test/test_gnu_make_compat.sh`.
- **Symptom (smak-buildtest, lz4):** `Unknown option: no-print-directory`.

### `+` recipe prefix not stripped
- [x] **FIXED (2026-09-28):** `+` is stripped wherever `@` and `-` are, and
  `+@`/`-+@` lines count as silent. Test: `test/test_gnu_make_compat.sh`.
- **Symptom (smak-buildtest, redis, zstd):** `+@cmd` ran literally; sequential
  exited 0 having built nothing, `-j` failed with `Cannot exec '+@...'`.

### Inline recipe `target: ; command` is ignored
- [x] **FIXED (2026-09-28):** text after the first `;` outside `$(...)` and
  quotes is the first recipe line (`split_inline_recipe`); target-specific
  variable lines are left alone. Test: `test/test_gnu_make_compat.sh`.

### `VAR != command` shell assignment yields an empty value
- [x] **FIXED (2026-09-28):** `!=` runs the expanded command and assigns its
  output (newlines to spaces); `::=` is treated as `:=`. Test:
  `test/test_gnu_make_compat.sh`. Remaining difference: GNU make re-expands a
  bare `$X` in the result (`$HOME` -> `$H` + `OME`); smak leaves one-letter
  `$X` references in values alone.

### Recipe output of `-C` sub-makes is lost under `-j`
- [x] **FIXED (2026-09-28):** three causes. The job-master's builtin `echo`
  returned "not handled" for text with shell metacharacters and the caller
  treated that as success, so the command never ran; declined builtins now
  go to a worker. `stop_job_server` took the first queued line as the
  shutdown ack and dropped `OUTPUT` lines still in flight; it now reads until
  `SHUTDOWN_ACK`. And the client dropped all `OUTPUT` under `-s`, which only
  means "don't echo commands". Tests: `test/test_gnu_make_compat.sh`,
  `test/test_recipe_shell_semantics.sh`.
- **Also fixed:** the `-j` builtin path split recipe lines on `;`/`&&` inside
  quotes (`echo "a;b"`), ran later parts inline before earlier dispatched
  ones, and turned line breaks into `;` (so a failing line no longer stopped
  the recipe); the progress-spinner clear (`\r  \r`) was written even when
  stderr is not a terminal, garbling logs.

### `smak -j4` hangs after a failed job (jq)
- [x] **FIXED (2026-09-28):**
  1. `if ...; then ...; fi | sed > $@` lines are kept whole (shell keywords);
     the worker's builtins decline anything with shell syntax (its `mkdir`
     had created a directory named `src && if test -x .`), `rm` expands globs,
     `mkdir`/`touch` take several arguments.
  2. The layered scheduler waited for a running job that was itself a
     recursive `$(MAKE)` wrapped in shell (automake `all-recursive`), while
     that job waited for the jobs its child smak submitted. Jobs that run a
     sub-make no longer hold back later layers (`runs_sub_make`).
  3. Lines that set or use shell variables (automake depcomp
     `depbase=...; ... $depbase.Tpo && mv $depbase.Tpo ...`) are no longer
     split on `&&` for the worker, and the depbase rewrite only applies to
     automake's exact form.
  4. A recipe that does not create its target (e.g. `inner:` writing
     `inner.txt`) no longer fails with "output file not found".
  jq now builds with `smak -j4` and a following `make` finds nothing to do.
  Test: `test/test_recipe_shell_semantics.sh`.

### `-j`: subdir objects of a non-recursive makefile compiled in the wrong directory
- [x] **FIXED (2026-09-28):** the real cause was `${LIBOBJDIR}x.o` from
  `LIBOBJS`: the job-master expanded only `$(...)` in dependency words, so the
  brace form stayed literal, the target matched no makefile rule and the
  builtin `%.o: %.c` rule (without tmux's `-I.`) was used. `expand_dep_text`
  now expands `${VAR}` too. tmux builds with `smak -j4`.

### Server (CLI) mode splits automake's multi-line compile recipe
- [x] **FIXED (2026-09-28):** same fix as item 3 of the jq entry above.

### End-of-line comments kept in variable values; `$?` unsupported (lua)
- [x] **FIXED (2026-09-28):** found by smak-buildtest on lua.
  - `X = a # comment` kept `# comment` in the value (only whole-line
    comments were skipped); `\#` was not unescaped. Non-recipe lines now
    lose everything from the first unescaped `#` (`strip_make_comment`).
  - Outside recipes, backslash-newline and the surrounding whitespace now
    collapse to one space (lua's `CWARNSCPP= \ <tab>-Wa \ ... # comment`
    passed `#` and tabs to gcc: "#: linker input file not found").
  - `$?` (prerequisites newer than the target) was passed to the shell,
    which expanded it to the last exit status (`ar rc liblua.a 0`). It is now
    an automatic variable; under -j, where recipes are expanded when queued,
    it also includes prerequisites still being built.
  - The "phony target 'all' exists as a file" warning (GNU make says
    nothing) only shows with SMAK_DEBUG / -v.
  Tests: `test/test_gnu_make_compat.sh`.

### Parse cache reused after smak itself changed
- [x] **FIXED (2026-09-28):** the state cache was validated only against the
  makefiles' mtime/size and a hand-bumped `CACHE_VERSION`, so a newer smak
  loaded rules parsed by an older one (seen as a deadlock on an inline-recipe
  makefile first parsed by the old parser). The cache version is now
  `CACHE_VERSION` plus the mtime/size of Smak.pm, SmakCMake.pm and
  SmakCMakeInterp.pm (`cache_signature`).

### VPATH-resolved `$<` gets a `./` prefix, so binaries differ from make's
- [ ] **Symptom (smak-buildtest, iverilog):** smak compiles
  `-c ./../libmisc/LineInfo.cc` where make uses `-c ../libmisc/LineInfo.cc`.
  The build works, but `__FILE__` strings and debug info differ, so `ivl`,
  `ivlpp` and `driver/iverilog` are not byte-identical to make's.

### CMake metadata mode: link commands run from the wrong directory
- [x] **FIXED (2026-09-28):** SmakCMake runs each `link.txt` line as
  `cd <target binary dir> && ...` (replacing regex path rewriting that missed
  `../libz.a`), parses every Makefile2 target dependency including top-level
  `CMakeFiles/x.dir/all` and names with `-`/`.`, and appends the
  `cmake -E cmake_symlink_library` step from build.make as `ln -sf`. zlib
  (cmake), cJSON and libuv build with smak and -j4, and `make` finds nothing
  left. Test: `test/test_cmake_link_dirs.sh`.
- [ ] **(original) Symptom (smak-buildtest, zlib-cmake, cJSON; cmake 3.28 Makefile
  generator):** every smak mode fails to link test executables with
  `/usr/bin/ld: cannot find ../libz.a` or `cannot find ../libcjson.so.1.7.19`.
  cmake's `link.txt` is written to run in the target's binary dir, e.g.
  `_build/test`, but smak runs it from the top build dir, so the relative
  library path points outside the tree. The same runs also show the open
  "links before its static-library dependency is archived" ordering problem:
  `undefined reference to cJSON_Delete`.
- **Hypothesis:** SmakCMake should set the job's `exec_dir` to the target's
  `CMakeFiles/<t>.dir/..` directory, as cmake's `build.make` does with
  `cd <dir> && ...`.

### `smak <goal>` with no rule for the goal exits 0 silently
- [x] **FIXED (2026-09-05):** `Smak::goal_has_rule` (Smak.pm) + a pre-build check
  in smak.pl over the command-line goals: a goal with no explicit rule (incl.
  variable-expanded keys like `$(EXE)$(EXEEXT)`), no matching pattern/suffix/
  built-in implicit rule, no VPATH hit and no file behind it now stops with
  `smak: *** No rule to make target 'X'.  Stop.` (non-zero). Dependencies keep
  the existing leniency (assumed to exist). Test: `test/test_no_rule_goal.sh`.
- **Symptom:** `smak nosuchtarget` and `smak -n nosuchtarget` printed nothing
  and exited 0 (GNU make: error, exit 2). Surfaced as `smak install` in a
  cmake-metadata build dir "succeeding" in 5 s having installed nothing
  (Trilinos 14.4 for Xyce).
- **Cause:** the job-master's queue path treats a target with no rule, no
  deps and no file as "assume it exists" (Smak.pm, `No rule for target ...
  assuming it exists`), which is meant for source-file dependencies but was
  applied to top-level goals too.

### SmakCMake (cmake-metadata mode): no `install` / `clean` / `test` targets
- [x] **FIXED (2026-09-05):** `generate_smak_rules` now synthesizes CMake's
  special targets from the metadata when `cmake_install.cmake` exists:
  `install` (deps `all`), `install/fast`, `install/local`, `install/strip`,
  `preinstall`, `test` (ctest, if found next to cmake) and `clean` (rm of all
  known objects/outputs). Verified: `smak install` installed Trilinos 14.4
  (48 libs, 3257 headers, TrilinosConfig.cmake) in 65 s. Test:
  `test/test_cmake_special_targets.pl`.
- **Symptom:** SmakCMake only generated per-target compile/link rules and
  `all`; the top-level Makefile's `install: preinstall ; cmake -P
  cmake_install.cmake` was never read, and (bug above) the missing goal was
  silently accepted.

### CMake interp: linked executables/shared libs get no build-tree RPATH
- [x] **FIXED (2026-09-28):** executables and shared libraries that link
  in-project shared libraries get `-Wl,-rpath,<their build dirs>` unless
  CMAKE_SKIP_BUILD_RPATH / CMAKE_SKIP_RPATH is set. The interpreter also
  honors OUTPUT_NAME, VERSION and SOVERSION (real file, soname, symlinks)
  instead of always writing lib<target>.so. Test:
  `test/test_cmake_link_dirs.sh` (interp cases).
- [ ] **(original) Symptom (2026-09-05, Xyce 7.11 via `smak -cmake`, BUILD_SHARED_LIBS=ON):**
  `src/Xyce` links fine but fails to start: `libXyceLib.so: cannot open shared
  object file`. The generated link.txt has no `-Wl,-rpath,<build dirs>`; real
  cmake adds the build-tree RPATH by default (CMAKE_SKIP_BUILD_RPATH=OFF) and
  only strips it at install time. Workaround: LD_LIBRARY_PATH wrapper
  (`~/tools/xyce/bin/Xyce`).
- **Hypothesis:** the link-command generator in SmakCMakeInterp should append
  `-Wl,-rpath,<dir>` for every in-project shared library the target links
  (plus CMAKE_INSTALL_RPATH / `$ORIGIN` entries when set), unless
  CMAKE_SKIP_BUILD_RPATH is ON.

### CMake interp: install/packaging commands report errors that are not errors
- [ ] **Symptom (2026-09-05, Xyce 7.11 CMakeLists via `smak -cmake`):** the
  interpreter prints `CMake Error: Bad COMPATIBILITY value used for
  WRITE_BASIC_CONFIG_VERSION_FILE(): "AnyNewerVersion"`, `No VERSION specified
  for WRITE_BASIC_CONFIG_VERSION_FILE()`, `INSTALL_PREFIX must be an absolute
  path` and `CPack welcome resource file ... could not be found`, yet exits 0
  and generates a complete build (147 targets). Real cmake accepts all of
  these. Cosmetic for building (install/export/CPack are documented no-ops)
  but alarming; `write_basic_package_version_file` should accept
  `AnyNewerVersion|SameMajorVersion|SameMinorVersion|ExactVersion` and take
  VERSION from `PROJECT_VERSION`, and CPack `include(CPack)` should be a quiet
  no-op.
- **Also:** `Argument "CMAKE_PROJECT_VERSION_MAJOR" isn't numeric in numeric
  ge (>=) at SmakCMakeInterp.pm line 756` x4 — same class as the open
  `EQUAL` entry below (unset/unexpanded operand in a numeric comparison);
  `GREATER_EQUAL` needs the same treatment.


### CMake interp: `if(X EQUAL Y)` warns on non-numeric operands; `-D` define not honored
- [ ] **Symptom (2026-06-17):** `smak -cmake ../yosys -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=ON -DYOSYS_WITHOUT_ABC=ON` on yosys 0.66 produced no
  CMakeCache/Makefile. Emits `Argument "git_result" isn't numeric in numeric eq
  (==) at SmakCMakeInterp.pm line 752`, and still tripped yosys's `abc is not
  configured as a git submodule` check *despite* `-DYOSYS_WITHOUT_ABC=ON`.
- **Where:** `SmakCMakeInterp.pm:752` — the `EQUAL` predicate evaluates a Perl
  numeric `==` on the dereferenced operands. yosys compares a git-describe result
  variable that is unset/"UNKNOWN" against a number; real CMake handles a
  non-numeric `EQUAL` operand gracefully (no error), Perl warns and coerces to 0,
  giving the wrong branch. Separately the `-DYOSYS_WITHOUT_ABC=ON` command-line
  define did not reach the `if(NOT YOSYS_WITHOUT_ABC)` branch (option default
  still in effect).
- **Workaround used:** smak's bundled real cmake
  (`/usr/local/share/smak/cmake-3.31.4-linux-x86_64/bin/cmake`) configured +
  built yosys cleanly (rc=0). This is the shim's intended `SMAK_CMAKE_REAL`
  fallback path.
- **Hypothesis:** (1) `EQUAL`/`LESS`/`GREATER` should detect non-numeric operands
  and follow CMake semantics (string/zero, no Perl numeric warning); (2) `-D<var>`
  command-line defines must be seeded into the variable/cache scope *before* the
  `if()` conditions referencing them are evaluated.

### nvc build: generated VHDL bootstrap libraries left incomplete
- [x] **VERIFIED FIXED (2026-06-06):** `cd /usr/local/src/nvc-build && rm -rf lib
  && smak -j16` now produces the COMPLETE lib (all `lib/std` packages incl.
  STANDARD-body/TEXTIO, `ieee.08` NUMERIC_STD, `sv2vhdl` SV_DISPLAY_PKG, all
  std/ieee/nvc .08/.19 variants) and `run_regr wait1` -> ok, with smak alone (no
  `make -k` fallback). The relay dispatch (Smak.pm ~13987-14074) now collects all
  chained recursive makes (`for $k ($i..$#cmd_parts)`) and forks each descent;
  the generated-tool chain (libs built by running the just-built `bin/nvc`) is
  driven to completion. Reproduced clean in 5 synthetic shapes too. Left checked
  here for history.
- [ ] **(original) Symptom:** `smak -j16` in an autotools `nvc` out-of-tree build links
  `bin/nvc` correctly, but the VHDL support libraries under `lib/` are
  truncated: `lib/std/` holds only `STD.STANDARD` (no `STD.STANDARD-body`,
  no `STD.TEXTIO`, no `STD.ENV`), and `lib/ieee`, `lib/ieee.08`, `lib/nvc`
  are left completely empty. `run_regr wait1` then dies with
  `** Fatal: (init): missing body for package STD.STANDARD`.
- **Surfaces in:** building `/usr/local/src/nvc` into `/usr/local/src/nvc-build`
  (sv2ghdl SV-Test regression bring-up, 2026-06-01).
- **Hypothesis:** These libraries are *generated by running the freshly-built
  `nvc` binary* to analyse `../nvc/lib/{std,ieee,...}/*.vhd` — a bootstrap
  (generated-tool) dependency. smak's recursive/relay layer doesn't drive
  that chain to completion: it appears to stop after the first package of the
  first library, so the tool-built artifacts that later targets depend on are
  missing/out-of-order. Related to how the relay captures targets whose recipe
  invokes a just-built binary rather than the compiler.
- **Workaround:** plain `make -j16` builds the std-93 + ieee-93 + nvc libs so
  `run_regr wait1` → `ok`, but a *single* make after smak still leaves the
  higher-std variants incomplete (`lib/ieee.08`/`lib/ieee.19` missing
  NUMERIC_STD, `lib/sv2vhdl` missing SV_DISPLAY_PKG) because smak's partial lib
  files look up-to-date by timestamp. To force a complete set: `rm -rf lib &&
  make -k -j16`. NOTE this also surfaced a genuine missing dep — `python3-dev`
  (`Python.h`) is required to build `lib/sv2vhdl/libresolver.so` (the federation
  resolver); without it a from-scratch `make` aborts (exit 2) before finishing
  the VHDL libs, hence the `-k`. With `python3-dev` installed a plain `make`
  completes everything.
- **Repro:** `cd /usr/local/src/nvc-build && rm -rf lib && smak -j16 && ls lib/ieee.08 | grep NUMERIC_STD`

### Recursive sub-make descent left incomplete (iverilog subdirs)
- [x] **VERIFIED FIXED (2026-06-06):** removed the subdir final artifacts
  (`vpi/*.vpi tgt-*/*.tgt`) in a fully-configured `/usr/local/src/iverilog` and
  re-ran `smak -j16`: all descents rebuilt (vpi x7 + tgt-vvp/vhdl/null/stub x1),
  exit 0. The `$(foreach dir,$(SUBDIRS),$(MAKE) -C $(dir) all && ) true` chain
  (Makefile:134) is now fully dispatched. Same root fix as the nvc entry above.
- [ ] **(original) Symptom:** `smak -j16` in `/usr/local/src/iverilog` builds the top-level
  binaries (`ivl`, `ivlpp`, `vhdlpp`, `vvp`, `driver/iverilog`) and exits 0, but
  several recursive subdirectory builds never run: `vpi/*.vpi` (system.vpi,
  va_math.vpi, …) and the code-generator targets `tgt-vvp/vvp.tgt`,
  `tgt-vhdl/vhdl.tgt`, `tgt-null/null.tgt`, etc. are missing. `smak -n` afterwards
  still lists `smak -C vpi all && smak -C tgt-vvp all && …` as pending — i.e. the
  relayed child makes for those dirs were skipped, not executed. iverilog is
  unusable without tgt-vvp.
- **Surfaces in:** building `/usr/local/src/iverilog` (sv2ghdl SV-Test bring-up,
  2026-06-01). Same root area as the nvc bug above and "Built-ins not used in some
  parallel modes" — the recursive-make relay layer.
- **Hypothesis:** the top-level rule chains many `smak -C <dir> all` via `&&`;
  the relay captures/launches the first few (ivlpp/vhdlpp/vvp did build) but the
  later descents (vpi, tgt-*) are dropped, and the parent still reports success.
- **Workaround:** plain `make -j16` in the same tree builds vpi/*.vpi and all
  tgt-*/*.tgt; no errors.
- **Repro:** `cd /usr/local/src/iverilog && make distclean; ./configure && smak -j16 && ls vpi/*.vpi tgt-vvp/*.tgt`

### Relay double-prefixes paths at 2-level nesting (recursive-make dependency target)
- [x] **FIXED (2026-06-07):** the relay child (smak.pl, ~line 1128) submitted
  each captured target by its key (relative to the child's cwd) paired with the
  recipe's `exec_dir`, but the job-server qualifies a job as `exec_dir/target`.
  At depth >=2 the key carried a sub-make dir prefix that `exec_dir` already
  contained -> double. Fix: before SUBMIT_JOB, re-express target/deps/siblings
  *relative to exec_dir* via `File::Spec->abs2rel(rel2abs($key,$cwd),$exec_dir)`
  -- a no-op for the correct single-level case, collapses the redundant prefix
  at depth >=2. (make.pl is a symlink to smak.pl, so covered.) Verified:
  test_nested_make passes in parallel (re-enabled +x); the doubled path is gone;
  and NO regression -- smakcomb 9/9, 12-dir chain 12/12, nvc lib bootstrap
  (run_regr wait1 ok), iverilog vpi+tgt descents all rebuild via smak -j16.
- [ ] **(original) Symptom (found 2026-06-06):** under `-j`, a 2-level nested build where a
  recursive make is the recipe of a *dependency target* HANGS. Top `app:
  lib/lib.a` with `lib/lib.a:` -> `$(MAKE) -C lib all`, and lib's `lib.a:` ->
  `$(MAKE) -C src all`. The job-server relay accumulates the subdir prefix
  twice for the grandchild: it queues `lib/src/src/util.o` (doubled `src/src`)
  whose dep `lib/src/src/util.c` never exists, so it's deferred forever ->
  "Waiting for layer 1 to drain (... 1 deferred)" -> hang until parent dies.
- **Surfaces in:** test_nested_make in parallel modes (was hidden -- the test
  file lacked +x so the suite skipped it; chmod'ing it exposed this). 1-level
  nesting and chained `make -C a && make -C b` are fine (verified); nvc/iverilog
  build fine. Specific to recursive-make-as-dependency-target at depth >=2.
- **Root area:** the relay child's target-path prefix accumulation across nested
  child relays (NOT the in-process merge at ~Smak.pm:911-928, which is correct
  for one level). `target_with_prefix` is applied with an already-prefixed
  target. Cf. the original "double path prefix" gotcha.
- **Repro:** `mkdir -p t/lib/src; cd t; <build the 3 Makefiles above>; smak -j4 all`
  -> hangs; `smak all` (sequential) works.
- **Status:** FIXED (above) -- test_nested_make re-enabled (+x) and passing.
  test_dnsmasq stays non-executable pending the exit-77 harness fix below.

### test_dnsmasq exit 77 (skip) miscounted as failure
- [x] **FIXED (2026-09-28):** run-regression reports exit 77 from the first
  mode as SKIP and does not run or score the other modes; test_dnsmasq is
  executable again (it skips when /usr/local/src/dnsmasq is absent).
- [ ] **(original) Symptom:** with +x, test_dnsmasq exits 77 ("SKIP: dnsmasq dir not found")
  but run-regression scores any non-0/non-124 mode exit as FAIL, so it shows as
  failed. **Fix:** honor exit 77 as skip in the per-mode scoring (all 6 mode
  checks in run-regression). Left non-executable for now.

### Job-server startup race
- [x] **FIXED (2026-09-28):** the job-master created its port file and then
  wrote the ports, and the client started reading as soon as the file
  existed, so it could see an empty or partial file ("Cannot connect to
  job-master: Connection refused"). Stale port files from earlier servers
  with a reused PID were also accepted. The file is now written to `.tmp` and
  renamed, carries a per-start token the client checks, the client retries
  the connect briefly, and it kills the job-master it forked if it gives up
  (an orphaned server held the caller's stdout open, hanging `$(...)`).
  Stress test: 0 failures in 40 starts (was ~1 in 10).
- [ ] **(original) Symptom:** `smak: Job-master connection lost during worker startup`
- **Surfaces in:** test_dryrun, test_command_prefixes, test_objext_expansion,
  test_echo, test_modify, test_timeout. Mostly the Sequential/Cache mode of
  the regression matrix. Failure rate is non-deterministic; the same test
  passes in other modes of the same run.
- **Hypothesis:** Worker fork/exec races the master accept(); the master
  closes the listen socket before the worker connects, or the connect()
  syscall hits the closed socket. Could be sigchld handling.
- **Repro:** `cd test && ./run-regression -j 8 --filter dryrun`
- **Hardened (2026-06-06):** the *consequence* of all workers failing (the
  silent infinite hang) is fixed — the job-master now fails loudly with
  "no workers available" instead of spinning forever (see the
  test_ssh_localhost entry). The underlying non-deterministic race itself was
  not reproduced in the current suite (33->34/39 pass; the rest were the
  IO::Pty harness dep). Leaving open pending a confirmed repro.

### autorescan misses post-deletion rebuild
- [ ] **Symptom:** `FAIL: test_auto.o was not rebuilt after deletion`
- **Surfaces in:** test_autorescan
- **Hypothesis:** The autorescan loop computes need-rebuild from cached
  mtimes; when an output file is deleted, the next pass needs to detect the
  missing file as "stale" rather than only comparing timestamps.

### Built-ins not used in some parallel modes
- [ ] **Symptom:** `FAIL: Built-ins not used in parallel mode`
- **Surfaces in:** test_recursive_parallel
- **Hypothesis:** The dispatch path that recognizes builtin-fork-able
  commands (echo, cd, …) is bypassed in certain parallel/cache combinations.
  Probably related to the recursive-make relay layer's interaction with
  `is_builtin_command()` in the dispatch loop.

### Scanner misses events under load
- [ ] **Symptom:** `FAIL: Not all events detected` (CREATE / MODIFY / DELETE)
- **Surfaces in:** test_scanner
- **Hypothesis:** inotify event coalescing or read-buffer drain timing.
  Test creates+modifies+deletes in quick succession; scanner reports a
  subset of the events.

### test_ssh_localhost: SSH-worker mode broken on localhost
- [x] **FIXED (2026-06-06):** when passwordless SSH to localhost IS available,
  the test ran the real `smak --ssh=localhost` and it HUNG 30s (not the
  environmental skip). Two real smak bugs in `spawn_ssh_worker` / job-master
  startup:
  1. **Wrong remote worker path** — SSH spawn launched `~/.cache/smak/smak-worker`
     (never staged → exit 127). Localhost shares our filesystem, so it now runs
     the local `$bin_dir/smak-worker -cd <cwd>` directly (no ~/.cache, no sshfs).
  2. **Silent infinite hang on 0 workers** — when ALL workers fail to start,
     `num_workers` decremented to 0, the startup loop exited, and the job-master
     advanced to its listen loop and spun forever (`workers=0 queued=1`) on jobs
     it could never run. Now: if `@workers==0 && @worker_assignments>0` it sends
     `JOBSERVER_NO_WORKERS` and exits; the parent reports
     "no workers available -- all N worker(s) failed to start" instead of
     hanging. (General robustness — applies to any worker-start failure, not
     just SSH.) Verified: `smak --ssh=localhost -j2` builds (2/2 workers),
     test_ssh_localhost.sh -> SUCCESS.

### Executable links before its static-library dependency is archived
- [x] **FIXED (2026-09-28):** the exe->library edge was lost because
  SmakCMake's Makefile2 parser only matched targets with a directory prefix,
  so top-level library targets were never recorded as dependencies. Covered
  by `test/test_cmake_link_dirs.sh` (static and shared library, seq and -j4,
  metadata and interp modes).
- [ ] **(original) Symptom (found 2026-07-10, while testing the ar `rm -f` fix):** a clean
  build of a project with a static library + an executable that links it returns
  **exit 1**, even though both artifacts are built correctly. smak dispatches the
  exe's link rule *before* the static lib's archive rule has completed: the first
  link fails (`libX.a` doesn't exist yet), the archive then runs, the exe
  re-links and succeeds — but the failed first attempt's nonzero status leaks
  into the overall run exit code.
- **Surfaces in:** any CMake-interp project with `add_library(<n> STATIC …)` +
  `add_executable` + `target_link_libraries(app <n>)`. Deterministic at `-j1`
  (rc=1 every run); at `-j4` it can pass (rc=0) by timing luck when the archive
  finishes before the link is attempted. NOT caused by the `rm -f` archive fix —
  reproduced identically with old code (`git stash`) at `-j1`.
- **Hypothesis:** the exe→`lib.a` edge is added as an *order-only* dep
  (`SmakCMake::generate_smak_rules`, ~L386-397 "Add as order-only dep"), which
  doesn't force the archive recipe to fully complete before the exe link is
  dispatched on the first build. Real make orders the exe link strictly after
  `lib.a`'s recipe (a normal prerequisite, not order-only).
- **Workaround:** re-run smak (2nd invocation: `lib.a` exists → exe links clean,
  rc=0), or ignore rc=1 when the expected artifacts exist.
- **Repro:** `add_library(mylib STATIC a.cpp b.cpp); add_executable(app main.cpp);
  target_link_libraries(app mylib)` → interpret+generate → `smak -j1` → rc=1,
  `app` present.

### No-op rebuild does not complete on large trees (rule re-derivation each run)
- [ ] **Symptom (found 2026-07-10):** running smak on an already-built large
  CMake tree with nothing changed does not finish within 120–300s and recompiles
  nothing (`rc=124` timeout, 0 compiles). Xyce = 98 targets / ~462 objects.
- **Surfaces in:** `/usr/local/src/xyce-build` over the 9p `/mnt/c` Windows mount
  (WSL). Pre-existing — reproduced with AND without the `.d` header-dep feature
  (gap 4), so not caused by it.
- **Hypothesis:** every smak invocation re-derives all rules (`try_cmake_project`
  re-parses CMakeCache/Makefile2/DependInfo/flags.make/link.txt for all targets)
  and re-runs the full staleness pass with no caching between runs — O(targets ×
  deps) of `stat()`, pathological when `stat` is slow (9p mount). The `.d`
  header-dep feature adds ~49s of depfile reads on 9p (file-read bound;
  negligible on native ext4, and scoped to in-tree headers).
- **Workaround:** build on native ext4 (e.g. `/home/claude`), NOT the 9p
  `/mnt/c` mount — already the documented guidance. A persistent
  rules/staleness cache across invocations would be the real fix.
- **Repro:** `cd /usr/local/src/xyce-build` (fully built) `&& time smak -j8` →
  does not complete.

## Container deps (cross-distro)
Tests need these Perl/system packages installed:
- `perl-IO-Tty` (Tumbleweed) / `libio-pty-perl` (Debian/Ubuntu): for the
  PTY harness used by test_print, test_readline, test_nested, etc.
- `diffutils` (Tumbleweed): test_makecmp uses `diff` and `cmp`.
- `which` (Tumbleweed): nvc's autoconf macro uses `which llvm-config`.

## Recently fixed (kept for context)
- 2026-04-25 — Perl precedence warning at `Smak.pm:4487`
  (`! $x =~ /\.dat$/` → `$x !~ /\.dat$/`). Was contaminating test diff
  output and causing test_command_prefixes / test_suffix_rules /
  test_autorescan to spuriously fail.
- 2026-04-25 — "New master connecting / connected / ready" STDERR messages
  gated on `$ENV{SMAK_DEBUG}` (were breaking dry-run diffs in tests using
  `2>&1`).
- 2026-04-25 — Worker-drain `while (my $line = <$socket>)` loop wrapped in
  `no warnings 'closed'` so a mid-drain disconnect doesn't emit
  `readline() on closed filehandle` to STDERR.

## 2026-07-01 — Deadlock: 515 jobs queued, all workers ready, nothing running (accel .so build)

`regress run nvc/regr-accel` (dispatch via smak `-j12 -f run.mk`) deadlocks in
the intermittent check with `current_dispatch_layer=0, max_dispatch_layer=0`,
515 jobs queued at layer 0, 12 workers ready, but nothing dispatched. First
queued job is an nvc accel `.so` build whose recipe is a two-step shell:

    cd /home/claude && gen_statemachine <in.v> <top> <out.so> \
      && gcc -O2 -shared -fPIC -o <out.so> <out.so>_nvc.c

i.e. a large fan-out of independent same-layer leaf jobs (one per accel module),
each a `A && B` compound. smak enqueues all 515 but never dispatches — layer-0
jobs sit "ready" with idle workers. Reproduces every run; `regress` auto-detects
(`smak dispatcher exited rc=32512`) and falls back to `make -j12`, which
completes fine — so it's a smak dispatch-loop bug on a wide single-layer job set
with compound `&&` recipes, not a build-correctness issue. Same family as the
recursive/generated-build incompleteness already noted for nvc-accel/iverilog.

## Out-of-tree (VPATH) builds: core target-existence not VPATH-aware

Found building Verilator out-of-tree (configure run from a separate build dir,
`VPATH = $(srcdir)`).

1. **obj_dbg recursive-capture chdir** — FIXED (create -C subdir if missing during
   dry-run capture).
2. **missing-intermediate check ignored VPATH** — FIXED (resolve_vpath before
   deciding a dep is missing).
3. **core target build still ignores VPATH (OPEN)** — smak's normal
   existence/needs_rebuild checks test `-e "$dir/$target"` only. A prerequisite
   that lives on the VPATH (e.g. `configure`, up-to-date in `$(srcdir)`) is seen
   as absent and rebuilt — `config.status: configure` triggers `autoconf` in the
   build dir → "no input file" → build aborts. Fix needs resolve_vpath threaded
   through the target-existence + needs_rebuild path (and their timestamp reads),
   not just the missing-intermediate check.
4. **man-page tasks fail (OPEN)** — `help2man`/`pod2man` for verilator.1 etc.
   fail (exit 127 / exit 2) under smak's recipe-exec env though they succeed
   under make. Non-fatal to verilator_bin but aborts the default `all` goal.

Verilator itself builds fine with plain `make` out-of-tree; these are smak VPATH
gaps.
