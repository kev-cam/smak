#!/bin/bash
# Test that phony targets can be run repeatedly without being cached

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMAK="$SCRIPT_DIR/../smak"

TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

cd $TESTDIR

# Create a simple Makefile with a phony clean target
cat > Makefile << 'EOF'
.PHONY: clean

all: foo.txt

foo.txt:
	echo "hello" > foo.txt

clean:
	rm -f foo.txt
	@echo "Cleaned"
EOF

echo "Test 1: First clean should work"
output=$(SMAK_CACHE_DIR=0 $SMAK clean 2>&1)
echo "$output" | grep -q "Cleaned"
if [ $? -ne 0 ]; then
    echo "FAIL: First clean didn't run"
    echo "Output: $output"
    exit 1
fi

echo "Test 2: Creating foo.txt"
SMAK_CACHE_DIR=0 $SMAK all > /dev/null 2>&1
if [ ! -f foo.txt ]; then
    echo "FAIL: foo.txt was not created"
    exit 1
fi

echo "Test 3: Second clean should work (not cached)"
output=$(SMAK_CACHE_DIR=0 $SMAK clean 2>&1)
echo "$output" | grep -q "Cleaned"
if [ $? -ne 0 ]; then
    echo "FAIL: Second clean didn't run (likely cached)"
    echo "Output: $output"
    exit 1
fi

if [ -f foo.txt ]; then
    echo "FAIL: foo.txt still exists after second clean"
    exit 1
fi

echo "Test 4: Creating foo.txt again"
SMAK_CACHE_DIR=0 $SMAK all > /dev/null 2>&1

echo "Test 5: Third clean should work"
output=$(SMAK_CACHE_DIR=0 $SMAK clean 2>&1)
echo "$output" | grep -q "Cleaned"
if [ $? -ne 0 ]; then
    echo "FAIL: Third clean didn't run"
    echo "Output: $output"
    exit 1
fi

echo "All tests passed"
