#!/bin/bash
# Test print command timeout

echo "Testing print timeout (this should timeout after 5 seconds)..."
echo ""

cat <<'EOF' | timeout 10 ./smak -f Makefile.nested -d
print while(1) { }
quit
EOF

echo ""
echo "Test completed (should have timed out)"
