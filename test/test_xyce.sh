#!/bin/bash
# Test building Xyce project with smak
# This is a regression test - Xyce used to build successfully

echo "Testing Xyce build with smak..."
echo ""

cd "$(dirname "$0")"
FAILED=0

# Check if xyce-build directory exists
XYCE_BUILD_DIR="/usr/local/src/xyce-build"
if [ ! -d "$XYCE_BUILD_DIR" ]; then
    echo "  ✗ FAIL: xyce-build directory not found at $XYCE_BUILD_DIR"
    exit 1
fi

echo "Test: Build Xyce with smak"
cd "$XYCE_BUILD_DIR" || exit 1

# First, clean
echo "  Running clean..."
../../smak/smak clean >/dev/null 2>&1 || true

# Now try to build
echo "  Building..."
BUILD_OUTPUT=$(../../smak/smak 2>&1)
EXIT_CODE=$?

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

# If sequential build succeeded, test parallel build
if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "Test: Clean and rebuild with -j4"
    echo "  Running clean..."
    ../../smak/smak clean >/dev/null 2>&1 || true

    echo "  Building with -j4..."
    BUILD_OUTPUT_PARALLEL=$(../../smak/smak -j4 2>&1)
    EXIT_CODE_PARALLEL=$?

    if [ $EXIT_CODE_PARALLEL -eq 0 ]; then
        echo "  ✓ PASS: Parallel build completed successfully"
    else
        echo "  ✗ FAIL: Parallel build failed with exit code $EXIT_CODE_PARALLEL"
        echo "Parallel build output:"
        echo "$BUILD_OUTPUT_PARALLEL"
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
    echo "Note: This is a regression - Xyce used to build successfully with smak"
    exit 1
fi
