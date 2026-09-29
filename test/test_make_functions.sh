#!/bin/bash
# Regression: make functions and parse-time expansion, each compared with GNU
# make's output (sequential and -j2).  Found by smak-buildtest on lz4
# (2026-09-28), whose build/make/multiconf.make generates its rules with
# $(foreach ..,$(eval $(call ..))) from define templates:
#   - define/endef, $(call) with $(0)/$(1).., $(eval), $$ in templates
#   - $(if)/$(and)/$(or) expand only the branches they take
#     (`$$(if $$(filter 2,$$(V)),$$(info ...))` printed the template)
#   - $(foreach) joins its results with a space (dropped xxhash.o)
#   - $(info) output repeats on every run (a cached parse skipped it)
#   - $$(cmd) reaches the shell as $(cmd)
#   - a tab-indented `VAR = value` outside a recipe is an assignment
#   - default ARFLAGS = rv
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

check() {  # name dir [args...]: smak output must equal make's
    local name=$1 dir=$2; shift 2
    local want got j
    want=$(cd "$dir" && rm -rf out && make -s --no-print-directory "$@" 2>&1)
    for j in "" "-j2"; do
        got=$(cd "$dir" && rm -rf out && timeout 120 $SMAK -s $j "$@" 2>&1)
        if [ -n "$j" ]; then got=$(sort <<<"$got"); cmp=$(sort <<<"$want"); else cmp=$want; fi
        if [ "$got" == "$cmp" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want" | head -8; echo "  smak: $got" | head -8; fail=1
        fi
    done
}

mkdir tmpl
cat > tmpl/Makefile <<'EOF'
V =
define obj  # name, extra
$$(if $$(filter 2,$$(V)),$$(info $$(call $(0),$(1),$(2)))) #debug print
all: $(1)
$(1): ; @echo "build $(1) [$$@] $(2)"
endef
$(foreach O,a b,$(eval $(call obj,$(O),x$(O))))
EOF
check "define/call/eval templates" tmpl

mkdir lazy
cat > lazy/Makefile <<'EOF'
V =
$(if $(V),$(info then-branch),$(info else-branch $$x, a))
x := $(or ,, $(V),second)
y := $(and a,$(info and-evaluated),c)
z := $(and a,,$(info NOT-evaluated))
$(info [$(x)] [$(y)] [$(z)])
all: ; @:
EOF
check "lazy if/and/or" lazy
# the second run may load a cached parse: $(info) must still print
check "info on a second run" lazy

mkdir fe
cat > fe/Makefile <<'EOF'
DIRS = d1 d2
FILES := $(notdir $(foreach d,$(DIRS),$(wildcard $(d)/*.c)))
# zstd: $(addprefix $(BUILD_DIR)/, $(OBJS)) - a leading blank is not a word
# jemalloc: references inside a substitution reference's pattern
R =
V := $(DIRS:$(R)d%=$(R)x%.sym)
W := [$(V)] [$(addprefix p/, a b)] [$(addsuffix .o, a b)] [$(words  a b )] [$(sort  b a)]
all: ; @echo "[$(FILES)] [$(foreach d,a b,<$(d)>)] [$(ARFLAGS)] $(W)"
EOF
mkdir fe/d1 fe/d2; touch fe/d1/x.c fe/d1/y.c fe/d2/z.c
check "foreach join, ARFLAGS" fe

mkdir dollar
cat > dollar/Makefile <<'EOF'
	TABVAR = tab-assigned
all:
	@echo "$$(echo sub) $${HOME:+home} [$(TABVAR)]"
EOF
check "\$\$(cmd) and tab assignment" dollar

# zstd: `$(shell cc -Wa,--noexecstack ... 2>$(VOID))` was cut at the comma,
# and conditions in inactive branches ran their $(shell) (md5 on Linux)
mkdir cond
cat > cond/Makefile <<'EOF'
VOID = /dev/null
ifeq (a,b)
  ifeq ($(shell echo INACTIVE >&2; echo 0), 0)
    X = bad
  endif
endif
ifeq ($(shell echo a,b 2>$(VOID)),a,b)
W = shell-comma
else ifeq ($(shell echo ELSE-IF >&2; echo 1),1)
W = elseif
endif
S := $(subst a,b,a,a) $(filter a,a b,c) $(word 2,x y,z)
all: ; @echo "W=$(W) X=$(X) S=$(S)"
EOF
check "commas in the last argument, inactive branches" cond

# zstd re-runs `$(MAKE) $@ BUILD_DIR=obj/..` under `ifndef BUILD_DIR`:
# ifndef must see command-line variables (else endless recursion), and a
# same-directory sub-make with variables must re-read the makefile
mkdir cvdef
cat > cvdef/Makefile <<'EOF'
ifndef BUILD_DIR
all:
	@echo "no BUILD_DIR, recursing"; $(MAKE) --no-print-directory all BUILD_DIR=obj CF="a b"
else
all:
	@echo "BUILD_DIR=$(BUILD_DIR) CF=$(CF)"
endif
EOF
check "ifndef with a command-line variable" cvdef

# redis: `release_hdr := $(shell sh -c './mkreleasehdr.sh')` writes
# release.h while the makefile is read; a parse loaded from smak's cache
# must still run it (check removes out/ before each run; the -j2 run loads
# the cache). $(shell) output newlines become spaces.
mkdir shside
cat > shside/Makefile <<'EOF'
X := $(shell mkdir -p out; echo gen > out/gen.h; echo hi)
L := $(shell printf "a\nb\n")
all: ; @echo "X=$(X) L=[$(L)] $$(cat out/gen.h)"
EOF
check "\$(shell) side effects with a cached parse" shside

# redis deps/jemalloc: static pattern rules (targets: tpattern: ppattern,
# and `$(OBJS): %.o:` carrying the recipe), $(@D) $(@F) $(@:%.o=%.d)
mkdir -p static/src
for f in a b; do echo "int $f;" > static/src/$f.c; done
cat > static/Makefile <<'EOF'
OBJS := out/a.o out/b.o
SYMS := $(OBJS:.o=.sym)
all: $(SYMS)
$(OBJS): out/%.o: src/%.c
$(OBJS): CPPFLAGS += -DX
$(SYMS): out/%.sym: out/%.o
$(OBJS): %.o:
	@mkdir -p $(@D)
	@echo "cc $< -> $@ stem=$* [$(CPPFLAGS)] $(@F) $(@:%.o=%.d)"; touch $@
$(SYMS): %.sym: ; @echo "sym $< -> $@ stem=$*"; touch $@
EOF
check "static pattern rules, \$(@D) \$(@F) \$(@:..)" static
rm -rf static/out

exit $fail
