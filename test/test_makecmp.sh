#!/bin/bash
# Test make-cmp command

echo "Testing make-cmp command..."
echo ""

cat <<'EOF' | ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Kd
make-cmp test.o
quit
EOF
