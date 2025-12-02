#!/bin/bash
# Test readline functionality and print command with $(VAR) translation

echo "Testing print command with variable translation..."
echo ""

cat <<'EOF' | ./smak -Kf Makefile.test -Kd
print "Makefile variables:"
print "CC = $(CC)"
print "CFLAGS = $(CFLAGS)"
print "Combined: $(CC) $(CFLAGS)"
print keys %MV
print scalar(keys %MV) . " variables defined"
quit
EOF
