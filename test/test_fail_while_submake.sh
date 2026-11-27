#!/bin/bash
# Regression: smak -j never finished when a job failed while a sub-make was
# on its way.
#     all: a b
#     chk: ; @exit 1
#     a: chk ; $(MAKE) -C $@ all
#     b: ; $(MAKE) -C $@ all
# The failure of chk stops the build: the job-master clears its queue and
# tells the sub-makes connected to it.  The sub-make for b, forked a moment
# before, connects after that and sends its jobs; nothing is dispatched any
# more, nobody tells it, and it waits for ever - and so did smak
# ("queued=1 ... builtin_forks=1" for good under SMAK_DEBUG).  It did not
# happen with `false` as the failing command, which is run in-process
# before anything is forked.
# Found building TightVNC with a header missing (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

mkdir a b
for s in a b; do printf 'all:\n\t@sleep 0.3; echo built %s\n' $s > $s/Makefile; done

check() {  # name, the failing recipe
    local name=$1 recipe=$2 i rc
    printf 'all: a b\nchk:\n\t%s\na: chk\n\t$(MAKE) -C $@ all\nb:\n\t$(MAKE) -C $@ all\n.PHONY: all chk a b\n' \
        "$recipe" > Makefile
    for i in 1 2 3; do
        timeout 60 $SMAK -j4 >/dev/null 2>&1; rc=$?
        if [ $rc = 124 ]; then
            echo "FAIL: $name, run $i: smak did not finish"; fail=1
            pkill -P $$ -f smak 2>/dev/null
            return
        elif [ $rc = 0 ]; then
            echo "FAIL: $name, run $i: smak reported success"; fail=1
            return
        fi
    done
    echo "PASS: $name"
}

check "exit 1" '@exit 1'
check "output, then false" '@echo message; false'
check "if/else with exit 1" '@if false; then :; else echo message; exit 1; fi'
check "false" '@false'

# a failing line, then a recursive make, in one recipe
printf 'all: a b\na:\n\t@false\n\t$(MAKE) -C $@ all\nb:\n\t$(MAKE) -C $@ all\n.PHONY: all a b\n' > Makefile
for i in 1 2 3; do
    timeout 60 $SMAK -j4 >/dev/null 2>&1; rc=$?
    if [ $rc = 124 ] || [ $rc = 0 ]; then
        echo "FAIL: a failing line before a recursive make, run $i: status $rc"; fail=1; break
    fi
done
[ $fail = 0 ] && echo "PASS: a failing line before a recursive make"

exit $fail
