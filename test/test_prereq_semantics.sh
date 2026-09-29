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
    clean() { find . -name out -prune -exec rm -rf {} +; }
    want=$(cd "$dir" && clean && make --no-print-directory "$@" 2>&1 | grep -v '^make')
    for j in "" "-j2"; do
        got=$(cd "$dir" && clean && timeout 120 $SMAK $j "$@" 2>&1)
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

# zstd: vpath entries are used as spelled (an absolute `$(LIB_SRCDIR)/common`
# with LIB_SRCDIR ending in / became /common/x.c), $(OUTPUT_OPTION) brings in
# $@ after expansion, and `%-release : VAR := ...` applies to lib-release and
# its prerequisites
mkdir -p zv/sub/common
touch zv/sub/common/q.c
cat > zv/sub/inc.mk <<'EOF'
D ?= $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
vpath %.c $(D)/common
EOF
cat > zv/Makefile <<'EOF'
include sub/inc.mk
F = -g
all: lib-release
%-release : F := -O3
%-release : %
	@echo "release $* F=$(F)"
lib: out/q.o
	@echo "lib F=$(F)"
out/%.o: %.c
	@mkdir -p out; echo "cc $< $(OUTPUT_OPTION)"
EOF
check "vpath spelling, OUTPUT_OPTION, pattern-specific variables" zv

# zstd: a recipe line continued inside $(if ...) expands to `    @echo ...`
# (make finds @ after the whitespace); under -j a builtin line was run by
# the client and again by the job-master
mkdir ifat
printf 'all:\n\t$(if $(X),\\\n    @echo multi,\\\n    @echo single $(X))\n\t@echo done\n\t@sleep 0; echo ext\n' > ifat/Makefile
check "continued \$(if) recipe line, mixed builtin/external lines" ifat

# zstd programs/: objects depend on $(B)/%.d, declared as `$(DEPFILES):`
# (no recipe, no prerequisites). A missing one counts as updated; a relayed
# sub-make submitted it as a dependency nothing produces (-j hang).
mkdir -p dfile/sub
printf 'int x;\n' > dfile/sub/x.c
printf 'all:\n\t@$(MAKE) --no-print-directory -C sub\n' > dfile/Makefile
cat > dfile/sub/Makefile <<'EOF'
B = out
all: $(B)/x.o
$(B)/%.o : %.c $(B)/%.d | $(B)
	@echo "cc $@"; touch $@ $(B)/$*.d
$(B): ; @mkdir -p $@
DEPFILES := $(B)/x.d
$(DEPFILES):
include $(wildcard $(DEPFILES))
EOF
check "empty explicit targets as prerequisites in a relayed sub-make" dfile

# zstd lib/: `libzstd.a: ; $(MAKE) $@ BUILD_DIR=..` in a relayed sub-make
# submits the target whose job is running it (-j deadlock); the inner jobs
# must use the relay's prerequisites, not this makefile's `%.o: %.c`, and
# run builtins (mkdir) in their own directory
mkdir -p self/sub
printf 'all:\n\t@$(MAKE) --no-print-directory -C sub\n' > self/Makefile
cat > self/sub/Makefile <<'EOF'
all: lib
lib: out/a.a
ifndef B
out/a.a:
	@$(MAKE) --no-print-directory $@ B=out
else
out/a.a: $(B)/x.o
	@echo "ar $@ $^"; touch $@
$(B)/x.o:
	@mkdir -p $(B); echo "cc $@"; touch $@
endif
EOF
check "same target re-made by a relayed sub-make" self

# jq: after touching a source, a relayed sub-make (-j) rebuilt the object
# but relinked nothing (its jobs were judged up to date while the object's
# job, dispatched early, still had the old file), or linked the program
# before the library was relinked
mkdir -p relink/sub
printf 'all:\n\t@$(MAKE) --no-print-directory -C sub\n' > relink/Makefile
cat > relink/sub/Makefile <<'EOF'
prog: main.o lib.a
	@sleep 1; cat main.o lib.a > $@
lib.a: a.o b.o
	@sleep 1; cat a.o b.o > $@
%.o: %.c
	@cp $< $@
EOF
for f in main a b; do echo "$f" > relink/sub/$f.c; done
(cd relink && timeout 120 $SMAK -j4 >/dev/null 2>&1)
for j in "" "-j4"; do
    sleep 1; echo "a2$j" > relink/sub/a.c
    (cd relink && timeout 120 $SMAK $j >/dev/null 2>&1)
    if grep -q "a2$j" relink/sub/prog && [ relink/sub/prog -nt relink/sub/lib.a ] \
       && [ relink/sub/lib.a -nt relink/sub/a.o ] && [ -z "$(cd relink/sub && make -q prog || echo stale)" ]; then
        echo "PASS: relayed incremental relink ${j:-seq}"
    else
        echo "FAIL: relayed incremental relink ${j:-seq}"; ls -la --time-style=full-iso relink/sub; fail=1
    fi
done

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
