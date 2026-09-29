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

# lz4: `liblz4.so.1: liblz4.so.1.10.0` (a phony re-linking a symlink) is
# remade every run, but the file it points to keeps its time, so make does
# not remake liblz4.so; smak did (decided before building prerequisites).
# lua: `all: $(ALL_T) ; touch all` - a regular file named `all` is a file
# target, not smak's conventional phony.
mkdir symlinks
cat > symlinks/Makefile <<'EOF'
all: lib.so
	touch all
lib.so: lib.so.1
	ln -sf lib.so.1 $@
lib.so.1: lib.so.1.0
	ln -sf lib.so.1.0 $@
.PHONY: lib.so.1.0
lib.so.1.0: real
	ln -sf real $@
real:
	touch real
EOF
(cd symlinks && make >/dev/null 2>&1); want=$(cd symlinks && make 2>&1)
(cd symlinks && rm -f all lib.so* real && timeout 120 $SMAK >/dev/null 2>&1); sleep 1
got=$(cd symlinks && timeout 120 $SMAK 2>&1)
if [ "$got" == "$want" ]; then echo "PASS: second run (phony symlink chain, file named all)"
else echo "FAIL: second run: make [$want] smak [$got]"; fail=1; fi

# redis src/: `ifneq (...)` <tab>vpath %.c ../modules/vector-sets
mkdir -p ivp/src ivp/mod
echo 'int m;' > ivp/mod/m.c
printf 'X = 1\nifneq ($(X),)\n\tvpath %%.c ../mod\nendif\nall: out/m.o\nout/m.o: m.c\n\t@mkdir -p out; echo "cc $<"; touch $@\n' > ivp/src/Makefile
check "indented vpath in a conditional" ivp/src

# redis: under -j, `$(MAKE) -C src distclean` whose recipe runs
# `(cd ../mods && $(MAKE) clean)` was built in-process and its targets sent to
# the job-master, which looked them up in the top makefile: nothing ran
mkdir -p nclean/src nclean/mods
printf 'all:\n\t@$(MAKE) --no-print-directory -C src distclean\n' > nclean/Makefile
printf 'distclean:\n\t@(cd ../mods && $(MAKE) --no-print-directory clean)\n' > nclean/src/Makefile
printf 'all: a.so\na.so:\n\t@touch $@\nclean:\n\t@echo CLEAN; rm -rf *.so out\n' > nclean/mods/Makefile
for j in "" "-j4"; do
    touch nclean/mods/a.so; mkdir -p nclean/mods/out
    got=$(cd nclean && timeout 120 $SMAK $j 2>&1)
    if [ "$got" == "CLEAN" ] && [ ! -e nclean/mods/a.so ] && [ ! -e nclean/mods/out ]; then
        echo "PASS: nested sub-make goal ${j:-seq}"
    else echo "FAIL: nested sub-make goal ${j:-seq}: [$got]"; ls nclean/mods; fail=1; fi
done

# redis: `module_tests: redis-server ; $(MAKE) -C ../tests/modules` in a
# relayed sub-make: the relay also expanded the recursive make while
# capturing, so the modules were built at once (before redis-server), twice
mkdir -p mt/src mt/mods
printf 'all:\n\t@$(MAKE) --no-print-directory -C src all\n' > mt/Makefile
printf 'all: prog mt\nprog:\n\t@sleep 1; echo PROG; touch prog\nmt: prog\n\t@$(MAKE) --no-print-directory -C ../mods\n' > mt/src/Makefile
printf 'all:\n\t@echo MODS\n' > mt/mods/Makefile
for j in "" "-j4"; do
    rm -f mt/src/prog
    got=$(cd mt && timeout 120 $SMAK $j 2>&1 | tr '\n' ' ')
    if [ "$got" == "PROG MODS " ]; then echo "PASS: recursive make after its prerequisite ${j:-seq}"
    else echo "FAIL: recursive make after its prerequisite ${j:-seq}: [$got]"; fail=1; fi
done

mkdir silent
printf 'all: a\na:\n\tmkdir -p out\n\techo quiet\n.SILENT:\n' > silent/Makefile
check ".SILENT" silent

mkdir echo
printf 'all: a b\na:\n\tmkdir -p out\n\ttest -n "$$HOME"\n\t@echo x; echo y\n\techo "p;q"; touch out/f; echo z\n\t-@rm -f nothere\n\t-rm -f out/g\nb:\n\techo b\n' > echo/Makefile
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

# zstd lib/Makefile: `.PHONY: libx.a` whose recipe re-runs make with
# BUILD_DIR set. The relayed job's target file exists, but being phony it
# must still run, or a touched source is never recompiled under -j.
mkdir -p ph/lib
printf 'all:\n\t@$(MAKE) --no-print-directory -C lib\n' > ph/Makefile
cat > ph/lib/Makefile <<'EOF'
.PHONY: all libx.a
all: libx.a
ifndef BUILD_DIR
libx.a:
	+@$(MAKE) --no-print-directory $@ BUILD_DIR=obj
else
libx.a: $(BUILD_DIR)/a.o
	@echo AR; cp $< $@
$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(@D); echo "CC $<"; cp $< $@
endif
EOF
echo a > ph/lib/a.c
for j in "" "-j2"; do
    (cd ph && timeout 120 $SMAK $j >/dev/null 2>&1)
    touch -d '1 minute ago' ph/lib/obj/a.o ph/lib/libx.a; touch ph/lib/a.c
    got=$(cd ph && timeout 120 $SMAK $j 2>&1 | tr '\n' ' ')
    if [ "$got" == "CC a.c AR " ]; then echo "PASS: phony sub-make target that exists as a file ${j:-seq}"
    else echo "FAIL: phony sub-make target that exists as a file ${j:-seq}: [$got]"; fail=1; fi
done

exit $fail
