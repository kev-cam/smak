#!/bin/bash
# Regression: `a.o: a.h` (extra prerequisites, no recipe) plus an implicit
# rule (.c.o: or %.o: %.c).  GNU make treats the implicit rule's source a.c
# as a prerequisite and as $<:
#   - touching a.c must rebuild a.o (smak ignored it, sequential and -j);
#   - under -j the recipe must compile a.c (smak ran `cc -c a.h`, making a
#     precompiled header and failing).
# Found by smak-buildtest on dnsmasq (2026-09-27).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
printf '.c.o:\n\t@echo "compile $<"; cp $< $@\nall: a.o\na.o: a.h\n' > Makefile.suffix
printf '%%.o: %%.c\n\t@echo "compile $<"; cp $< $@\nall: a.o\na.o: a.h\n' > Makefile.pattern
fail=0
for m in suffix pattern; do
    for j in "" "-j2"; do
        rm -f a.o; echo src > a.c; touch a.h
        touch -d '2 minutes ago' a.c a.h
        out=$($SMAK $j -f Makefile.$m 2>&1)
        if ! grep -q 'compile a.c' <<<"$out"; then
            echo "FAIL: $m ${j:-seq}: first build did not compile a.c: $out"; fail=1; continue
        fi
        touch -d '1 minute ago' a.o; touch a.c
        out=$($SMAK $j -f Makefile.$m 2>&1)
        if grep -q 'compile a.c' <<<"$out"; then
            echo "PASS: $m ${j:-seq}: touching a.c rebuilt a.o"
        else
            echo "FAIL: $m ${j:-seq}: touching a.c did not rebuild a.o: $out"; fail=1
        fi
    done
done
exit $fail
