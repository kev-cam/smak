#!/bin/bash
# Regression: GNU make features real projects rely on, each compared with
# GNU make's own output (sequential and -j2).  Found by smak-buildtest
# (2026-09-27):
#   - makefile search order GNUmakefile, makefile, Makefile (lua)
#   - --no-print-directory -w -r -R accepted (lz4)
#   - `+` recipe prefix (redis, zstd)
#   - inline recipes `target: ; cmd`, not for `target: VAR = a;b`
#   - `VAR != cmd` and `VAR ::= value`
#   - quoted `;` and `&&` in recipes are not split by the -j builtin path,
#     and builtin echo keeps quoted spacing and -n
#   - $< from `%.o: $(srcdir)/../lib/%.c` with srcdir=. is ../lib/x.c, not
#     ./../lib/x.c (iverilog binaries differed from make's via __FILE__)
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
fail=0

check() {  # name dir [args...]: smak output must equal make's
    local name=$1 dir=$2; shift 2
    local want got j
    want=$(cd "$dir" && make -s --no-print-directory "$@" 2>&1 | grep -v '(ignored)')
    for j in "" "-j2"; do
        got=$(cd "$dir" && $SMAK -s $j "$@" 2>&1)
        # Parallel targets may finish in any order; the seq run checks order.
        if [ -n "$j" ]; then got=$(sort <<<"$got"); cmp=$(sort <<<"$want"); else cmp=$want; fi
        if [ "$got" == "$cmp" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want" | head -5; echo "  smak: $got" | head -5; fail=1
        fi
    done
}

mkdir -p names/sub
printf 'all:\n\t@echo top-lowercase\n\t@$(MAKE) --no-print-directory -w -r -R -C sub\n' > names/makefile
printf 'all:\n\t@echo sub-gnumakefile\n' > names/sub/GNUmakefile
printf 'all:\n\t@echo WRONG-sub-Makefile\n' > names/sub/Makefile
check "makefile names + GNU options" names

mkdir plus
printf 'all:\n\t+@echo plus-at\n\t@+echo at-plus\n\t-+@false\n\t@echo after\n' > plus/Makefile
check "+ prefix" plus

mkdir inline
cat > inline/Makefile <<'EOF'
x = 1
all: a b ; @echo "inline all x=$(x)"
	@echo second-line
a: ; @echo "a: $(shell echo 'q;r')"
b: VAR = p;q
b:
	@echo "b VAR=$(VAR)"
EOF
check "inline recipes" inline

mkdir assign
cat > assign/Makefile <<'EOF'
sum != echo hi | md5sum | cut -c1-8
lines != printf "a\nb\n"
imm ::= $(sum)-x
all:
	@echo "[$(sum)] [$(lines)] [$(imm)]"
EOF
check "!= and ::=" assign

mkdir echo
cat > echo/Makefile <<'EOF'
all: dep
	@echo "p;q" && echo 'x&&y' ; echo z
dep:
	@echo "a  two  spaces"
	@echo -n no-newline; echo " <"
	@echo "x;y" > f.txt; cat f.txt
EOF
check "quoted separators and echo" echo

mkdir -p dotslash/sub dotslash/lib
echo x > dotslash/lib/x.c
printf 'srcdir = .\nall: x.o\n%%.o: $(srcdir)/../lib/%%.c\n\t@echo "cc $<"\n' > dotslash/sub/Makefile
check "pattern prerequisite ./ prefix" dotslash/sub
rm -f dotslash/sub/x.o

exit $fail
