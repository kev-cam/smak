# SMAK Test Suite

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
