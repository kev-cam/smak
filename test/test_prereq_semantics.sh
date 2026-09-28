#!/bin/bash
# Regression: prerequisite and recipe semantics, compared with GNU make.
# Found by smak-buildtest on lz4 (2026-09-28):
#   - order-only prerequisites of pattern rules (`c/%/x.o: | c/%/.`) get the
#     stem, and a pattern rule with only order-only prerequisites applies
#   - prerequisite lists are expanded when the rule is read, with global
#     values (lz4 names object dirs by $(shell echo $(CPPFLAGS) | md5sum))
#   - target-specific `+=` inherited through prerequisites applies once
#   - .SILENT: with no prerequisites silences every recipe
#   - under -j, recipe lines are echoed (also lines run as job-master
#     builtins and in relay sub-makes), each unless it starts with @
#   - a failed `$(MAKE) -C sub` fails the recipe; the lines after it do
#     not run (they were forked in parallel with the sub-make under -j)
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

check() {  # name dir [args...]: smak output must equal make's (after cleaning)
    local name=$1 dir=$2; shift 2
    local want got j
    want=$(cd "$dir" && rm -rf out && make --no-print-directory "$@" 2>&1 | grep -v '^make')
    for j in "" "-j2"; do
        got=$(cd "$dir" && rm -rf out && $SMAK $j "$@" 2>&1)
        if [ -n "$j" ]; then got=$(sort <<<"$got"); cmp=$(sort <<<"$want"); else cmp=$want; fi
        if [ "$got" == "$cmp" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want" | head -8; echo "  smak: $got" | head -8; fail=1
        fi
    done
}

mkdir -p oo/lib
echo 'int x;' > oo/lib/x.c
cat > oo/Makefile <<'EOF'
vpath %.c lib
CPPFLAGS = -Da
C = out
all: rel
rel: CPPFLAGS += -DN
rel: prog
prog: CPPFLAGS += -DT
prog: $(C)/$(firstword $(shell echo $(CPPFLAGS) | md5sum))/x.o
	@echo "link [$(CPPFLAGS)] $^"
.PRECIOUS: $(C)/%/.
$(C)/%/. :
	mkdir -p $@
$(C)/%/x.o : x.c | $(C)/%/.
	@echo "cc $< [$(CPPFLAGS)] stem=$*"; touch $@
EOF
check "order-only pattern prereqs, parse-time prereqs, target-specific +=" oo

mkdir silent
printf 'all: a\na:\n\tmkdir -p out\n\techo quiet\n.SILENT:\n' > silent/Makefile
check ".SILENT" silent

mkdir echo
printf 'all: a b\na:\n\tmkdir -p out\n\t@echo x; echo y\n\techo "p;q"; touch out/f; echo z\n\t-@rm -f nothere\n\t-rm -f out/g\nb:\n\techo b\n' > echo/Makefile
check "recipe echo" echo

mkdir -p sub/s
printf 'all: a b\na:\n\t$(MAKE) -C s\n\techo after-sub\nb:\n\techo b\n' > sub/Makefile
printf 'all:\n\tfalse\n' > sub/s/Makefile
for j in "" "-j2"; do
    got=$(cd sub && $SMAK $j 2>&1); rc=$?
    if [ $rc -ne 0 ] && ! grep -qx after-sub <<<"$got"; then
        echo "PASS: failed sub-make stops the recipe ${j:-seq}"
    else
        echo "FAIL: failed sub-make stops the recipe ${j:-seq} (rc=$rc)"; echo "$got" | head -8; fail=1
    fi
done

exit $fail
