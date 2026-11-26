#!/bin/bash
# Regression: $(MAKECMDGOALS), compared with GNU make.  TightVNC's Makefiles
# pass the goals down, with directories as .PHONY targets of a multi-target
# rule:
#     MAKECMDGOALS ?= all
#     all clean install: $(SUBDIRS)
#     $(SUBDIRS): ; $(MAKE) -C $@ $(MAKECMDGOALS)
# smak never set MAKECMDGOALS, so `smak clean` ran `all` in every
# subdirectory, and the sub-makes saw it empty.
#   - the goals of the command line, not the VAR=value arguments
#   - undefined without goals (`?=` applies), set in a sub-make by its goals
#   - visible while the makefile is read (ifeq)
#   - a cached parse of a makefile that names MAKECMDGOALS is not used for
#     other goals
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT V
fail=0

mkdir d1 d2
cat > Makefile <<'EOF'
MAKECMDGOALS ?= all
SUBDIRS = d1 d2
ifeq ($(MAKECMDGOALS),clean)
MODE = cleaning
else
MODE = building
endif
all clean install: $(SUBDIRS)
	@echo "top $@ mode=$(MODE) goals=[$(MAKECMDGOALS)]"
d2: d1
$(SUBDIRS):
	@$(MAKE) -C $@ $(MAKECMDGOALS)
.PHONY: all clean install $(SUBDIRS)
EOF
for s in d1 d2; do
    cat > $s/Makefile <<'EOF'
all clean install:
	@echo "$(notdir $(CURDIR)) $@ goals=[$(MAKECMDGOALS)] V=[$(V)]"
.PHONY: all clean install
EOF
done

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

check "no goal"
check "clean" clean
check "install" install
check "variable and goal" V=1 clean
export SMAK_CACHE_DIR=$d/cache
check "parse cache, no goal"
check "parse cache, clean" clean
check "parse cache, no goal again"
exit $fail
