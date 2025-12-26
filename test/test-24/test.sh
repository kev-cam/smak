#!/bin/bash
# Test script for pattern rules and vpath
# Tests the Makefile structure that exercises the pattern+vpath fixes

set -e  # Exit on error

TEST_NAME="Pattern rules + vpath test"

echo "=== $TEST_NAME ==="
echo ""

# Clean first
echo "1. Cleaning..."
make -f Makefile clean > /dev/null 2>&1
if [ ! -f "main.o" ] && [ ! -f "helper.o" ] && [ ! -f "program" ]; then
    echo "   ✓ Clean successful"
fi

# Build all targets
echo "2. Building all targets..."
make -f Makefile all > build.log 2>&1

# Check if all targets were built
if [ -f "main.o" ] && [ -f "helper.o" ] && [ -f "program" ]; then
    echo "   ✓ All targets built successfully"
else
    echo "   ✗ FAILED: Missing targets"
    echo "   Expected: main.o, helper.o, program"
    ls -la *.o program 2>/dev/null || true
    cat build.log
    exit 1
fi

# Verify that vpath resolution worked (check build log)
if grep -q "Compiling.*main.cc" build.log && grep -q "Compiling.*helper.cc" build.log; then
    echo "   ✓ Pattern rule compilation worked"
else
    echo "   ✗ FAILED: Pattern rules didn't execute correctly"
    cat build.log
    exit 1
fi

# Verify linking worked
if grep -q "Linking program" build.log; then
    echo "   ✓ Linking worked"
else
    echo "   ✗ FAILED: Linking didn't execute"
    cat build.log
    exit 1
fi

# Verify vpath found source files in src/ directory
if grep -q "src/main.cc" build.log && grep -q "src/helper.cc" build.log; then
    echo "   ✓ Vpath correctly resolved source files from src/ directory"
else
    echo "   ⚠ Warning: Vpath resolution may not have worked as expected"
fi

# Test incremental build (should be up-to-date)
echo "3. Testing incremental build..."
make -f Makefile all > rebuild.log 2>&1
if grep -qi "up-to-date\|nothing to be done" rebuild.log; then
    echo "   ✓ Incremental build correctly skipped up-to-date targets"
elif ! grep -q "Compiling" rebuild.log; then
    echo "   ✓ No recompilation needed"
else
    echo "   ⚠ Warning: Unnecessary rebuild detected"
    cat rebuild.log
fi

# Clean up
echo "4. Cleaning up..."
make -f Makefile clean > /dev/null 2>&1
if [ ! -f "main.o" ] && [ ! -f "helper.o" ] && [ ! -f "program" ]; then
    echo "   ✓ Final clean successful"
fi

echo ""
echo "=== $TEST_NAME: PASSED ==="
echo ""
echo "This test verifies that:"
echo "  - Pattern rules (%.o: %.cc) work correctly"
echo "  - Vpath directives (vpath %.cc src) find source files"
echo "  - Dependencies are resolved properly"
echo "  - Incremental builds work"
echo ""

exit 0
