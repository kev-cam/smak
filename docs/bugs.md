# smak bug list

Tracked smak issues. Each entry: short title, symptom, where it surfaces, current
hypothesis. Tick off (replace `- [ ]` with `- [x]`) when fixed.

## Open

### Job-server startup race
- [ ] **Symptom:** `smak: Job-master connection lost during worker startup`
- **Surfaces in:** test_dryrun, test_command_prefixes, test_objext_expansion,
  test_echo, test_modify, test_timeout. Mostly the Sequential/Cache mode of
  the regression matrix. Failure rate is non-deterministic; the same test
  passes in other modes of the same run.
- **Hypothesis:** Worker fork/exec races the master accept(); the master
  closes the listen socket before the worker connects, or the connect()
  syscall hits the closed socket. Could be sigchld handling.
- **Repro:** `cd test && ./run-regression -j 8 --filter dryrun`

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

### test_ssh_localhost fails when passwordless SSH unavailable
- [ ] **Symptom:** `SKIP: SSH to localhost not configured`
- **Status:** Environmental, not a smak bug. Test should detect missing
  passwordless SSH and SKIP rather than FAIL.
- **Fix:** Test driver, not smak core.

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
