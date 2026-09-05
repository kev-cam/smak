#!/bin/bash
# Regression: an explicitly requested goal with no rule and no file must fail
# like GNU make ("No rule to make target 'X'.  Stop.", non-zero exit), while
# goals reachable through explicit, variable-expanded, pattern, suffix or
# built-in implicit rules -- or that exist as files -- are accepted.
# Found building Trilinos for Xyce (2026-09-05): `smak install` in a CMake
# build dir exited 0 having done nothing.
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
printf 'EXE=prog\nall:\n\t@echo hi\n$(EXE)$(EXEEXT): foo.o\n\t@echo link $@\n%%.o: %%.c\n\t@echo cc $<\n' > Makefile
echo 'int main(){return 0;}' > foo.c
fail=0
out=$($SMAK -n nosuchtarget 2>&1); rc=$?
if [ $rc -eq 0 ] || ! grep -q "No rule to make target 'nosuchtarget'" <<<"$out"; then
    echo "FAIL: unknown goal accepted (rc=$rc): $out"; fail=1
else
    echo "PASS: unknown goal rejected (rc=$rc)"
fi
for goal in all foo.o prog foo.c; do
    if $SMAK -n "$goal" >/dev/null 2>&1; then echo "PASS: goal $goal accepted"; else echo "FAIL: goal $goal rejected"; fail=1; fi
done
exit $fail
