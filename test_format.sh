#!/bin/bash
# Test $MV{} to $() conversion in various contexts

echo "Testing format conversion in different contexts..."
echo ""

cat <<'EOF' | ./smak -Kf Makefile.nested -Kd
print "Direct access: " . $MV{CC}
print "In string: The compiler is $(CC)"
print "Multiple vars: $(CC) $(CFLAGS)"
print "Nested: $(CMD) expands to " . $MV{CMD}
show test.o
quit
EOF
