#!/bin/bash
# Test stop-on-failure behavior
# Verifies that:
#   1. Without -k: build stops at first failure, later targets NOT built
#   2. With -k: build continues after failure, independent targets ARE built

cd "$(dirname "$0")"
SMAK=${USR_SMAK_SCRIPT:-smak}
FAILED=0

echo "Testing stop-on-failure behavior..."

# Clean up any previous test artifacts
rm -f success1.txt success2.txt success3.txt

echo ""
echo "Test 1: Without -k flag (should stop on first failure)"
$SMAK -f Makefile.stop_on_failure clean 2>/dev/null

# Run build and capture output
OUTPUT=$($SMAK -f Makefile.stop_on_failure -j2 2>&1)
EXIT_CODE=$?

# Should have the error message
if echo "$OUTPUT" | grep -q "smak: \*\*\* \[fail1\] Error"; then
    echo "  PASS: Error message displayed"
else
    echo "  FAIL: No error message found"
    FAILED=1
fi

# Check that success3 was NOT built (stopped before reaching it)
if [ -f success3.txt ]; then
    echo "  FAIL: success3.txt was built but should have been stopped"
    FAILED=1
else
    echo "  PASS: success3.txt was NOT built (stopped on failure)"
fi

# Verify exit code is non-zero
if [ $EXIT_CODE -ne 0 ]; then
    echo "  PASS: Exit code is non-zero ($EXIT_CODE)"
else
    echo "  FAIL: Exit code should be non-zero"
    FAILED=1
fi

echo ""
echo "Test 2: With -k flag (should continue after failure)"
$SMAK -f Makefile.stop_on_failure clean 2>/dev/null
rm -f success1.txt success2.txt success3.txt

# Run build with -k
OUTPUT=$($SMAK -f Makefile.stop_on_failure -k -j2 2>&1)
EXIT_CODE=$?

# With -k, all independent success targets should be built
if [ -f success1.txt ] && [ -f success2.txt ] && [ -f success3.txt ]; then
    echo "  PASS: All success*.txt files were built with -k"
else
    echo "  FAIL: Not all success files built with -k"
    FAILED=1
fi

# Verify exit code is still non-zero (build failed, even with -k)
if [ $EXIT_CODE -ne 0 ]; then
    echo "  PASS: Exit code is non-zero with -k ($EXIT_CODE)"
else
    echo "  FAIL: Exit code should be non-zero even with -k"
    FAILED=1
fi

# Clean up
rm -f success1.txt success2.txt success3.txt

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All stop-on-failure tests passed!"
    exit 0
else
    echo "Some tests failed"
    exit 1
fi
