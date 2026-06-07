#!/bin/bash
# Test nested make -C (recursive make) builds correctly
# Verifies: subdirectory builds, variable passing, multi-level nesting

SMAK="${USR_SMAK_SCRIPT:-smak}"

TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

cd "$TESTDIR"

# Create nested project structure:
#   top/
#     Makefile
#     lib/
#       Makefile
#       src/
#         Makefile

mkdir -p lib/src

# Inner-most Makefile: creates a .o file
cat > lib/src/Makefile << 'EOF'
all: util.o

util.o: util.c
	cp util.c util.o

clean:
	rm -f *.o

.PHONY: all clean
EOF

# Create source file
echo "/* util.c */" > lib/src/util.c

# Middle Makefile: delegates to src/ and creates lib.a
cat > lib/Makefile << 'LIBMAKE'
all: lib.a

lib.a:
	$(MAKE) -C src all
	@echo "built" > lib.a

clean:
	$(MAKE) -C src clean
	rm -f lib.a

.PHONY: all clean
LIBMAKE

# Top-level Makefile: delegates to lib/
cat > Makefile << 'TOPMAKE'
all: app

app: lib/lib.a
	@echo "linked" > app

lib/lib.a:
	$(MAKE) -C lib all

clean:
	$(MAKE) -C lib clean
	rm -f app

.PHONY: all clean
TOPMAKE

# Test 1: Full build from top level
echo "Test 1: Full nested build"
output=$($SMAK all 2>&1)
result=$?
if [ $result -ne 0 ]; then
    echo "FAIL: Build returned exit code $result"
    echo "Output: $output"
    exit 1
fi

# Verify all artifacts were created
for f in lib/src/util.o lib/lib.a app; do
    if [ ! -f "$f" ]; then
        echo "FAIL: Expected file $f was not created"
        echo "Output: $output"
        exit 1
    fi
done
echo "  PASS: All artifacts created"

# Test 2: Clean from top level
echo "Test 2: Nested clean"
output=$($SMAK clean 2>&1)
result=$?
if [ $result -ne 0 ]; then
    echo "FAIL: Clean returned exit code $result"
    echo "Output: $output"
    exit 1
fi

for f in lib/src/util.o lib/lib.a app; do
    if [ -f "$f" ]; then
        echo "FAIL: File $f should have been removed by clean"
        exit 1
    fi
done
echo "  PASS: All artifacts cleaned"

# Test 3: Dry-run should not create files
echo "Test 3: Dry-run nested build"
output=$($SMAK -n all 2>&1)
result=$?
if [ $result -ne 0 ]; then
    echo "FAIL: Dry-run returned exit code $result"
    echo "Output: $output"
    exit 1
fi

for f in lib/src/util.o lib/lib.a app; do
    if [ -f "$f" ]; then
        echo "FAIL: Dry-run created file $f"
        exit 1
    fi
done
echo "  PASS: Dry-run did not create files"

# Test 4: Rebuild works (idempotent)
echo "Test 4: Rebuild (idempotent)"
$SMAK all >/dev/null 2>&1
output=$($SMAK all 2>&1)
result=$?
if [ $result -ne 0 ]; then
    echo "FAIL: Rebuild returned exit code $result"
    echo "Output: $output"
    exit 1
fi
echo "  PASS: Rebuild succeeded"

echo ""
echo "All nested make tests passed"
