#!/bin/bash
# Test that recursive calls are optimized in parallel mode

cd "$(dirname "$0")"

# Create test directories
mkdir -p test-rec-1 test-rec-2

# Create sub-Makefiles
cat > test-rec-1/Makefile << 'MAKEFILE'
all:
	@echo "Built in test-rec-1"
clean:
	@echo "Cleaned test-rec-1"
MAKEFILE

cat > test-rec-2/Makefile << 'MAKEFILE'
all:
	@echo "Built in test-rec-2"
clean:
	@echo "Cleaned test-rec-2"
MAKEFILE

# Create main Makefile with recursive calls
cat > Makefile.recursive << 'MAKEFILE'
all:
	${USR_SMAK_SCRIPT:-smak} -C test-rec-1 all && ${USR_SMAK_SCRIPT:-smak} -C test-rec-2 all

clean:
	${USR_SMAK_SCRIPT:-smak} -C test-rec-1 clean && ${USR_SMAK_SCRIPT:-smak} -C test-rec-2 clean
MAKEFILE

# Test in parallel mode
echo "Testing parallel mode (-j2):"
SMAK_ASSERT_NO_SPAWN=1 ${USR_SMAK_SCRIPT:-smak} -f Makefile.recursive -j2 clean
result=$?

# Cleanup
rm -rf test-rec-1 test-rec-2 Makefile.recursive

if [ $result -eq 0 ]; then
    echo "✓ PASS: Built-ins used in parallel mode"
    exit 0
else
    echo "✗ FAIL: Built-ins not used in parallel mode"
    exit 1
fi
