#!/bin/bash
# Regression: variables given on the command line reach sub-makes through
# MAKEFLAGS, as in GNU make.  dnsmasq is built as `make COPTS=-DHAVE_DNSSEC`
# and its top-level recipe runs `cd src && $(MAKE) build_cflags="`...`" ...`;
# smak dropped COPTS in the sub-make (always under -j, and sequentially when
# the recipe goes through the shell), silently building a binary without the
# requested features.  A sub-make's own assignment still wins.
# Found by smak-buildtest on dnsmasq (2026-09-27).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
mkdir sub
printf 'all:\n\t@cd sub && $(MAKE) X="`echo 1`"\n' > Makefile
printf 'all:\n\t@echo "sub COPTS=[$(COPTS)] X=[$(X)]"\n' > sub/Makefile
printf 'all:\n\t@cd sub && $(MAKE) COPTS=inner\n' > Makefile.override
fail=0
for j in "" "-j2"; do
    out=$($SMAK $j COPTS='-DA -DB' 2>&1)
    if grep -q 'sub COPTS=\[-DA -DB\] X=\[1\]' <<<"$out"; then
        echo "PASS: ${j:-seq}: COPTS reached the sub-make"
    else
        echo "FAIL: ${j:-seq}: sub-make saw: $out"; fail=1
    fi
    out=$($SMAK $j -f Makefile.override COPTS=outer 2>&1)
    if grep -q 'sub COPTS=\[inner\]' <<<"$out"; then
        echo "PASS: ${j:-seq}: sub-make's own assignment wins"
    else
        echo "FAIL: ${j:-seq}: override lost: $out"; fail=1
    fi
done
exit $fail
