#!/bin/bash
# Test print command with simple strings and timeout

echo "Testing print command fixes..."
echo ""

cat <<'EOF' | ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Kd
print "a"
print 2 + 2
print "CC = $(CC)"
quit
EOF
