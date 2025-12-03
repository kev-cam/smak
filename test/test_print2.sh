#!/bin/bash
# Test more complex print expressions

echo "Testing complex print expressions..."
echo ""

cat <<'EOF' | ../smak -f Makefile.test -Kd
print "Fixed rules: " . scalar(keys %fixed_rule)
print exists $fixed_rule{"Makefile.test\tprogram"} ? "program rule exists" : "not found"
print $fixed_deps{"Makefile.test\tprogram"} ? join(', ', @{$fixed_deps{"Makefile.test\tprogram"}}) : "no deps"
quit
EOF
