#!/bin/bash
# Test OBJEXT expansion with actual nvc Makefile
# This should expose the iteration limit issue

echo "Testing OBJEXT expansion with nvc Makefile..."
echo ""

cd "$(dirname "$0")"
FAILED=0

# Test with actual nvc Makefile
echo "Test: Dry-run lib/libnvc.a with nvc Makefile"
cd ../projects/nvc || exit 1

DRY_OUTPUT=$(../../smak -n lib/libnvc.a 2>&1)
EXIT_CODE=$?

# Check for iteration limit warning
if echo "$DRY_OUTPUT" | grep -q "iteration limit"; then
    echo "  ✗ FAIL: Hit variable expansion iteration limit"
    echo "Warning message:"
    echo "$DRY_OUTPUT" | grep -A 2 "iteration limit"
    ((FAILED++))
else
    echo "  ✓ PASS: No iteration limit warning"
fi

# Check that OBJEXT was expanded properly in the dependencies
if echo "$DRY_OUTPUT" | grep -q "src/lib\.o"; then
    echo "  ✓ PASS: OBJEXT expanded in dependencies (found src/lib.o)"
else
    echo "  ✗ FAIL: OBJEXT not properly expanded in dependencies"
    ((FAILED++))
fi

# Check for unexpanded OBJEXT references (the bug)
if echo "$DRY_OUTPUT" | grep -q '\$(OBJEXT)'; then
    echo "  ✗ FAIL: Found unexpanded \$(OBJEXT) references"
    echo "Examples:"
    echo "$DRY_OUTPUT" | grep -o 'src/[^[:space:]]*\$(OBJEXT)' | head -5
    ((FAILED++))
else
    echo "  ✓ PASS: All OBJEXT references properly expanded"
fi

# Verify specific file that was reported as problematic
if echo "$DRY_OUTPUT" | grep -q 'vlog-dump\.o'; then
    echo "  ✓ PASS: vlog-dump.o properly expanded (if no \$(OBJEXT) found)"
elif echo "$DRY_OUTPUT" | grep -q 'vlog-dump\.\$(OBJEXT)'; then
    echo "  ✗ FAIL: vlog-dump still has unexpanded \$(OBJEXT)"
    ((FAILED++))
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Failed $FAILED test(s)"
    echo ""
    echo "Note: This test documents the OBJEXT expansion issue in nvc Makefile"
    exit 1
fi
