#!/bin/bash
# Test that OBJEXT variable expansion doesn't hit iteration limits
# This tests the issue found in projects/nvc/Makefile

echo "Testing OBJEXT variable expansion..."
echo ""

cd "$(dirname "$0")"
MAKEFILE="test_objext_expansion.mk"
FAILED=0

# Pre-check: Validate smak dry-run matches make (exits on mismatch)
${USR_SMAK_SCRIPT:-smak} --check=quiet -f "$MAKEFILE" all || {
    echo "FAIL: smak --check=quiet validation failed (dry-run mismatch with make)"
    exit 1
}

# Test: Dry-run should expand $(OBJEXT) without hitting iteration limit
echo "Test: Dry-run with automake-style variables"
DRY_OUTPUT=$(${USR_SMAK_SCRIPT:-smak} -n -f "$MAKEFILE" all 2>&1)
EXIT_CODE=$?

# Check for iteration limit warning
if echo "$DRY_OUTPUT" | grep -q "iteration limit"; then
    echo "  ✗ FAIL: Hit variable expansion iteration limit"
    echo "Output:"
    echo "$DRY_OUTPUT"
    ((FAILED++))
else
    echo "  ✓ PASS: No iteration limit warning"
fi

# Check that OBJEXT was expanded to 'o'
if echo "$DRY_OUTPUT" | grep -q "src/lib\.o"; then
    echo "  ✓ PASS: OBJEXT expanded to 'o' (found src/lib.o)"
else
    echo "  ✗ FAIL: OBJEXT not properly expanded"
    echo "Expected to find 'src/lib.o' in output:"
    echo "$DRY_OUTPUT"
    ((FAILED++))
fi

# Check that the command contains the correct AR invocation
if echo "$DRY_OUTPUT" | grep -q "gcc-ar cr lib/libnvc.a"; then
    echo "  ✓ PASS: AR command looks correct"
else
    echo "  ✗ FAIL: AR command not found or incorrect"
    echo "Output:"
    echo "$DRY_OUTPUT"
    ((FAILED++))
fi

# Check exit code
if [ $EXIT_CODE -eq 0 ]; then
    echo "  ✓ PASS: smak exited successfully"
else
    echo "  ✗ FAIL: smak exited with code $EXIT_CODE"
    ((FAILED++))
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Failed $FAILED test(s)"
    exit 1
fi
