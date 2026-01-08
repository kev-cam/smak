#!/bin/bash
# Test auto-rescan functionality

echo "Testing auto-rescan detection of deleted files..."
echo ""

cd "$(dirname "$0")"

# Run smak in interactive debug mode with job server
# This will be automated by test runner using test_autorescan.script
# Note: Makefile.autorescan and test_auto.c are permanent test files
SMAK_DEBUG=1 ${USR_SMAK_SCRIPT:-smak} -f Makefile.autorescan -j2 -Kd

if [ -f test_auto.o ] ; then
    rm -f test_auto.o test_auto.o-old
    exit 0
else
    exit 1
fi
