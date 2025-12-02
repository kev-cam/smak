#!/bin/bash
# Test print command with simple strings and timeout

echo "Testing print command fixes..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -d
print "a"
print 2 + 2
print "CC = $(CC)"
quit
EOF
