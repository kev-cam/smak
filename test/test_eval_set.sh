#!/bin/bash
# Test eval and set commands

echo "Testing eval and set commands..."
echo ""

cat <<'EOF' | ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Kd
set
eval $timeout = 10
set
eval 2 + 2
quit
EOF
