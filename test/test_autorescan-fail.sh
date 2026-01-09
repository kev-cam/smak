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
SMAK_DEBUG=1 ${USR_SMAK_SCRIPT:-smak} -f Makefile.autorescan-fail -j2 -Kd

# This test expects the build to fail (source file is missing)
if [ -f test_auto_fail.o ] ; then
    # File was created - build succeeded when it should have failed
    rm -f test_auto_fail.o Makefile.autorescan-fail
    exit 1  # Test failed - build should not have succeeded
else
    # File not created - build correctly failed as expected
    rm -f Makefile.autorescan-fail
    exit 0  # Test passed - build failed as expected
fi
