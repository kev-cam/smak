#!/bin/bash
# Regression: exported variables reach recipe commands and sub-makes,
# compared with GNU make.  TightVNC's Xvnc/Makefile has `export LN = ln
# -snf` and `export DEFS = ...`; its sub-makes run `$(LN) ...` and add to
# DEFS (`DEFS += -DSHAPE`), three levels deep.  smak parsed `export` and
# dropped it: $(LN) was empty and every object was compiled without DEFS.
#   - `export VAR = value`, `export A B`, and a value that refers to a
#     variable assigned later
#   - a variable from the environment that a makefile changes is passed on
#     with the new value, to the next level too
#   - `unexport VAR` takes it out of the environment
#   - a command-line assignment still wins in every sub-make
#   - under -j, where the sub-makes' recipes run in the job-master's workers
#   - with a cached parse
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT DEFS LN EXTRA A B NOTEXP
fail=0

mkdir -p mid/leaf
cat > Makefile <<'EOF'
export LN = ln -snf
export DEFS = -DTOP $(LATE)
LATE = -DLATE
A = a-val
B = b-val
export A B
NOTEXP = not-exported
CFLAGS += -Wall
all: mid
	@echo "top env: DEFS=[$$DEFS] LN=[$$LN] A=[$$A] B=[$$B] NOTEXP=[$$NOTEXP] CFLAGS=[$$CFLAGS]"
mid:
	@$(MAKE) -C $@
.PHONY: all mid
EOF
cat > mid/Makefile <<'EOF'
DEFS += -DMID
export EXTRA = x
unexport LN
all: leaf
	@echo "mid: DEFS=[$(DEFS)] LN=[$(LN)] A=[$(A)] NOTEXP=[$(NOTEXP)] CFLAGS=[$(CFLAGS)] origin=$(origin DEFS)/$(origin EXTRA)"
	@echo "mid env: DEFS=[$$DEFS] EXTRA=[$$EXTRA] LN=[$$LN]"
leaf:
	@$(MAKE) -C $@
.PHONY: all leaf
EOF
cat > mid/leaf/Makefile <<'EOF'
DEFS += -DLEAF
all:
	@echo "leaf: DEFS=[$(DEFS)] LN=[$(LN)] EXTRA=[$(EXTRA)] B=[$(B)]"
	@echo "leaf env: DEFS=[$$DEFS] EXTRA=[$$EXTRA] LN=[$$LN]"
.PHONY: all
EOF

check() {  # name, [make arguments]
    local name=$1; shift
    local want got j g w
    want=$(CFLAGS=-O1 make --no-print-directory "$@" 2>&1)
    for j in "" "-j2" "-j2 --no-builtins"; do
        got=$(CFLAGS=-O1 timeout 120 $SMAK $j "$@" 2>&1)
        if [ -n "$j" ]; then g=$(sort <<<"$got"); w=$(sort <<<"$want"); else g=$got; w=$want; fi
        if [ "$g" == "$w" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want"; echo "  smak: $got"; fail=1
        fi
    done
}

check "export, unexport, changed environment variable"
check "command line overrides an exported variable" DEFS=-DCMD
export SMAK_CACHE_DIR=$d/cache
check "first run with a parse cache"
check "second run, parse loaded from the cache"
exit $fail
