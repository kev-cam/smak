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

# Run smak - build should fail because source file doesn't exist
${USR_SMAK_SCRIPT:-smak} -f Makefile.autorescan-fail -j2 all 2>/dev/null

# This test expects the build to fail (source file is missing)
# For -fail tests: exit non-zero = test passed (failure occurred), exit 0 = test failed
if [ -f test_auto_fail.o ] ; then
    # File was created - build succeeded when it should have failed
    rm -f test_auto_fail.o Makefile.autorescan-fail
    exit 0  # -fail test FAILED (build wrongly succeeded)
else
    # File not created - build correctly failed as expected
    rm -f Makefile.autorescan-fail
    exit 1  # -fail test PASSED (build correctly failed)
fi
