#!/bin/bash
# Test suffix rule collision handling
# When multiple suffix rules can produce the same target (e.g., .c.o and .cxx.o both -> .o),
# the build tool must check which source file exists and select the appropriate rule.
#
# EXPECTED BEHAVIOR:
# - For only_c.o: Should use .c.o rule (gcc) because only_c.c exists
# - For only_cxx.o: Should use .cxx.o rule (g++) because only_cxx.cxx exists
# - Both make and smak should produce identical output
#
# CURRENT BEHAVIOR (after reverting suffix rule support):
# - Make correctly selects rules based on which source exists
# - Smak uses built-in implicit rules, ignoring the user-defined suffix rules
# - This test will FAIL until suffix rule support is properly re-implemented

echo "Testing suffix rule collision handling..."
echo ""

cd "$(dirname "$0")"
MAKEFILE="test_suffix_collision.mk"
FAILED=0

# Clean any previous build artifacts
rm -f only_c.o only_cxx.o

# Test: Dry-run should select correct rule based on which source file exists
echo "Test: Rule selection based on source file existence"
DRY_MAKE=$(timeout 5 make -n -f "$MAKEFILE" all 2>&1)
DRY_SMAK=$(timeout 5 ../smak -n -f "$MAKEFILE" all 2>&1)

echo "Make output:"
echo "$DRY_MAKE"
echo ""
echo "Smak output:"
echo "$DRY_SMAK"
echo ""

# Check that make uses gcc for only_c.c
if echo "$DRY_MAKE" | grep -q "gcc.*only_c.c"; then
    echo "  ✓ Make uses gcc for only_c.c (correct - .c file exists)"
else
    echo "  ✗ FAIL: Make doesn't use gcc for only_c.c"
    ((FAILED++))
fi

# Check that make uses g++ for only_cxx.cxx
if echo "$DRY_MAKE" | grep -q "g++.*only_cxx.cxx"; then
    echo "  ✓ Make uses g++ for only_cxx.cxx (correct - .cxx file exists)"
else
    echo "  ✗ FAIL: Make doesn't use g++ for only_cxx.cxx"
    ((FAILED++))
fi

# Check that smak uses gcc for only_c.c
if echo "$DRY_SMAK" | grep -q "gcc.*only_c.c"; then
    echo "  ✓ Smak uses gcc for only_c.c"
else
    echo "  ✗ FAIL: Smak doesn't use gcc for only_c.c"
    echo "  (Expected: gcc, showing built-in cc rule instead)"
    ((FAILED++))
fi

# Check that smak uses g++ for only_cxx.cxx
if echo "$DRY_SMAK" | grep -q "g++.*only_cxx.cxx"; then
    echo "  ✓ Smak uses g++ for only_cxx.cxx"
else
    echo "  ✗ FAIL: Smak doesn't use g++ for only_cxx.cxx"
    echo "  (Expected: g++, showing built-in c++ rule instead)"
    ((FAILED++))
fi

# Compare outputs
echo ""
if [ "$DRY_MAKE" = "$DRY_SMAK" ]; then
    echo "  ✓ PASS: Make and Smak outputs match"
else
    echo "  ✗ FAIL: Outputs differ"
    echo "Differences:"
    diff -u <(echo "$DRY_MAKE") <(echo "$DRY_SMAK") || true
    ((FAILED++))
fi

# Clean up
rm -f only_c.o only_cxx.o

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Failed $FAILED check(s)"
    echo ""
    echo "Note: These failures are EXPECTED until suffix rule support is re-implemented."
    echo "The test documents the correct behavior that needs to be implemented."
    exit 1
fi
