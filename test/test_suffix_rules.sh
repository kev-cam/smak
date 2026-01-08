#!/bin/bash
# Test C/C++ suffix rules
# Verifies that .c.o and .cxx.o suffix rules work correctly and use the right compilers
#
# EXPECTED BEHAVIOR:
# - Make uses the suffix rules defined in the Makefile (gcc for .c, g++ for .cxx)
# - Smak should use the same suffix rules (gcc for .c, g++ for .cxx)
# - Both should produce identical dry-run output
#
# CURRENT BEHAVIOR (after reverting suffix rule support):
# - Make uses the suffix rules correctly
# - Smak falls back to built-in implicit rules (cc for .c, c++ for .cxx)
# - This test will FAIL until suffix rule support is properly re-implemented

echo "Testing C/C++ suffix rules..."
echo ""

cd "$(dirname "$0")"
MAKEFILE="test_suffix_rules.mk"
FAILED=0

# Clean any previous build artifacts
rm -f test_c.o test_cxx.o

# Test 1: Dry-run should show correct compilers for each file type
echo "Test 1: Dry-run output (verify correct compilers)"
DRY_MAKE=$(timeout 5 make -n -f "$MAKEFILE" all 2>&1)
DRY_SMAK=$(timeout 5 ${USR_SMAK_SCRIPT:-smak} -n -f "$MAKEFILE" all 2>&1)

echo "Make output:"
echo "$DRY_MAKE"
echo ""
echo "Smak output:"
echo "$DRY_SMAK"
echo ""

# Check that make uses gcc for .c files
if echo "$DRY_MAKE" | grep -q "gcc.*test_c.c"; then
    echo "  ✓ Make uses gcc for .c files"
else
    echo "  ✗ FAIL: Make doesn't use gcc for .c files"
    ((FAILED++))
fi

# Check that make uses g++ for .cxx files
if echo "$DRY_MAKE" | grep -q "g++.*test_cxx.cxx"; then
    echo "  ✓ Make uses g++ for .cxx files"
else
    echo "  ✗ FAIL: Make doesn't use g++ for .cxx files"
    ((FAILED++))
fi

# Check that smak uses gcc for .c files
if echo "$DRY_SMAK" | grep -q "gcc.*test_c.c"; then
    echo "  ✓ Smak uses gcc for .c files"
else
    echo "  ✗ FAIL: Smak doesn't use gcc for .c files"
    echo "Full smak output:"
    echo "$DRY_SMAK"
    ((FAILED++))
fi

# Check that smak uses g++ for .cxx files
if echo "$DRY_SMAK" | grep -q "g++.*test_cxx.cxx"; then
    echo "  ✓ Smak uses g++ for .cxx files"
else
    echo "  ✗ FAIL: Smak doesn't use g++ for .cxx files"
    echo "Full smak output:"
    echo "$DRY_SMAK"
    ((FAILED++))
fi

# Test 2: Compare dry-run outputs
echo ""
echo "Test 2: Compare make and smak dry-run outputs"
if [ "$DRY_MAKE" = "$DRY_SMAK" ]; then
    echo "  ✓ PASS: Outputs match exactly"
else
    echo "  ✗ FAIL: Outputs differ"
    echo "Differences:"
    diff -u <(echo "$DRY_MAKE") <(echo "$DRY_SMAK") || true
    ((FAILED++))
fi

# Clean up
rm -f test_c.o test_cxx.o

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Failed $FAILED test(s)"
    exit 1
fi
