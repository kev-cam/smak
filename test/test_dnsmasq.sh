#!/bin/bash
# Test building dnsmasq project with smak
# This is a regression test to ensure dnsmasq builds correctly

echo "Testing dnsmasq build with smak..."
echo ""

cd "$(dirname "$0")"
FAILED=0

# Check if dnsmasq directory exists
DNSMASQ_DIR="/usr/local/src/dnsmasq"
if [ ! -d "$DNSMASQ_DIR" ]; then
    echo "SKIP: dnsmasq directory not found at $DNSMASQ_DIR"
    exit 77
fi

echo "Test: Build dnsmasq with smak"
cd "$DNSMASQ_DIR" || exit 1

# First, clean
echo "  Running clean..."
${USR_SMAK_SCRIPT:-smak} clean >/dev/null 2>&1 || true

# Now try to build and time it
echo "  Building..."
START_TIME=$(date +%s)
BUILD_OUTPUT=$(${USR_SMAK_SCRIPT:-smak} 2>&1)
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

# Check for undefined variable errors
if echo "$BUILD_OUTPUT" | grep -q "not found\|missing.*operand"; then
    echo "  ✗ FAIL: Found unexpanded variables or missing operands"
    echo "Errors:"
    echo "$BUILD_OUTPUT" | grep -E "not found|missing.*operand" | head -5
    ((FAILED++))
else
    echo "  ✓ PASS: No unexpanded variable errors"
fi

# Check for successful build
if [ $EXIT_CODE -eq 0 ]; then
    echo "  ✓ PASS: Build completed successfully"
else
    echo "  ✗ FAIL: Build failed with exit code $EXIT_CODE"
    echo "Build output (last 20 lines):"
    echo "$BUILD_OUTPUT" | tail -20
    ((FAILED++))
fi

# If sequential build succeeded, test parallel builds
if [ $EXIT_CODE -eq 0 ]; then
    # Calculate timeout as 2x sequential build time (minimum 30s)
    TIMEOUT=$((SEQUENTIAL_TIME * 2))
    [ $TIMEOUT -lt 30 ] && TIMEOUT=30
    echo ""
    echo "Using timeout of ${TIMEOUT}s for parallel builds"

    # Test -j4 build
    echo ""
    echo "Test: Clean and rebuild with -j4"
    echo "  Running clean..."
    ${USR_SMAK_SCRIPT:-smak} clean >/dev/null 2>&1 || true

    echo "  Building with -j4 (timeout ${TIMEOUT}s)..."
    BUILD_OUTPUT_J4=$(timeout $TIMEOUT ${USR_SMAK_SCRIPT:-smak} -j4 2>&1)
    EXIT_CODE_J4=$?

    if [ $EXIT_CODE_J4 -eq 0 ]; then
        echo "  ✓ PASS: -j4 build completed successfully"
    elif [ $EXIT_CODE_J4 -eq 124 ]; then
        echo "  ✗ FAIL: -j4 build timed out after ${TIMEOUT}s"
        ((FAILED++))
    else
        echo "  ✗ FAIL: -j4 build failed with exit code $EXIT_CODE_J4"
        echo "-j4 build output (last 20 lines):"
        echo "$BUILD_OUTPUT_J4" | tail -20
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
    echo "Note: This is a regression test for dnsmasq build support"
    exit 1
fi
