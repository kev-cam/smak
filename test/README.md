# SMAK Test Suite

## Quick Setup

Run the setup script to install all test dependencies:
```bash
sudo ./setup-test-deps.sh
```

## Dependencies

### System Packages (Debian/Ubuntu)
```bash
sudo apt-get install libio-pty-perl
```

### Perl Modules
- IO::Pty - Required for automated interactive test scripts (run-with-script.pl)
- IO::Select - Standard library
- POSIX - Standard library
- Time::HiRes - Standard library

**Note:** Without `libio-pty-perl`, most tests will fail with:
```
Can't locate IO/Pty.pm in @INC
```

## Running Tests

### Quick Regression Test
```bash
cd test
./run-regression
```

### Before Push
```bash
./test/test-before-push
```

This runs the full regression suite and logs results to `test/logs/`.

**Important:** Before committing changes, copy the regression report to the reports directory:
```bash
# After running tests, save the baseline report
cp test/logs/test-<branch>-<sha>-<timestamp>.log reports/default-<date>-<sha>
```

This maintains a baseline record of test results for tracking regressions.

### Full Test Suite
```bash
cd test
./run-regression --full
```

Includes random build tests and CLI tests.

### Test Options
```bash
./run-regression --help          # Show all options
./run-regression --sanity        # Quick sanity check
./run-regression --verbose       # Show test output
./run-regression --filter debug  # Run only matching tests
```

### Isolating Tests from User Configuration

To prevent user's `~/.smak.rc` from affecting test results:

**Method 1: Using -norc flag**
```bash
./run-regression -norc           # Pass -norc to smak
```

**Method 2: Using SMAK_RCFILE environment variable**
```bash
# Point to empty/minimal rc file
export SMAK_RCFILE=/dev/null
./run-regression

# Or inline
SMAK_RCFILE=/dev/null ./run-regression
```

**Method 3: Using a test-specific rc file**
```bash
# Create a minimal test rc file
echo "# Test configuration" > test/.smak.test.rc
SMAK_RCFILE=test/.smak.test.rc ./run-regression
```

## Test Results

Tests are run in 4 modes:
- Sequential/NoCache
- Sequential/Cache
- Parallel/NoCache (with -j4)
- Parallel/Cache (with -j4)

Each test also runs its `-fail` variant to verify error handling.

## Interactive Tests

Some tests use interactive debug mode (`-Kd` flag). These are automated using script files in `scripts/*.script` that define the commands to send and expected responses.

The `run-with-script.pl` tool uses PTY (pseudo-terminal) to simulate interactive input for these tests.

## Known Issues

### Timeout Failures (6 tests)
The following interactive tests currently timeout after 30s:
- test_autorescan (partial failure - only Sequential/NoCache passes)
- test_debug
- test_debug_simple
- test_script
- test_timeout
- test_var_translation

These tests appear to have issues with PTY-based interactive automation.

### Race Condition (1 test)
- test_scanner: Fails only in Parallel/Cache mode - file system events not all detected

### Current Test Status
With `libio-pty-perl` installed:
- **18/25 tests passing (72%)**
- 7 tests failing (pre-existing issues, not regressions)
