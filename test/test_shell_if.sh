#!/bin/bash
# Test that smak handles && inside shell if-conditions correctly
# Reproduces: ghdl version.tmp failure where "if test -d .git && desc=..." is broken

echo "Testing shell if-then with && in condition..."
echo ""

FAILED=0

# Clean any leftover from previous runs
rm -f version.tmp

# Test 1: Sequential build result should match make
echo "Test 1: Sequential build result (should match make)"
make -s -f Makefile.shell_if all 2>&1 > /tmp/make_shell_if.out
MAKE_RC=$?
MAKE_VER=$(cat version.tmp 2>/dev/null)
rm -f version.tmp

${USR_SMAK_SCRIPT:-smak} -s -f Makefile.shell_if all 2>&1 > /tmp/smak_shell_if.out
SMAK_RC=$?
SMAK_VER=$(cat version.tmp 2>/dev/null)
rm -f version.tmp

if [ $MAKE_RC -ne 0 ]; then
    echo "  ✗ SKIP: make itself failed (rc=$MAKE_RC)"
elif [ $SMAK_RC -ne 0 ]; then
    echo "  ✗ FAIL: smak failed (rc=$SMAK_RC) but make succeeded"
    echo "  Smak output:"
    cat /tmp/smak_shell_if.out
    ((FAILED++))
elif [ "$MAKE_VER" = "$SMAK_VER" ]; then
    echo "  ✓ PASS: Sequential build matches make (version.tmp=$SMAK_VER)"
else
    echo "  ✗ FAIL: version.tmp differs"
    echo "  Make: $MAKE_VER"
    echo "  Smak: $SMAK_VER"
    ((FAILED++))
fi

# Test 2: Parallel build should produce same result as make
echo ""
echo "Test 2: Parallel build with -j4 (should match make)"
${USR_SMAK_SCRIPT:-smak} -s -j 4 -f Makefile.shell_if all 2>&1 > /tmp/smak_shell_if_par.out
SMAK_PAR_RC=$?
SMAK_PAR_VER=$(cat version.tmp 2>/dev/null)
rm -f version.tmp

if [ $SMAK_PAR_RC -ne 0 ]; then
    echo "  ✗ FAIL: smak -j4 failed (rc=$SMAK_PAR_RC)"
    echo "  Output:"
    cat /tmp/smak_shell_if_par.out
    ((FAILED++))
elif [ "$MAKE_VER" = "$SMAK_PAR_VER" ]; then
    echo "  ✓ PASS: Parallel build matches make (version.tmp=$SMAK_PAR_VER)"
else
    echo "  ✗ FAIL: version.tmp differs"
    echo "  Make: $MAKE_VER"
    echo "  Smak -j4: $SMAK_PAR_VER"
    ((FAILED++))
fi

# Test 3: Parallel --no-builtins should also work
echo ""
echo "Test 3: Parallel --no-builtins (should match make)"
${USR_SMAK_SCRIPT:-smak} -s -j 4 --no-builtins -f Makefile.shell_if all 2>&1 > /tmp/smak_shell_if_nb.out
SMAK_NB_RC=$?
SMAK_NB_VER=$(cat version.tmp 2>/dev/null)
rm -f version.tmp

if [ $SMAK_NB_RC -ne 0 ]; then
    echo "  ✗ FAIL: smak -j4 --no-builtins failed (rc=$SMAK_NB_RC)"
    echo "  Output:"
    cat /tmp/smak_shell_if_nb.out
    ((FAILED++))
elif [ "$MAKE_VER" = "$SMAK_NB_VER" ]; then
    echo "  ✓ PASS: No-builtins parallel matches make (version.tmp=$SMAK_NB_VER)"
else
    echo "  ✗ FAIL: version.tmp differs"
    echo "  Make: $MAKE_VER"
    echo "  Smak --no-builtins: $SMAK_NB_VER"
    ((FAILED++))
fi

# Clean up
rm -f /tmp/make_shell_if.out /tmp/smak_shell_if.out /tmp/smak_shell_if_par.out /tmp/smak_shell_if_nb.out
rm -f version.tmp

echo ""
if [ $FAILED -gt 0 ]; then
    echo "Failed $FAILED test(s)"
    exit 1
fi
echo "All tests passed!"
