#!/bin/bash
# Test interactive debug mode

echo "Testing interactive debug mode..."
echo ""

cd "$(dirname "$0")"

# Run smak in debug mode with test Makefile
# Use script automation (scripts/test_debug.script) for automated testing
exec ${USR_SMAK_SCRIPT:-smak} -f Makefile.test -Kd
