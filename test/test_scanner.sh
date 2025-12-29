#!/bin/bash
# Test standalone scanner mode

echo "Testing standalone scanner mode..."
echo ""

cd "$(dirname "$0")"

# Clean up any leftover test files
rm -f test_scan_file.txt

# Start scanner in background
../smak -scanner test_scan_file.txt > /tmp/scanner-output-$$.txt 2>&1 &
SCANNER_PID=$!

# Give scanner time to start
sleep 1

# Test CREATE event
echo "Creating file..."
touch test_scan_file.txt
sleep 1.5

# Test MODIFY event
echo "Modifying file..."
echo "content" > test_scan_file.txt
sleep 1.5

# Test DELETE event
echo "Deleting file..."
rm -f test_scan_file.txt
sleep 1.5

# Kill scanner
kill $SCANNER_PID 2>/dev/null
wait $SCANNER_PID 2>/dev/null

# Check output
echo ""
echo "Scanner output:"
cat /tmp/scanner-output-$$.txt

# Verify events
if grep -q "CREATE:$SCANNER_PID:test_scan_file.txt" /tmp/scanner-output-$$.txt && \
   grep -q "MODIFY:$SCANNER_PID:test_scan_file.txt" /tmp/scanner-output-$$.txt && \
   grep -q "DELETE:$SCANNER_PID:test_scan_file.txt" /tmp/scanner-output-$$.txt; then
    echo ""
    echo "✓ All events detected correctly"
    rm -f /tmp/scanner-output-$$.txt
    exit 0
else
    echo ""
    echo "✗ FAIL: Not all events detected"
    echo "Expected CREATE, MODIFY, and DELETE events for PID $SCANNER_PID"
    rm -f /tmp/scanner-output-$$.txt
    exit 1
fi
