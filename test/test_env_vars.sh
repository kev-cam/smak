#!/bin/bash
# Regression: environment variables are make variables, compared with GNU
# make.  `all: ; @echo "[$(HOME)]"` printed `[]`, and TightVNC's sub-makes
# never saw the CFLAGS the build was started with.  As in make:
#   - an environment variable expands in recipes, conditionals (ifdef, ifeq)
#     and prerequisites, in a sub-make too, and as ${VAR}
#   - it overrides the built-in defaults (CC); a makefile assignment
#     overrides it, `+=` appends to it and `?=` leaves it alone
#   - a command-line assignment overrides both
#   - $(origin VAR) says `environment`
#   - a cached parse is not used for a different environment, and the cache
#     file does not hold the environment's values
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT FOO BAR OVR MODE CFLAGS CC
fail=0

mkdir sub
cat > Makefile <<'EOF'
CFLAGS += -Wall
BAR ?= default
OVR = from-makefile
ifdef FOO
MSG = foo-set
else
MSG = foo-unset
endif
ifeq ($(MODE),debug)
MSG += debug
endif
all: $(FOO:%=dep-%) sub
	@echo "FOO=[$(FOO)] CFLAGS=[$(CFLAGS)] BAR=[$(BAR)] OVR=[$(OVR)] MSG=[$(MSG)] CC=[$(CC)] braces=[${FOO}]"
	@echo "origin: $(origin FOO) $(origin OVR) $(origin BAR) $(origin NOSUCH)"
dep-%:
	@echo "prerequisite $@"
sub:
	@$(MAKE) -C sub
.PHONY: all sub
EOF
printf 'all:\n\t@echo "sub FOO=[$(FOO)] MODE=[$(MODE)]"\n' > sub/Makefile

check() {  # name, environment assignments, [make arguments]
    local name=$1 envs=$2; shift 2
    local want got j g w
    want=$(env $envs make --no-print-directory "$@" 2>&1)
    for j in "" "-j2" "-j2 --no-builtins"; do
        got=$(env $envs timeout 120 $SMAK $j "$@" 2>&1)
        if [ -n "$j" ]; then g=$(sort <<<"$got"); w=$(sort <<<"$want"); else g=$got; w=$want; fi
        if [ "$g" == "$w" ]; then
            echo "PASS: $name ${j:-seq}"
        else
            echo "FAIL: $name ${j:-seq}"; echo "  make: $want"; echo "  smak: $got"; fail=1
        fi
    done
}

check "recipe, ifdef, prerequisite, makefile overrides" "FOO=1 OVR=from-env"
check "+=, ?=, ifeq, built-in default" "FOO=2 CFLAGS=-O1 BAR=env-bar MODE=debug CC=mycc"
check "not set" "MODE=release"
check "command line overrides" "FOO=3 OVR=from-env" FOO=cmd OVR=cmd

# The parse cache: valid for one environment only, and no values in it
export SMAK_CACHE_DIR=$d/cache
for run in "FOO=a" "FOO=b MODE=debug" "FOO=b MODE=debug"; do
    want=$(env $run make --no-print-directory 2>&1)
    got=$(env $run SECRET_TOKEN=s3cr3t-value timeout 120 $SMAK 2>&1)
    if [ "$got" == "$want" ]; then
        echo "PASS: cached parse, $run"
    else
        echo "FAIL: cached parse, $run"; echo "  make: $want"; echo "  smak: $got"; fail=1
    fi
done
if ! ls cache/*.cache >/dev/null 2>&1; then
    echo "FAIL: no cache file written"; fail=1
elif grep -rq 's3cr3t-value' cache; then
    echo "FAIL: the cache file holds an environment variable's value"; fail=1
else
    echo "PASS: environment values are not written to the cache"
fi
exit $fail
