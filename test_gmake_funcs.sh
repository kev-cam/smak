#!/bin/bash
# Test gmake functions

echo "Testing gmake functions..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -Kd
print $(patsubst %.c,%.o,foo.c bar.c baz.c)
print $(subst .c,.o,test.c main.c)
print $(strip   foo   bar   baz  )
print $(filter %.c,foo.c bar.o baz.c test.h)
print $(filter-out %.o,foo.c bar.o baz.c)
print $(words foo bar baz test)
print $(word 2,foo bar baz)
print $(firstword apple banana cherry)
print $(lastword apple banana cherry)
print $(dir src/foo.c include/bar.h)
print $(notdir src/foo.c include/bar.h)
print $(basename foo.c bar.o test.txt)
print $(suffix foo.c bar.o test.txt)
print $(addprefix src/,foo.c bar.c)
print $(addsuffix .o,foo bar baz)
print $(sort baz foo bar foo)
print $(wildcard *.sh)
print $(if yes,then-part,else-part)
print $(if ,then-part,else-part)
quit
EOF
