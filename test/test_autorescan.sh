#!/bin/bash
# Test auto-rescan functionality
# This test verifies that auto-rescan detects deleted files under a running job-server

echo "Testing auto-rescan detection of deleted files..."
echo ""

cd "$(dirname "$0")"

# Clean up any previous test artifacts
rm -f test_auto.o test_auto.o-old

# Pre-check: Validate smak dry-run matches make (exits on mismatch)
${USR_SMAK_SCRIPT:-smak} --check=quiet -f Makefile.autorescan all || {
    echo "FAIL: smak --check=quiet validation failed (dry-run mismatch with make)"
    exit 1
}

# Run the script-based test using -Ks (CLI mode with script)
# The script:
#   1. Builds test_auto.o
#   2. Enables auto-rescan
#   3. Moves test_auto.o away (simulating deletion)
#   4. Rebuilds - auto-rescan should detect the deletion and rebuild
${USR_SMAK_SCRIPT:-smak} -f Makefile.autorescan -Ks scripts/test_autorescan.script -j 2 2>/dev/null

if [ -f test_auto.o ] ; then
    rm -f test_auto.o test_auto.o-old
    exit 0
else
    echo "FAIL: test_auto.o was not rebuilt after deletion"
    exit 1
fi
