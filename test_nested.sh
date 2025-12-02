#!/bin/bash
# Test nested variable expansion and $MV{} to $() conversion

echo "Testing nested variable expansion..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -d
print "CC = $(CC)"
print "CFLAGS = $(CFLAGS)"
print "COMPILE = $(COMPILE)"
print "CMD = $(CMD)"
rule test.o
print $fixed_rule{"Makefile.nested\ttest.o"}
quit
EOF
