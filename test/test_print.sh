#!/bin/bash
# Test help and print commands in debug mode

echo "Testing help and print commands..."
echo ""

cat <<'EOF' | ${USR_SMAK_SCRIPT:-smak} -f Makefile.test -Kd
help
print 2 + 2
print scalar(keys %fixed_rule)
print scalar(keys %pattern_rule)
print scalar(keys %pseudo_rule)
print join(', ', sort keys %fixed_rule)
print $makefile
quit
EOF
