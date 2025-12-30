#!/bin/bash
# Test that SMAK_ASSERT_NO_SPAWN catches when built-ins are NOT used

echo "Testing SMAK_ASSERT_NO_SPAWN assertion (should fail)..."
echo ""

cd "$(dirname "$0")"

# Create test structure
mkdir -p subdir1 subdir2 subdir3

cat > subdir1/Makefile << 'SUBMAKE'
all:
	@echo "Building in subdir1"

clean:
	@echo "Cleaning subdir1"
	@rm -f *.o
SUBMAKE

cat > subdir2/Makefile << 'SUBMAKE'
all:
	@echo "Building in subdir2"

clean:
	@echo "Cleaning subdir2"
	@rm -f *.o
SUBMAKE

cat > subdir3/Makefile << 'SUBMAKE'
all:
	@echo "Building in subdir3"

clean:
	@echo "Cleaning subdir3"
	@rm -f *.o
SUBMAKE

cat > Makefile.builtin-test << 'MAINMAKE'
all:
	../smak -C subdir1 all && ../smak -C subdir2 all && ../smak -C subdir3 all

clean:
	../smak -C subdir1 clean && ../smak -C subdir2 clean && ../smak -C subdir3 clean
MAINMAKE

# Run test with SMAK_NO_BUILTINS to force spawning
# SMAK_ASSERT_NO_SPAWN should trigger and fail
SMAK_NO_BUILTINS=1 SMAK_ASSERT_NO_SPAWN=1 ../smak -f Makefile.builtin-test clean 2>&1 | grep -q "SMAK_ASSERT_NO_SPAWN"
result=$?

# Cleanup
rm -rf subdir1 subdir2 subdir3 Makefile.builtin-test

# For -fail tests, we expect the assertion to trigger (grep finds it = exit 0)
# which means the test correctly failed, so we exit non-zero to signal "passed"
if [ $result -eq 0 ]; then
    echo ""
    echo "✓ Assertion triggered correctly (built-ins disabled)"
    exit 1  # Exit non-zero to indicate -fail test passed
else
    echo ""
    echo "✗ Assertion did NOT trigger (expected failure)"
    exit 0  # Exit zero means -fail test actually failed
fi
