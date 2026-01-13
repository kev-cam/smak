#!/bin/bash
# Test auto-rescan functionality

echo "Testing auto-rescan detection of deleted files..."
echo ""

cd "$(dirname "$0")"

# Run smak to build test_auto.o
# Note: Makefile.autorescan and test_auto.c are permanent test files
${USR_SMAK_SCRIPT:-smak} -f Makefile.autorescan -j2 all 2>/dev/null

if [ -f test_auto.o ] ; then
    rm -f test_auto.o test_auto.o-old
    exit 0
else
    exit 1
fi
