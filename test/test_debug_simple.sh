#!/bin/bash
# Test interactive debug mode - simplified version

echo "Testing interactive debug mode..."
echo ""

cd "$(dirname "$0")"
exec ${USR_SMAK_SCRIPT:-smak} -Kd
