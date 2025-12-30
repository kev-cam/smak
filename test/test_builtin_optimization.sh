#!/bin/bash
# Test that recursive smak -C calls use built-in optimization

echo "Testing built-in recursive call optimization..."
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

# Run test - built-ins should be used, so SMAK_ASSERT_NO_SPAWN should NOT trigger
SMAK_ASSERT_NO_SPAWN=1 ../smak -f Makefile.builtin-test clean 2>&1
result=$?

# Cleanup
rm -rf subdir1 subdir2 subdir3 Makefile.builtin-test

if [ $result -eq 0 ]; then
    echo ""
    echo "✓ Built-ins used (SMAK_ASSERT_NO_SPAWN passed)"
    exit 0
else
    echo ""
    echo "✗ Built-ins NOT used (SMAK_ASSERT_NO_SPAWN failed)"
    exit 1
fi
