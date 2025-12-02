#!/bin/bash
# Test echo control variable

echo "Testing echo control variable..."
echo ""

echo "Test 1: Check default value of echo (should be 0)"
cat <<'EOF' | ./smak -f Makefile.nested -d
set
quit
EOF

echo ""
echo "Test 2: Set echo to 1 and run commands (should echo them)"
cat <<'EOF' | ./smak -f Makefile.nested -d
eval $echo = 1
list
print $(CC)
set
quit
EOF

echo ""
echo "Test completed"
