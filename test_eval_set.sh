#!/bin/bash
# Test eval and set commands

echo "Testing eval and set commands..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -d
set
eval $timeout = 10
set
eval 2 + 2
quit
EOF
