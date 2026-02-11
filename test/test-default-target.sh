#!/bin/bash
# Test default target selection - should skip special targets and variables
set -e

TEST_DIR="test-default-target-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

cleanup() {
    cd "$SCRIPT_DIR"
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "Testing default target selection..."

# Test 1: Target with unexpanded variable should be skipped
echo ""
echo "Test 1: Target with \$(VAR) should be skipped"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

cat > Makefile << 'EOF'
$(VERBOSE).SILENT:

all: foo.o
	@echo "Building all"

foo.o: foo.c
	gcc -c foo.c
EOF

touch foo.c

# Get default target
DEFAULT=$(perl -I../.. -MSmak -e 'Smak::parse_makefile("Makefile"); print Smak::get_default_target() || "NONE"')

if [ "$DEFAULT" = "all" ]; then
    echo "✓ PASS: Default target is 'all' (skipped \$(VERBOSE).SILENT)"
else
    echo "✗ FAIL: Default target is '$DEFAULT', expected 'all'"
    exit 1
fi

cd ..
rm -rf "$TEST_DIR"

# Test 2: Special target starting with . should be skipped
echo ""
echo "Test 2: Target starting with . should be skipped"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

cat > Makefile << 'EOF'
.PHONY: clean

.SILENT:

all: foo.o
	@echo "Building all"

foo.o: foo.c
	gcc -c foo.c
EOF

touch foo.c

DEFAULT=$(perl -I../.. -MSmak -e 'Smak::parse_makefile("Makefile"); print Smak::get_default_target() || "NONE"')

if [ "$DEFAULT" = "all" ]; then
    echo "✓ PASS: Default target is 'all' (skipped .SILENT)"
else
    echo "✗ FAIL: Default target is '$DEFAULT', expected 'all'"
    exit 1
fi

cd ..
rm -rf "$TEST_DIR"

# Test 3: Pattern rules should be skipped
echo ""
echo "Test 3: Pattern rules should be skipped"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

cat > Makefile << 'EOF'
%: RCS/%,v
	co $@

all: foo.o
	@echo "Building all"

foo.o: foo.c
	gcc -c foo.c
EOF

touch foo.c

DEFAULT=$(perl -I../.. -MSmak -e 'Smak::parse_makefile("Makefile"); print Smak::get_default_target() || "NONE"')

if [ "$DEFAULT" = "all" ]; then
    echo "✓ PASS: Default target is 'all' (skipped pattern rule)"
else
    echo "✗ FAIL: Default target is '$DEFAULT', expected 'all'"
    exit 1
fi

cd ..
rm -rf "$TEST_DIR"

# Test 4: .PHONY target is valid default (matching GNU make behavior)
echo ""
echo "Test 4: .PHONY target is valid default target"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

cat > Makefile << 'EOF'
.PHONY: clean

%: RCS/%
	co $@

clean:
	rm -f *.o
EOF

DEFAULT=$(perl -I../.. -MSmak -e 'Smak::parse_makefile("Makefile"); print Smak::get_default_target() || "NONE"')

if [ "$DEFAULT" = "clean" ]; then
    echo "✓ PASS: Default target is 'clean' (.PHONY targets are valid defaults)"
else
    echo "✗ FAIL: Default target is '$DEFAULT', expected 'clean'"
    exit 1
fi

cd ..

echo ""
echo "All default target tests passed!"
exit 0
