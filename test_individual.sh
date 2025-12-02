#!/bin/bash
# Test individual gmake functions

echo "Testing individual gmake functions..."
echo ""

cat <<'EOF' | ./smak -f Makefile.nested -d
print $(patsubst %.c,%.o,foo.c)
print $(filter %.c,foo.c bar.o baz.c)
print $(words one two three)
quit
EOF
