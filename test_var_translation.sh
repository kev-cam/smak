#!/bin/bash
# Test print command with $(VAR) translation

echo "Testing print command with \$(VAR) translation..."
echo ""

# Note: We need to set %MV hash for this to work
cat <<'EOF' | ./smak -f Makefile.test -Kd
print "Testing $(CC) translation..."
print $MV{CC} = "gcc"
print "CC is: $(CC)"
quit
EOF
