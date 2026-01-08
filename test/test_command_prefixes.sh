#!/bin/bash
# Test command prefix handling (@ for silent, - for ignore errors)

echo "Testing command prefixes..."
echo ""

# Test 1: Dry-run should strip both @ and - prefixes
echo "Test 1: Dry-run output (should match make)"
DRY1=$(make -n -f test_hyphen_prefix.mk all 2>&1)
DRY2=$(${USR_SMAK_SCRIPT:-smak} -n -f test_hyphen_prefix.mk all 2>&1)

if [ "$DRY1" = "$DRY2" ]; then
    echo "  ✓ PASS: Dry-run output matches make"
else
    echo "  ✗ FAIL: Dry-run output differs"
    echo "Make:"
    echo "$DRY1"
    echo "Smak:"
    echo "$DRY2"
    exit 1
fi

# Test 2: - prefix should ignore errors
echo ""
echo "Test 2: Ignore errors with - prefix"
${USR_SMAK_SCRIPT:-smak} -f test_ignore_errors2.mk test > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ PASS: Command with - prefix ignored error and continued"
else
    echo "  ✗ FAIL: Command failed despite - prefix"
    exit 1
fi

# Test 3: @ prefix should suppress echo
echo ""
echo "Test 3: Silent mode with @ prefix"
OUTPUT=$(${USR_SMAK_SCRIPT:-smak} -f test_ignore_errors.mk test 2>&1)
if ! echo "$OUTPUT" | grep -q "echo"; then
    echo "  ✓ PASS: @ prefix suppressed command echo"
else
    echo "  ✗ FAIL: @ prefix did not suppress echo"
    echo "Output: $OUTPUT"
    exit 1
fi

echo ""
echo "All tests passed!"
