#!/bin/bash
# Test that SMAK_RCFILE environment variable works correctly

echo "Testing SMAK_RCFILE environment variable..."
echo ""

cd "$(dirname "$0")"

# Test 1: Using .smak.test.rc should show the message
echo "Test 1: Verify .smak.test.rc is loaded"
OUTPUT=$(SMAK_RCFILE=.smak.test.rc ../smak -f Makefile.test list 2>&1)
if echo "$OUTPUT" | grep -q "Using SMAK_RCFILE:.*\.smak\.test\.rc"; then
    echo "  ✓ PASS: .smak.test.rc was loaded"
else
    echo "  ✗ FAIL: .smak.test.rc was not loaded"
    echo "  Output: $OUTPUT"
    exit 1
fi

# Test 2: Using /dev/null should not show the message
echo "Test 2: Verify /dev/null works (no rc file loaded)"
OUTPUT=$(SMAK_RCFILE=/dev/null ../smak -f Makefile.test list 2>&1)
if echo "$OUTPUT" | grep -q "Using SMAK_RCFILE"; then
    echo "  ✗ FAIL: /dev/null should not load any rc file"
    echo "  Output: $OUTPUT"
    exit 1
else
    echo "  ✓ PASS: /dev/null prevents rc file loading"
fi

# Test 3: Verify the message shows the correct path
echo "Test 3: Verify SMAK_RCFILE value is shown correctly"
OUTPUT=$(SMAK_RCFILE=.smak.test.rc ../smak -f Makefile.test list 2>&1)
if echo "$OUTPUT" | grep -q "Using SMAK_RCFILE:.*\.smak\.test\.rc"; then
    echo "  ✓ PASS: Correct SMAK_RCFILE path shown"
else
    echo "  ✗ FAIL: SMAK_RCFILE path not shown correctly"
    echo "  Output: $OUTPUT"
    exit 1
fi

echo ""
echo "All tests passed!"
