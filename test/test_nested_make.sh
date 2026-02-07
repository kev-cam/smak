#!/bin/bash
# Test that nested makes are handled as built-in (not spawned to workers)

set -e
cd "$(dirname "$0")"

echo "Testing nested make behavior..."

# Clean up
rm -f subdir/target1.txt subdir/target2.txt
rm -f nested-f-target1.txt nested-f-target2.txt

FAIL=0

# Test 1: Nested make with -C
echo ""
echo "Test 1: Nested make with -C (change directory)"
echo "================================================"

# Run the build in background and capture status
smak -f Makefile.nested-C -j2 > /tmp/nested-C-output.txt 2>&1 &
BUILD_PID=$!

# Give it a moment to start
sleep 0.5

# Check status - if sub-make is handled as built-in, workers should be idle
# or busy with actual work (not smak/make commands)
STATUS=$(smak -s 2>/dev/null || true)
echo "Status during build:"
echo "$STATUS"

# Wait for build to complete
wait $BUILD_PID
BUILD_EXIT=$?

echo ""
echo "Build output:"
cat /tmp/nested-C-output.txt

# Check if build succeeded
if [ $BUILD_EXIT -ne 0 ]; then
    echo "  FAIL: Build exited with code $BUILD_EXIT"
    FAIL=1
else
    echo "  PASS: Build succeeded"
fi

# Check if targets were built
if [ -f subdir/target1.txt ] && [ -f subdir/target2.txt ]; then
    echo "  PASS: Subdir targets were built"
else
    echo "  FAIL: Subdir targets were not built"
    FAIL=1
fi

# Check that the sub-make was NOT running as a worker job
# (If it was, we'd see "smak" or "make" in the worker's job description)
if echo "$STATUS" | grep -q "worker.*busy.*smak\|worker.*busy.*make"; then
    echo "  FAIL: Sub-make was spawned to a worker (should be handled as built-in)"
    FAIL=1
else
    echo "  PASS: Sub-make was NOT spawned to a worker"
fi

# Test 2: Nested make with -f
echo ""
echo "Test 2: Nested make with -f (alternate makefile)"
echo "================================================="

# Run the build in background and capture status
smak -f Makefile.nested-f -j2 > /tmp/nested-f-output.txt 2>&1 &
BUILD_PID=$!

# Give it a moment to start
sleep 0.5

# Check status
STATUS=$(smak -s 2>/dev/null || true)
echo "Status during build:"
echo "$STATUS"

# Wait for build to complete
wait $BUILD_PID
BUILD_EXIT=$?

echo ""
echo "Build output:"
cat /tmp/nested-f-output.txt

# Check if build succeeded
if [ $BUILD_EXIT -ne 0 ]; then
    echo "  FAIL: Build exited with code $BUILD_EXIT"
    FAIL=1
else
    echo "  PASS: Build succeeded"
fi

# Check if targets were built
if [ -f nested-f-target1.txt ] && [ -f nested-f-target2.txt ]; then
    echo "  PASS: Sub-makefile targets were built"
else
    echo "  FAIL: Sub-makefile targets were not built"
    FAIL=1
fi

# Check that the sub-make was NOT running as a worker job
if echo "$STATUS" | grep -q "worker.*busy.*smak\|worker.*busy.*make"; then
    echo "  FAIL: Sub-make was spawned to a worker (should be handled as built-in)"
    FAIL=1
else
    echo "  PASS: Sub-make was NOT spawned to a worker"
fi

# Clean up
rm -f subdir/target1.txt subdir/target2.txt
rm -f nested-f-target1.txt nested-f-target2.txt
rm -f /tmp/nested-C-output.txt /tmp/nested-f-output.txt

echo ""
if [ $FAIL -eq 0 ]; then
    echo "All nested make tests passed!"
    exit 0
else
    echo "Some tests failed"
    exit 1
fi
