#!/bin/bash
# Test the built-in worker protocol test suite (smak --test-worker)

echo "Testing worker protocol via smak --test-worker"

cd "$(dirname "$0")"

# Run smak --test-worker
output=$(timeout 15 ${USR_SMAK_SCRIPT:-../smak} --test-worker 2>&1)
status=$?

echo "$output"

if [ $status -ne 0 ]; then
    echo "FAIL: smak --test-worker exited with code $status"
    exit 1
fi

# Check all tests passed
if echo "$output" | grep -q "0 failed"; then
    echo "All worker protocol tests passed"
    exit 0
else
    echo "FAIL: Some worker protocol tests failed"
    exit 1
fi
