#!/bin/bash
# Test dry-run, make-cmp, and ! commands

echo "Testing new commands..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -Kd
dry-run test.o
! echo "Hello from shell"
! ls -la Makefile.nested
quit
EOF
