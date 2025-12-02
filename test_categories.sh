#!/bin/bash
# Test categorized rules in debug mode

echo "Testing categorized rules in debug mode..."
echo ""

cat <<EOF | ./smak -f Makefile.test -d
list
list fixed
list pattern
list pseudo
show %.o
show .PHONY
show program
fixed
pattern
quit
EOF
