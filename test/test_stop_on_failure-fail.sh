#!/bin/bash
# Test stop-on-failure -fail version
# This test EXPECTS failure - it verifies that without -k, builds actually stop
# The test passes if success3.txt IS built (meaning stop-on-failure is broken)

cd "$(dirname "$0")"
SMAK=${USR_SMAK_SCRIPT:-smak}

# Clean up
rm -f success1.txt success2.txt success3.txt
$SMAK -f Makefile.stop_on_failure clean 2>/dev/null

# Run WITHOUT -k - should stop on first failure
$SMAK -f Makefile.stop_on_failure -j2 2>/dev/null

# This -fail test passes (exits 0) if stop-on-failure is BROKEN
# i.e., if success3.txt WAS built when it shouldn't have been
if [ -f success3.txt ]; then
    echo "Stop-on-failure is broken: success3.txt was built after failure"
    rm -f success1.txt success2.txt success3.txt
    exit 0  # -fail test passes when the feature is broken
else
    echo "Stop-on-failure is working correctly"
    rm -f success1.txt success2.txt success3.txt
    exit 1  # -fail test fails when the feature is working
fi
