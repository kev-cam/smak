# Test 24: Pattern Rules and Vpath

## Purpose
This test verifies the fixes for pattern rule dependency resolution and vpath handling in dispatch_jobs.

## What It Tests

### 1. Pattern Rule Expansion
- Pattern rule: `%.o: %.cc config.h`
- Verifies that when checking `main.o`, dependencies are expanded from `%.cc` to `main.cc`
- Ensures pattern matching works correctly in dispatch_jobs

### 2. Vpath Resolution
- Vpath directive: `vpath %.cc src`
- Source files are in `src/` subdirectory
- Verifies that dependencies are found via vpath when not in current directory
- Tests that `main.cc` is correctly resolved to `src/main.cc`

### 3. Hash Lookup Integrity
- Ensures dependency names remain unchanged (e.g., "main.cc", not "src/main.cc")
- Verifies that `completed_targets`, `failed_targets`, and `in_progress` hashes use correct keys
- Tests that vpath resolution only affects file existence checks, not dependency tracking

### 4. Dependency Ordering
- Verifies that `program` waits for `main.o` and `helper.o` to complete
- Tests that `main.o` and `helper.o` can be built in parallel
- Ensures proper dispatching when dependencies are queued but not yet built

## Structure
```
test-24/
├── Makefile           # Pattern rules and vpath directives
├── config.h           # Header file (dependency for all .o files)
├── src/
│   ├── main.cc        # Source file (found via vpath)
│   └── helper.cc      # Source file (found via vpath)
└── test.sh            # Test runner script
```

## Expected Behavior
1. Pattern rule matches: `main.o` matches `%.o`
2. Dependencies expanded: `%.cc` → `main.cc`, plus `config.h`
3. Vpath resolution: `main.cc` found at `src/main.cc`
4. File check: `src/main.cc` exists → dependency satisfied
5. Build: `main.o` and `helper.o` compiled in parallel
6. Link: `program` built after both .o files complete

## Bugs This Test Would Catch

### Bug 1: No pattern matching in dispatch_jobs
- **Symptom**: Build hangs, no jobs dispatched
- **Cause**: dispatch_jobs doesn't match `main.o` against `%.o` pattern
- **Fix**: Added pattern matching logic (like queue_target_recursive)

### Bug 2: Vpath modifies dependency names
- **Symptom**: Targets fail with "cannot be built" errors
- **Cause**: Dependencies resolved to "src/main.cc", hash lookups fail
- **Fix**: Keep dependency names unchanged, resolve vpath only for file checks

### Bug 3: Missing in_progress check for queued targets
- **Symptom**: Build hangs when dependencies are queued
- **Cause**: in_progress check only in "file exists" block
- **Fix**: Added elsif block to check in_progress before "doesn't exist" block

## Running the Test
```bash
cd test/test-24
./test.sh
```

## Success Criteria
- All .o files built from .cc files via pattern rule
- Program linked from .o files
- No "stuck" or "cannot be built" errors
- Incremental rebuild correctly skips up-to-date targets
