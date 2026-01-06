#!/bin/bash
# Test SSH workers on localhost

set -e

echo "Testing SSH workers on localhost"
echo ""

# Check if SSH to localhost works without password
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true 2>/dev/null; then
    echo "SKIP: SSH to localhost not configured (requires passwordless SSH)"
    echo "To enable: ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa (if needed)"
    echo "           ssh-copy-id localhost"
    exit 77  # Special exit code for skipped tests
fi

# Create test directory
TEST_DIR=$(mktemp -d /tmp/smak_ssh_test.XXXXXX)
# Don't clean up on error so we can debug
trap "[ \$? -eq 0 ] && rm -rf $TEST_DIR || echo 'Test dir preserved: $TEST_DIR'" EXIT

cd $TEST_DIR

# Create a simple Makefile without complex variable substitution
cat > Makefile << 'EOF'
.PHONY: all clean

all: file1.o file2.o file3.o
	@echo "All targets built"

%.o: %.c
	@echo "Compiling $<"
	@echo "/* compiled */" > $@

clean:
	rm -f *.o
EOF

# Create source files
echo "int main() { return 0; }" > file1.c
echo "void func1() {}" > file2.c
echo "void func2() {}" > file3.c

echo "Running smak with SSH workers on localhost..."
# Ensure smak is in PATH on remote side by setting it via ssh
export PATH=/usr/local/src/smak:$PATH
timeout 30 /usr/local/src/smak/smak --ssh=localhost -j2 all > test_output.log 2>&1
sts=$?

if [ $sts -ne 0 ]; then
    echo "FAILED: smak exited with status $sts"
    cat test_output.log
    exit 1
fi

# Verify output - with parallel builds, individual messages may not appear
# but we should see "All targets built" which means all dependencies completed
if ! grep -q "All targets built" test_output.log; then
    echo "FAILED: Expected 'All targets built' in output"
    echo "Output was:"
    cat test_output.log
    exit 1
fi

# Verify that workers connected via SSH
if ! grep -q "Worker.*shutting down" test_output.log; then
    echo "WARNING: No worker shutdown messages (might not be using SSH workers)"
fi

# Verify .o files were created
if [ ! -f file1.o ] || [ ! -f file2.o ] || [ ! -f file3.o ]; then
    echo "FAILED: Not all .o files were created"
    ls -la
    exit 1
fi

echo "Testing clean target over SSH..."
timeout 30 /usr/local/src/smak/smak --ssh=localhost clean > clean_output.log 2>&1
sts=$?

if [ $sts -ne 0 ]; then
    echo "FAILED: clean target exited with status $sts"
    cat clean_output.log
    exit 1
fi

# Verify .o files were removed
if [ -f file1.o ] || [ -f file2.o ] || [ -f file3.o ]; then
    echo "FAILED: .o files were not removed by clean"
    ls -la
    exit 1
fi

echo "SUCCESS: SSH workers on localhost work correctly"
exit 0
