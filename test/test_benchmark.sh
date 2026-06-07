#!/bin/bash
# Test worker communication benchmark

echo "Testing worker benchmark"

# Use the standalone worker speed test we created earlier
cd /usr/local/src/smak/test

if [ ! -f test_worker_speed.pl ]; then
    echo "✗ test_worker_speed.pl not found"
    exit 1
fi

# Run the worker speed test
timeout 15 ./test_worker_speed.pl 2>&1 | tee /tmp/bench_output.log
status=$?

if [ $status -ne 0 ]; then
    echo "✗ Worker speed test failed with exit code $status"
    exit 1
fi

# Check that worker connected
if grep -q "Worker connected" /tmp/bench_output.log; then
    echo "✓ Worker connected"
else
    echo "✗ Worker did not connect"
    exit 1
fi

# Check that commands completed
if grep -q "Completed 100 commands" /tmp/bench_output.log; then
    echo "✓ Commands completed"
else
    echo "✗ Commands did not complete"
    exit 1
fi

# Check that throughput was reported
if grep -q "Throughput:" /tmp/bench_output.log; then
    echo "✓ Throughput reported"
else
    echo "✗ Throughput not reported"
    exit 1
fi

# Extract and display the results
echo ""
echo "Worker benchmark results:"
grep -E "(Completed|Send time|Recv time|Throughput)" /tmp/bench_output.log

# Check if throughput is reasonable (should be > 10 commands/sec with TCP_NODELAY)
throughput=$(grep "Throughput:" /tmp/bench_output.log | awk '{print $2}')
if [ -n "$throughput" ]; then
    # Use bc for floating point comparison
    if echo "$throughput > 15" | bc -l | grep -q 1; then
        echo "✓ Throughput is reasonable (${throughput} cmd/s)"
    else
        echo "⚠ Throughput is low (${throughput} cmd/s, expected > 15)"
    fi
fi

# Clean up
rm -f /tmp/bench_output.log

echo ""
echo "Worker benchmark test PASSED"
exit 0
