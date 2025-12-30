# Development Rules for Smak

## Testing Before Committing

**CRITICAL: Always test changes before committing!**

### Quick Testing Workflow

When making changes to smak, use the test suite to verify your changes:

```bash
# Quick test of a specific test (fastest)
cd test
./run-regression --filter "test_name" --no-parallel --fast

# Test multiple related tests
./run-regression --filter "debug|builtin" --no-parallel --fast

# Run all tests with sequential-only (faster than full suite)
./run-regression --no-parallel

# Full regression test (run before final commit)
./run-regression
```

### Test Options Reference

- `--filter <pattern>`: Run only tests matching the pattern (grep -E)
- `--no-parallel`: Skip parallel modes, test only sequential behavior (2x faster)
- `--fast`: Stop at first failure per test (faster failure detection)
- `--verbose`: Show test output for debugging
- Combine options: `--no-parallel --fast` for quickest smoke test

### When to Test What

1. **During development** (quick iteration):
   - Use `--filter` to test only affected functionality
   - Add `--no-parallel --fast` for speed

2. **Before committing** (verify your changes):
   - Run tests related to your changes without `--fast`
   - Ensure both sequential and parallel modes pass

3. **Before pushing** (final verification):
   - Run full regression suite: `./run-regression`
   - Fix any failures before pushing

### Example: Testing Assertion Changes

```bash
# Made changes to Smak.pm assertions
cd test

# Quick smoke test (5-10 tests that exercise parallel builds)
./run-regression --filter "parallel|queue" --no-parallel --fast

# Verify the specific functionality works
./run-regression --filter "test_recursive_parallel"

# Final check before commit
./run-regression --no-parallel
```

## Code Quality Rules

### Assertions

- Use `assert_or_die()` for internal logic errors that should never happen
- Assertions should have clear, actionable error messages
- Always test the failure path when possible
- Remember assertions can be disabled with `ASSERTIONS_ENABLED => 0`

### Before Every Commit

1. ✅ Test affected functionality with relevant test cases
2. ✅ Verify no syntax errors (`perl -c` for Perl files)
3. ✅ Run quick regression: `./run-regression --no-parallel --fast`
4. ✅ Review your changes: `git diff`
5. ✅ Write a clear commit message explaining WHY, not just WHAT

### Commit Message Format

```
Short summary (50 chars or less)

Detailed explanation of:
- What was changed
- WHY it was changed (the problem being solved)
- How it fixes the issue
- Any trade-offs or considerations

Testing: How the change was tested
```

## Common Pitfalls

1. **Too aggressive assertions**: Don't assert conditions that are normal during startup/shutdown
2. **Not testing parallel mode**: Many bugs only appear in parallel builds
3. **Forgetting edge cases**: Empty queues, single jobs, max workers, etc.
4. **Committing without testing**: Always test first!

## Quick Reference

```bash
# Fast smoke test
./run-regression --filter "echo|dryrun" --no-parallel --fast

# Test specific feature area
./run-regression --filter "debug" --no-parallel

# Full verification
./run-regression

# Debug a failing test
./run-regression --filter "test_name" --verbose
```
