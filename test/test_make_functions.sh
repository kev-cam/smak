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
    want=$(cd "$dir" && make -s --no-print-directory "$@" 2>&1)
    for j in "" "-j2"; do
        got=$(cd "$dir" && $SMAK -s $j "$@" 2>&1)
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
all: ; @echo "[$(FILES)] [$(foreach d,a b,<$(d)>)] [$(ARFLAGS)]"
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

exit $fail
