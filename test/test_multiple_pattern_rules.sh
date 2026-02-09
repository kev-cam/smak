#!/bin/bash
# Test multiple pattern rules for the same target

echo "Testing multiple pattern rules..."
echo ""

# Create test directory
rm -rf test_multi_pattern
mkdir -p test_multi_pattern
cd test_multi_pattern

# Create test source files
cat > foo.c <<'EOC'
int foo_c() { return 1; }
EOC

cat > bar.cc <<'EOC'
int bar_cc() { return 2; }
EOC

cat > baz.cpp <<'EOC'
int baz_cpp() { return 3; }
EOC

# Create Makefile with multiple pattern rules
cat > Makefile <<'EOM'
.PHONY: all clean

all: foo.o bar.o baz.o

clean:
	rm -f *.o

# Note: smak should have built-in rules for these, but we can also define our own
EOM

# Pre-check: Validate smak dry-run matches make (exits on mismatch)
${USR_SMAK_SCRIPT:-smak} --check=quiet all || {
    echo "FAIL: smak --check=quiet validation failed (dry-run mismatch with make)"
    exit 1
}

# Test 1: Dry-run should show correct commands for each source type
echo "Test 1: Dry-run with multiple source types"
OUTPUT=$(${USR_SMAK_SCRIPT:-smak} -n all 2>&1)

if echo "$OUTPUT" | grep -q "foo.c"; then
    echo "  ✓ PASS: foo.c rule found"
else
    echo "  ✗ FAIL: foo.c rule not found"
    echo "Output: $OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -q "bar.cc"; then
    echo "  ✓ PASS: bar.cc rule found"
else
    echo "  ✗ FAIL: bar.cc rule not found"
    echo "Output: $OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -q "baz.cpp"; then
    echo "  ✓ PASS: baz.cpp rule found"
else
    echo "  ✗ FAIL: baz.cpp rule not found"
    echo "Output: $OUTPUT"
    exit 1
fi

# Test 2: Actual build should work
echo ""
echo "Test 2: Actual build"
${USR_SMAK_SCRIPT:-smak} clean > /dev/null 2>&1
OUTPUT=$(${USR_SMAK_SCRIPT:-smak} all 2>&1)
EXITCODE=$?

if [ $EXITCODE -eq 0 ]; then
    echo "  ✓ PASS: Build succeeded"
else
    echo "  ✗ FAIL: Build failed with exit code $EXITCODE"
    echo "Output: $OUTPUT"
    exit 1
fi

# Check that all object files were created
if [ -f foo.o ] && [ -f bar.o ] && [ -f baz.o ]; then
    echo "  ✓ PASS: All object files created"
else
    echo "  ✗ FAIL: Not all object files created"
    ls -la *.o 2>&1
    exit 1
fi

# Test 3: Missing source file should fall back to first rule (.c)
echo ""
echo "Test 3: Missing source - fallback to first rule"
rm -f test.c test.cc test.cpp test.o
OUTPUT=$(${USR_SMAK_SCRIPT:-smak} -n test.o 2>&1)

if echo "$OUTPUT" | grep -q "test.c"; then
    echo "  ✓ PASS: Falls back to .c rule when no source exists"
else
    echo "  ✗ FAIL: Did not fall back to .c rule"
    echo "Output: $OUTPUT"
    exit 1
fi

# Cleanup
cd ..
rm -rf test_multi_pattern

echo ""
echo "All tests passed!"
