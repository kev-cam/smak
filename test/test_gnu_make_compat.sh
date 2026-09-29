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
#   - end-of-line comments and \# in variable values; backslash-newline
#     plus indentation collapses to one space (lua's CWARNSCPP)
#   - $? (prerequisites newer than the target; lua: ar rc liblua.a $?)
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT   # the seq runs check output order; the suite's modes set -j
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

mkdir comments
cat > comments/Makefile <<'EOF2'
X = a # comment
Y = b\#c # real comment
W= \
	-Wa \
	-Wb \
        # the next ones are off,
	# -Wx \
	# -Wy \

all:
	@echo "[$(X)] [$(Y)] [$(W)]"
EOF2
check "comments and continuations" comments

mkdir newer
printf 'lib.a: a.o b.o\n\t@echo "update: $?"\n%%.o:\n\t@touch $@\n' > newer/Makefile
touch newer/a.o newer/b.o newer/lib.a; touch -d '1 minute ago' newer/a.o newer/lib.a
want=$(cd newer && make -s 2>&1); got=$(cd newer && $SMAK -s 2>&1)
if [ "$got" == "$want" ]; then echo "PASS: \$? seq"; else echo "FAIL: \$? seq: make [$want] smak [$got]"; fail=1; fi

# redis: a recipe line ending in a shell comment (`$(AR) $@ $(OBJS)	# DLL
# needs ...`: Perl's own exec passed "#" to ar), `VAR='' cmd` (exec'd
# "VAR=" as the program), '' arguments, # inside $(shell ...), and a
# comment must not hide a failing command's status
mkdir shc
cat > shc/Makefile <<'EOF'
X := $(shell echo a # b)
all: one two
one:
	@echo "one [$(X)]"	# trailing comment
two:
	@SUFFIX='' sh -c 'echo "two [$$SUFFIX]"'
	@printf '%s|' a '' b; echo
EOF
check "shell comments, VAR=value prefix, empty arguments" shc
mkdir shfail
printf 'all:\n\t@false # fails\n\t@echo not-reached\n' > shfail/Makefile
for j in "" "-j2"; do
    got=$(cd shfail && $SMAK $j 2>&1); rc=$?
    if [ $rc -ne 0 ] && ! grep -q not-reached <<<"$got"; then echo "PASS: failing command with a comment ${j:-seq}"
    else echo "FAIL: failing command with a comment ${j:-seq} (rc=$rc)"; fail=1; fi
done

# redis: `ar rcs $@ $+` ($+ keeps duplicates, $^ drops them), and a
# `cd sub && $(MAKE) ...` line was echoed twice
mkdir -p plus/sub
printf 'all:\n\tcd sub && $(MAKE) --no-print-directory X=1\n' > plus/Makefile
printf 'all: a b a\n\t@echo "plus=[$+] hat=[$^]"\na b:\n\t@:\n' > plus/sub/Makefile
want=$(cd plus && make --no-print-directory 2>&1 | sed 's/make/MAKE/')
got=$(cd plus && $SMAK 2>&1 | sed "s#$SMAK#MAKE#")
if [ "$got" == "$want" ]; then echo "PASS: \$+ \$^ and cd-sub-make echo"; else echo "FAIL: \$+ \$^: make [$want] smak [$got]"; fail=1; fi

exit $fail
