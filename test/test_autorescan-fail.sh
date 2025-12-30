#!/bin/bash
# Test auto-rescan failure case - missing source file

echo "Testing auto-rescan with missing source (should fail)..."
echo ""

cd "$(dirname "$0")"

# Create a simple test Makefile
cat > Makefile.autorescan-fail << 'EOF'
all: test_auto_fail.o

test_auto_fail.o: test_auto_fail.c
	@echo "Building test_auto_fail.o from test_auto_fail.c"
	@cp test_auto_fail.c test_auto_fail.o
	@echo "Built test_auto_fail.o"
EOF

# Don't create the source file - this should cause the build to fail

# Run smak in interactive debug mode with job server
# This will be automated by test runner using test_autorescan-fail.script
SMAK_DEBUG=1 ../smak -f Makefile.autorescan-fail -j2 -Kd

# This test should fail (build should not succeed)
if [ -f test_auto_fail.o ] ; then
    # File was created - test failed (we expected failure)
    rm -f test_auto_fail.o Makefile.autorescan-fail
    exit 0  # Report success (failure was expected)
else
    # File not created - test succeeded (failure occurred as expected)
    rm -f Makefile.autorescan-fail
    exit 1  # Report failure (this means the test worked - build failed as expected)
fi
