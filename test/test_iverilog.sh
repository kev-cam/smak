#!/bin/bash
# Test building iverilog project with smak
# This is a regression test - iverilog used to build successfully

echo "Testing iverilog build with smak..."
echo ""

cd "$(dirname "$0")"
FAILED=0

# Check if iverilog directory exists
IVERILOG_DIR="/usr/local/src/iverilog"
if [ ! -d "$IVERILOG_DIR" ]; then
    echo "  ✗ FAIL: iverilog directory not found at $IVERILOG_DIR"
    exit 1
fi

echo "Test: Build iverilog with smak"
cd "$IVERILOG_DIR" || exit 1

# First, clean
echo "  Running clean..."
${USR_SMAK_SCRIPT:-smak}/smak clean >/dev/null 2>&1 || true

# Now try to build and time it
echo "  Building..."
START_TIME=$(date +%s)
BUILD_OUTPUT=$(${USR_SMAK_SCRIPT:-smak}/smak 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s)
SEQUENTIAL_TIME=$((END_TIME - START_TIME))
echo "  Sequential build took ${SEQUENTIAL_TIME}s"

# Check for variable expansion iteration limit warning
if echo "$BUILD_OUTPUT" | grep -q "iteration limit"; then
    echo "  ✗ FAIL: Hit variable expansion iteration limit"
    echo "Warning message:"
    echo "$BUILD_OUTPUT" | grep -A 2 "iteration limit"
    ((FAILED++))
else
    echo "  ✓ PASS: No iteration limit warning"
fi

# Check for undefined variable errors (DESTDIR, includedir, srcdir)
if echo "$BUILD_OUTPUT" | grep -q "DESTDIR: not found\|includedir: not found\|srcdir: not found"; then
    echo "  ✗ FAIL: Found unexpanded variables passed to shell"
    echo "Errors:"
    echo "$BUILD_OUTPUT" | grep "not found" | head -3
    ((FAILED++))
else
    echo "  ✓ PASS: No unexpanded variable errors"
fi

# Check for successful build
if [ $EXIT_CODE -eq 0 ]; then
    echo "  ✓ PASS: Build completed successfully"
else
    echo "  ✗ FAIL: Build failed with exit code $EXIT_CODE"
    ((FAILED++))
fi

# If sequential build succeeded, test parallel builds
if [ $EXIT_CODE -eq 0 ]; then
    # Calculate timeout as 2x sequential build time
    TIMEOUT=$((SEQUENTIAL_TIME * 2))
    echo ""
    echo "Using timeout of ${TIMEOUT}s for parallel builds (2x sequential time)"

    # Test -j1 build
    echo ""
    echo "Test: Clean and rebuild with -j1"
    echo "  Running clean..."
    ${USR_SMAK_SCRIPT:-smak}/smak clean >/dev/null 2>&1 || true

    echo "  Building with -j1 (timeout ${TIMEOUT}s)..."
    BUILD_OUTPUT_J1=$(timeout $TIMEOUT ${USR_SMAK_SCRIPT:-smak}/smak -j1 2>&1)
    EXIT_CODE_J1=$?

    if [ $EXIT_CODE_J1 -eq 0 ]; then
        echo "  ✓ PASS: -j1 build completed successfully"
    elif [ $EXIT_CODE_J1 -eq 124 ]; then
        echo "  ✗ FAIL: -j1 build timed out after ${TIMEOUT}s"
        ((FAILED++))
    else
        echo "  ✗ FAIL: -j1 build failed with exit code $EXIT_CODE_J1"
        echo "-j1 build output:"
        echo "$BUILD_OUTPUT_J1"
        ((FAILED++))
    fi

    # Test -j4 build
    echo ""
    echo "Test: Clean and rebuild with -j4"
    echo "  Running clean..."
    ${USR_SMAK_SCRIPT:-smak}/smak clean >/dev/null 2>&1 || true

    echo "  Building with -j4 (timeout ${TIMEOUT}s)..."
    BUILD_OUTPUT_J4=$(timeout $TIMEOUT ${USR_SMAK_SCRIPT:-smak}/smak -j4 2>&1)
    EXIT_CODE_J4=$?

    if [ $EXIT_CODE_J4 -eq 0 ]; then
        echo "  ✓ PASS: -j4 build completed successfully"
    elif [ $EXIT_CODE_J4 -eq 124 ]; then
        echo "  ✗ FAIL: -j4 build timed out after ${TIMEOUT}s"
        ((FAILED++))
    else
        echo "  ✗ FAIL: -j4 build failed with exit code $EXIT_CODE_J4"
        echo "-j4 build output:"
        echo "$BUILD_OUTPUT_J4"
        ((FAILED++))
    fi
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Failed $FAILED test(s)"
    echo ""
    echo "Note: This is a regression - iverilog used to build successfully with smak"
    exit 1
fi
