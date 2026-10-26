#!/bin/bash
# Regression: smak must work as $MAKE for GCC's -flto=auto link step.
# lto-wrapper probes `$MAKE --version` (non-zero exit => serial LTRANS) and
# then runs `$MAKE -f tmp.mk -jN all` on a makefile whose targets are
# `/tmp/ccX.ltrans0.ltrans.o:` with a recipe and no prerequisites.  Under -j
# smak gave such targets the built-in `%.o: %.c` prerequisite and failed with
# "dependency '...ltrans.c' cannot be built".
# Found relinking nvc (2026-10-25): "using serial compilation of 53 LTRANS jobs".
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
fail=0

out=$($SMAK --version 2>&1); rc=$?
if [ $rc -eq 0 ] && grep -q '^smak ' <<<"$out"; then
    echo "PASS: --version ($out)"
else
    echo "FAIL: --version rc=$rc: $out"; fail=1
fi

printf '%s:\n\t@touch $@\n.PHONY: all\nall: \\\n\t%s\n' "$d/x.ltrans.o" "$d/x.ltrans.o" > lto.mk
printf 'y.o:\n\t@touch $@\nall: y.o\n' > rel.mk
for mk in lto rel; do
    for j in 1 4; do
        rm -f x.ltrans.o y.o
        out=$($SMAK -f $mk.mk -j$j all 2>&1); rc=$?
        if [ $rc -eq 0 ] && { [ -f x.ltrans.o ] || [ -f y.o ]; }; then
            echo "PASS: explicit recipe without prerequisites ($mk.mk, -j$j)"
        else
            echo "FAIL: explicit recipe without prerequisites ($mk.mk, -j$j) rc=$rc: $out"; fail=1
        fi
    done
done

# Targets without a recipe must still get the built-in implicit rule.
echo 'int main(){return 0;}' > p.c
printf 'all: p.o\n' > imp.mk
if $SMAK -f imp.mk -j4 all >/dev/null 2>&1 && [ -f p.o ]; then
    echo "PASS: implicit %.o: %.c still applies"
else
    echo "FAIL: implicit %.o: %.c not applied"; fail=1
fi

if command -v gcc >/dev/null; then
    for i in 1 2 3 4; do echo "__attribute__((noinline)) int f$i(int x){return x+$i;}" > f$i.c; done
    echo 'int f1(int),f2(int),f3(int),f4(int); int main(){return f1(0)+f2(0)+f3(0)+f4(0)!=10;}' > m.c
    gcc -O2 -flto=auto -c f1.c f2.c f3.c f4.c m.c
    out=$(MAKE=$SMAK gcc -O2 -flto=auto -flto-partition=1to1 f1.o f2.o f3.o f4.o m.o -o lto_prog 2>&1); rc=$?
    if [ $rc -eq 0 ] && ./lto_prog && ! grep -q 'serial compilation' <<<"$out"; then
        echo "PASS: gcc -flto=auto link with MAKE=smak"
    else
        echo "FAIL: gcc -flto=auto link with MAKE=smak rc=$rc: $out"; fail=1
    fi
fi
exit $fail
