#!/bin/bash
# Regression: the default goal can come from an included makefile, compared
# with GNU make.  TightVNC's cfb16/Makefile is
#     PIXELSIZE = 16
#     include ../Makefile.cfb-common          (has `all: libcfb.a`)
#     $(foreach SRC,$(SRCS),$(eval $(call link_source_file,$(SRC))))
# The parser for included makefiles never set the default goal, so a plain
# `smak` made the first target of cfb16/Makefile itself, one symlinked
# source file, said nothing and exited 0: libcfb.a was missing at link time.
#   - the first target of the included file is the default goal
#   - not a pattern rule, a special target or a variable assignment in it
#   - a rule in the makefile before the include still comes first
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

cat > common.mk <<'EOF'
NAMES = one two
.PHONY: all first $(NAMES)
%.x: %.y
	@echo "pattern $@"
all: $(NAMES)
	@echo "all from common.mk: $^"
EOF
cat > Makefile <<'EOF'
include common.mk
define rule
$(1):
	@echo "made $$@"
endef
$(foreach N,$(NAMES),$(eval $(call rule,$(N))))
EOF
cat > Makefile.first <<'EOF'
first:
	@echo "first from the makefile"
include common.mk
one two:
	@echo "made $@"
EOF

check() {  # name, [make arguments]
    local name=$1; shift
    local want got j g w
    want=$(make --no-print-directory "$@" 2>&1)
    for j in "" "-j2" "-j2 --no-builtins"; do
        got=$(timeout 120 $SMAK $j "$@" 2>&1)
        if [ -n "$j" ]; then g=$(sort <<<"$got"); w=$(sort <<<"$want"); else g=$got; w=$want; fi
        if [ "$g" == "$w" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want"; echo "  smak: $got"; fail=1
        fi
    done
}

check "default goal from the included makefile"
check "a rule before the include comes first" -f Makefile.first
exit $fail
