# SMAK Implementation Notes

## Architecture Overview

SMAK is a parallel make replacement with a job-server architecture:

1. **Parent Process**: Parses Makefiles, expands dependencies, submits jobs
2. **Job Master**: Manages job queue, tracks task completion, dispatches to workers
3. **Workers**: Execute commands, report results back to job master
4. **Child SMAK Processes**: For recursive builds (`smak -C dir`), relay expanded rules back to parent job-server via `SMAK_JOB_SERVER` environment variable
5. ** Command Execution **: the job-server may refactor a build command, handling common functions (like mv, rm, touch, etc.) with built-in Perl functions, and doing direct execution rather than invoking the shell (bash).
6. **Command line interface**: in -jN mode the command-line processing is a detachable component that can be reattached to exist job-server processes. In use none of the components need to be on the same machine.

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

## Dry-Run Mode (`smak -n`)

Dry-run mode exercises the same code paths as a regular build, minus actually executing commands:

1. **Same code path**: Dry-run uses the same `build_target()` logic as real builds
2. **Sequential execution**: Always runs `-j1` to enforce deterministic output
3. **Forked execution**: Runs in a fork() so rule state changes can be discarded
4. **Dry workers**: Uses `smak-worker-dry` which prints commands via OUTPUT instead of executing
5. **Output matching**: `smak -n` output must match `make -n` output (verified by `smak -check`)

### Recursive Make in Dry-Run Mode

When `make -n` encounters a recursive make call, it passes `-n` through MAKEFLAGS so the child make also runs in dry-run mode and prints its commands. For `smak -n` to match:

1. When smak detects a recursive make/smak call in the command
2. It must fork into the subdirectory
3. Parse the sub-makefile with the command-line variables
4. Run dry-run expansion on the sub-targets
5. Print the expanded commands (not just the recursive make command itself)

### Consistency Requirements

- `smak -n` should produce output matching `make -n`
- `smak` (sequential) should behave the same as `make`
- `smak -j1` should behave the same as `make`

## Recent Fixes

### 2026-01-21: Compound Command Handling

**Problem**: Compound commands (`cmd1 && cmd2 && ...`) were being handled in-process even when a job server was running, which broke parallel builds.

**Initial Fix**: Changed the compound handler check to skip in-process handling when job server is active:
```perl
if (!$job_server_socket && $clean_cmd =~ /&&/) {
```

**Follow-up Fix**: Dry-run mode also uses a job server (with dry workers), but needs to expand compound commands in-process to properly show all commands. Updated condition to:
```perl
if (($dry_run_mode || !$job_server_socket) && $clean_cmd =~ /&&/) {
```

This ensures:
- Parallel mode (with job server): Job server handles compound commands
- Sequential mode (no job server): In-process handling
- Dry-run mode: In-process handling for proper command expansion

### 2026-01-21: Dry-Run Dependency Expansion

**Problem**: In dry-run mode with job server (`smak -n`), dependency expansion was skipped because `$job_server_socket` was set. This caused only partial output compared to sequential mode (`smak -n -j0`).

**Fix**: Changed the dependency expansion condition to include dry-run mode:
```perl
if (!$job_server_socket || $dry_run_mode) {
    # Temporarily disable job server for recursive builds in dry-run
    local $job_server_socket = $dry_run_mode ? undef : $job_server_socket;
    for my $dep (@deps) {
        build_target($dep, $visited, $depth + 1);
    }
}
```

This ensures dry-run mode expands all dependencies locally and prints all commands, matching the behavior of `make -n`.

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
   - Add `-n` flag to the recursive call, noting that "smak" commands
     are handled as a built-in whever possible
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

### 2026-01-21: Compound Command and Subdirectory Build Fixes

**Problem 1**: When `parse_make_command` returned empty for compound commands (like `smak -C dir1 && smak -C dir2 && ...`), the code would call `get_first_target()` which returns a random target from the hash.

**Fix**: Added check after `parse_make_command` returns - if no makefile, directory, or targets were parsed, fall through to external command execution instead of building a random target:
```perl
if (!$sub_makefile && !$sub_directory && !@sub_targets) {
    goto EXECUTE_EXTERNAL_COMMAND;
}
```

**Problem 2**: Subdirectory Makefiles weren't being parsed because the key (e.g., `Makefile\tall`) collided with the main Makefile's keys.

**Fix**: Use full path for $makefile when parsing subdirectory Makefiles:
```perl
$makefile = "$new_dir/$sub_mf_name";
```
And use `parse_included_makefile` instead of `parse_makefile` to accumulate rather than reset state.

**Problem 3**: Path duplication when verifying targets. A target like `vhdlpp/foo.o` in directory `/path/vhdlpp` would be checked at `/path/vhdlpp/vhdlpp/foo.o`.

**Fix**: Added prefix stripping in `verify_target_exists` and other path construction sites:
```perl
if ($dir && $target =~ m{^([^/]+)/(.+)$}) {
    my ($prefix, $base) = ($1, $2);
    if ($dir =~ m{/\Q$prefix\E$}) {
        $adjusted_target = $base;
    }
}
```

## Recursive Make Fork-and-Expand (Experimental)

### Problem Statement

When building projects like iverilog with `smak -j4`, half the workers were idle because
subdirectory builds (triggered by `$(MAKE) -C subdir`) were being handled sequentially
or not feeding work back to the job server properly.

### Design Goals

1. `smak -n` should match `make -n` output
2. Built-in handling of `$(MAKE) -C subdir` should:
   - Fork with fresh rule context (discard parent's rules)
   - Parse the subdirectory Makefile fresh
   - Capture and expand all targets/rules
   - Feed expanded rules back to the parent job-server with root-relative paths
3. The sub-make should NOT execute commands - it feeds work to the job-server
4. The job-server dispatches work to workers for parallel execution

### Implementation (Smak.pm)

When a command matches the recursive make pattern (`$(MAKE) -C dir` or `smak -C dir`):

1. **Fork a child process**:
   ```perl
   my $pid = fork();
   if ($pid == 0) {
       # Child: discard parent rules
       %fixed_rule = ();
       %fixed_deps = ();
       %pattern_rule = ();
       %pattern_deps = ();
       # ... other rule hashes cleared
   ```

2. **Parse subdirectory Makefile fresh**:
   ```perl
   chdir($sub_directory) or exit(1);
   eval { parse_makefile($sub_mf_name); };
   ```

3. **Capture targets via dry_run_target**:
   ```perl
   my %captured;
   for my $sub_target (@targets_to_build) {
       eval {
           dry_run_target($sub_target, {}, 0, {
               capture => \%captured,
               no_commands => 1
           });
       };
   }
   ```

4. **Expand all variables in child before serializing**:
   - `$MV{...}` variables via `format_output()` and `expand_vars()`
   - Automatic variables: `$@` (target), `$<` (first prereq), `$^` (all prereqs), `$*` (stem)
   ```perl
   my $expanded = format_output($info->{rule});
   $expanded = expand_vars($expanded);
   $expanded =~ s/\$\@/$tgt/g;
   $expanded =~ s/\$</$first_prereq/g;
   $expanded =~ s/\$\^/$all_prereqs/ge;
   $expanded =~ s/\$\*/$stem/g if $stem;
   ```

5. **Serialize captured targets via Storable**:
   ```perl
   Storable::nstore(\%captured, $jobs_file);
   exit(0);
   ```

6. **Parent loads and queues jobs with root-relative paths**:
   ```perl
   waitpid($pid, 0);
   my $captured = Storable::retrieve($jobs_file);
   for my $tgt (keys %$captured) {
       my $full_target = $normalize_path->($sub_directory, $tgt);
       # Queue job with root-relative path and expanded commands
   }
   ```

### Path Normalization

A helper function handles `.` and `..` in paths:
```perl
my $normalize_path = sub {
    my ($base_dir, $path) = @_;
    $path =~ s{^\./}{};  # Remove leading ./
    while ($path =~ s{^\.\./}{}) {
        if ($base_dir =~ m{/}) {
            $base_dir =~ s{/[^/]+$}{};
        } else {
            $base_dir = '';
        }
    }
    return $base_dir ? "$base_dir/$path" : $path;
};
```

### Fixes Applied

1. **ARRAY references in captured targets**: Pattern_deps structure is array of arrays
   `[['%.c'], ['%.cc']]`. Fixed by properly accessing variants in pattern rule matching.

2. **Pattern rules matching existing source files**: `parse%cc` incorrectly matched
   `parse_misc.cc`. Fixed by checking if any variant has existing prereqs before
   applying pattern rule to existing target.

3. **Dependency path doubling**: `ivlpp/lexor.lex` became `ivlpp/ivlpp/lexor.lex`.
   Fixed by checking if dep already starts with job dir prefix.

4. **can_build_target not finding queued targets**: Added checks for `$in_progress{$target}`,
   `$target_layer{$target}`, and compound targets.

### Current Status

**Working**:
- Variable expansion in forked children (commands show proper `gcc`/`g++` instead of `$MV{CC}`)
- Automatic variable expansion (`$@`, `$<`, `$^`, `$*`)
- Path normalization for `./` and `../` prefixes
- Pattern rules no longer incorrectly match existing source files

**Not Yet Working**:
- Test case with subdirectories (`/tmp/smak-test/`) shows subdirectory targets being
  marked "up-to-date" and skipped instead of triggering fork expansion
- The issue: `sub1` and `sub2` exist as directories, and even though they're declared
  `.PHONY` and have rules (`$(MAKE) -C $@ all`), they're being treated as up-to-date
- The phony detection may not be finding the `.PHONY` declaration, or the rule lookup
  for `$(SUBDIRS):` targets isn't working correctly

### Test Case

Created at `/tmp/smak-test/`:
```
/tmp/smak-test/
├── Makefile          # SUBDIRS = sub1 sub2; $(SUBDIRS): $(MAKE) -C $@ all
├── sub1/
│   ├── Makefile      # prog1: main.o util.o
│   ├── main.c
│   └── util.c
└── sub2/
    ├── Makefile      # prog2: app.o helper.o
    ├── app.c
    └── helper.c
```

`make -j4` works correctly. `smak -j4` skips subdirectories as "up-to-date".

### Next Steps

1. Debug why `.PHONY` targets that are directories aren't triggering their rules
2. Check if the `$(SUBDIRS):` rule is being parsed correctly (the target list expands
   to `sub1 sub2`, need to verify rule lookup works for these)
3. May need to force phony behavior for targets that have recursive make commands

## Shell-Executed Child SMAK (External Recursive Make)

### When This Happens

Some recursive make commands cannot be handled via the internal fork-and-expand path:
- Commands with backtick command substitution (e.g., `build_cflags="\`cmd\`"`)
- Complex shell constructs that need shell interpretation
- When the `-f makefile` option points to a different makefile

In these cases, smak falls back to external execution via shell. The child smak
process inherits `SMAK_JOB_SERVER` environment variable and should coordinate
with the parent job server.

### Architecture for Shell-Executed Child

1. **Child Startup**: Detects `SMAK_JOB_SERVER` environment variable
2. **Connect to Parent**: Opens socket to parent job server
3. **Parse Makefile**: Parses with command-line variables (already shell-expanded)
4. **Submit Jobs**: Uses `submit_job()` to send expanded commands to parent
   - Target names should be root-relative (e.g., `src/cache.o` not `cache.o`)
   - Directory should be absolute path for job execution
   - Commands are fully expanded with all variables resolved
5. **Completion Tracking**: Parent must know when child's jobs are done

### Current Implementation Issues (dnsmasq case)

The dnsmasq Makefile has:
```makefile
version = -DVERSION='\"`$(top)/bld/get-version $(top)`\"'
all:
    @cd $(BUILDDIR) && $(MAKE) build_cflags="$(version) ..." -f $(top)/Makefile dnsmasq
```

The backticks in `$(version)` cause smak to fall back to external execution.
The child smak runs via shell with `build_cflags` expanded. Issues:

1. **Variable Not Passed in BUILD Protocol**: The BUILD message didn't include
   command-line variables, so parent job server didn't have `build_cflags` set.

2. **COMPLETE Sent Immediately**: The BUILD handler sends COMPLETE before
   queued jobs finish, causing synchronization issues.

3. **SUBMIT_JOB Approach**: If child uses `submit_job()` directly, it exits
   after submitting but parent doesn't track these as dependencies of the
   original target (`all`).

### Proposed Solution

When a child smak connects via `SMAK_JOB_SERVER`:

1. **Submit Phase**: Child parses makefile, submits jobs via SUBMIT_JOB
   - Each job includes fully-expanded command with root-relative target
   - Parent queues these jobs for dispatch

2. **Synchronization**: Child sends "CHILD_DONE <count>" message after submitting
   - Parent tracks that <count> jobs belong to this child
   - Parent doesn't mark original target (that triggered child) as complete
     until all child jobs finish

3. **Completion**: When all child's jobs complete, parent marks original
   target as complete

This requires:
- New protocol message: `CHILD_DONE <job_count>`
- Parent tracks job->child relationship
- Original target waits for child jobs

## Open Issues

1. Some regression tests still failing
2. Need to implement proper layer-based compound target handling
3. Fork-and-expand not triggering for phony directory targets (see above)
4. Shell-executed child smak completion tracking (dnsmasq case)

## To Do

1. Add rules for invalidating target when its rules change (through Makefile
   updates), but don't invalidate just because the make-file changed.
   I.e. rules depend on the make-files, targets are marked stale if their
   rules change. Add a test for that where you do a code build and then modify
   C compiler flags in the make-file and build again.

2. Slurm support

3. Test with Fuse-NFS
