#!/bin/bash
# Test interactive debug mode

echo "Testing interactive debug mode..."
echo ""

cat <<EOF | ./smak -d
list
show program
rule clean
deps main.o
all
quit
EOF
