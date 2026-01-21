# SMAK Implementation Notes

## Architecture Overview

SMAK is a parallel make replacement with a job-server architecture:

1. **Parent Process**: Parses Makefiles, expands dependencies, submits jobs
2. **Job Master**: Manages job queue, tracks task completion, dispatches to workers
3. **Workers**: Execute commands, report results back to job master
4. **Child SMAK Processes**: For recursive builds (`smak -C dir`), relay expanded rules back to parent job-server via `SMAK_JOB_SERVER` environment variable

## Key Data Structures

### `%in_progress` Hash
- Tracks which targets are being built
- **Key format**: `"$dir\t$target"` (directory-qualified to avoid collisions)
- Values: "queued", "running", or exit code

### `%visited` Hash
- Tracks which targets have been visited during dependency expansion
- **Key format**: `"$cwd\t$target"` (directory-qualified)

### `$job_server_socket`
- Socket connection from parent to job-master
- When set, indicates we're running in parallel mode with job server

### `SMAK_JOB_SERVER` Environment Variable
- Format: `host:port`
- Allows child smak processes to connect back to parent job-server

## Recent Fixes

### 2026-01-21: Compound Command Handling

**Problem**: Compound commands (`cmd1 && cmd2 && ...`) were being handled in-process even when a job server was running, which broke parallel builds.

**Fix**: Changed the compound handler check at line 4830 from:
```perl
if ($clean_cmd =~ /&&/) {
```
to:
```perl
if (!$job_server_socket && $clean_cmd =~ /&&/) {
```

This ensures the job-server handles compound commands in parallel mode.

### 2026-01-21: Directory-Qualified In-Progress Keys

**Problem**: Same target name in different directories (e.g., multiple "all" targets) caused collisions in `%in_progress` hash.

**Fix**: Changed key format in `submit_job` (around line 438) to use `"$dir\t$target"` instead of just `$target`.

### 2026-01-21: Dry-Run Command Printing

**Problem**: In sequential mode during dry-run, subdirectory commands weren't being printed.

**Fix**: Removed `|| $dry_run_mode` from the print condition at line 5125:
```perl
# Changed from:
unless ($silent_mode || $silent || $dry_run_mode) {
# To:
unless ($silent_mode || $silent) {
```

### 2026-01-21: Perl Exec Warning

**Problem**: Worker process showed "Statement unlikely to be reached" warning for code after exec().

**Fix**: Wrapped exec in `{ no warnings 'exec'; ... }` in SmakWorker.pm line 137.

## Testing

### Regression Tests
Run: `perl /usr/local/src/smak/regression-tests.pl`

### Known Failing Tests (Pre-existing)
- `test_autorescan` - Fails in pass mode
- `test_command_prefixes` - Fails all modes
- `test_objext_expansion` - Fails all modes
- `test_phony_repeat` - Fails in parallel modes
- `test_projects` - Fails all modes
- `test_ssh_localhost` - Requires SSH setup
- `test-default-target` - Fails in cache modes

### Build Test Commands
```bash
# Clear cache before testing
rm -f /tmp/dkc/smak/*/state.cache

# Sequential build
smak -C /usr/local/src/iverilog/

# Parallel build with 4 workers
smak -C /usr/local/src/iverilog/ -j4

# Dry-run
smak -C /usr/local/src/iverilog/ -n
```

## Multi-Output Pattern Rules (Compound Targets)

When a pattern rule produces multiple outputs (e.g., `parse%cc parse%h: parse%y`), SMAK uses a "compound target" strategy:

1. **Compound Target Creation**: When targets like `parse.cc` and `parse.h` both match the same pattern rule, create a compound target `parse.cc&parse.h` that holds the actual build command (e.g., `bison ...`).

2. **Layer Strategy**:
   - The compound target `x&y` is placed in layer N with the actual build command
   - Individual targets `x` and `y` are placed in layer N+1 as placeholder targets that depend on the compound
   - This ensures the build command runs once, and components wait for it

3. **Post-Build Completion**: When the compound target completes successfully:
   - A post-build operation marks individual components (`x`, `y`) as done
   - The post-build can be `touch x y` (a built-in command)
   - This removes the individual targets from the build queue

4. **Verification**: The `verify_target_exists` function handles compound targets by splitting on `&` and verifying each component file exists.

**Example**:
```
# Pattern rule in Makefile
parse%cc parse%h: parse%y
    bison -o parse.cc --defines=parse.h parse.y

# Results in:
# Layer 1: parse.cc&parse.h (runs bison)
# Layer 2: parse.cc, parse.h (placeholders, marked done when compound completes)
```

## Dry-Run Mode (`smak -n`)

### Expected Behavior
`smak -n` should produce similar output to `make -n`:
- Show all commands that would be executed
- Expand pattern rules to actual commands
- Recurse into subdirectories and show their commands
- Print commands in build order (dependencies before dependents)

### Architecture

1. **Forked Child Execution**: Dry-run is executed as a forked child of the job-server
   - This prevents polluting the actual job-server's state/data
   - The child follows the same code path as a regular `-j1` build

2. **Dry Workers**: Uses `smak-worker-dry` instead of `smak-worker`
   - Dry workers print commands instead of executing them
   - They do NOT touch the filesystem

3. **Rule Discovery**: As the dry-run traverses dependencies:
   - It discovers all rules that would be executed
   - Rules are passed back to the actual job-server
   - The job-server can display them with `btree` (build tree)

4. **Recursive Handling**: When encountering `smak -C dir target`:
   - Add `-n` flag to the recursive call
   - Recurse and collect all sub-commands
   - Print them in order

### Code Flow

```
smak -n
  └─> job-server forks child
       └─> child runs build with dry_run_mode=1
            └─> uses dry-workers (print, don't execute)
            └─> sends discovered rules to parent job-server
       └─> parent displays btree
```

### Key Variables
- `$dry_run_mode`: Set to 1 when `-n` flag is passed
- Worker script: `smak-worker-dry` (vs `smak-worker` for real builds)

## Open Issues

1. Parallel build may execute wrong targets (install targets instead of build targets)
2. Some regression tests still failing
3. Need to implement proper layer-based compound target handling
4. Dry-run mode needs to fully expand and print all commands like make -n
