#!/bin/bash
# Test auto-rescan functionality

echo "Testing auto-rescan detection of deleted files..."
echo ""

cd "$(dirname "$0")"

# Create a simple test Makefile
cat > Makefile.autorescan << 'EOF'
all: test_auto.o

test_auto.o: test_auto.c
	@echo "Building test_auto.o from test_auto.c"
	@cp test_auto.c test_auto.o
	@echo "Built test_auto.o"

clean:
	mv test_auto.o  test_auto.o-old ; exit 0
EOF

# Create source file
echo "int main() { return 0; }" > test_auto.c

# Run smak in interactive CLI mode with job server
SMAK_DEBUG=1 ../smak -f Makefile.autorescan -j2 -cli 

if [ -f test_auto.o ] ; then
    exit 0
else
    exit 1
fi
