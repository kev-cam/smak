#!/bin/bash
# Test standalone scanner mode

echo "Testing standalone scanner mode..."
echo ""

cd "$(dirname "$0")"

# Clean up any leftover test files
rm -f test_scan_file.txt

# Start scanner in background
${USR_SMAK_SCRIPT:-smak} -scanner test_scan_file.txt > /tmp/scanner-output-$$.txt 2>&1 &
SCANNER_PID=$!

# Give scanner time to start (increased for slower systems)
sleep 2

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

# Verify events (allow optional " (via FUSE)" suffix)
if grep -qE "CREATE:$SCANNER_PID:test_scan_file.txt( \(via FUSE\))?" /tmp/scanner-output-$$.txt && \
   grep -qE "MODIFY:$SCANNER_PID:test_scan_file.txt( \(via FUSE\))?" /tmp/scanner-output-$$.txt && \
   grep -qE "DELETE:$SCANNER_PID:test_scan_file.txt( \(via FUSE\))?" /tmp/scanner-output-$$.txt; then
    echo ""
    # Check if FUSE was used
    if grep -q "(via FUSE)" /tmp/scanner-output-$$.txt; then
        echo "✓ All events detected correctly (using FUSE monitoring)"
    else
        echo "✓ All events detected correctly (using polling)"
    fi
    rm -f /tmp/scanner-output-$$.txt
    exit 0
else
    echo ""
    echo "✗ FAIL: Not all events detected"
    echo "Expected CREATE, MODIFY, and DELETE events for PID $SCANNER_PID"
    rm -f /tmp/scanner-output-$$.txt
    exit 1
fi
