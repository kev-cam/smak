#!/bin/bash
# Regression: a recipe that calls `exit`, compared with GNU make.
#   - sequential: the command is run as `{ command; } 2>&1; echo EXIT_STATUS=$?`
#     and `exit` leaves the shell before the echo.  With no status line smak
#     took `exit 0` for a failure ("Error 1") - and in the path for commands
#     after a recursive make, `exit 3` for a success.
#   - under -j: `exit 1` has no shell metacharacter, so the worker ran it as
#     a program: "Cannot exec 'exit'", status 127 instead of 1.  The same for
#     `:` and the other shell builtins that are not also programs.
# Found building TightVNC, whose Makefile ended a check early with
#     @case "$(MAKECMDGOALS)" in clean|install) exit 0 ;; esac; ...
# (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

check() {  # the recipe line
    local recipe=$1 want wantrc got gotrc j
    printf 'all:\n\t%s\n' "$recipe" > Makefile
    want=$(make 2>/dev/null); wantrc=$?
    [ $wantrc = 0 ] || wantrc=1
    for j in "" "-j2" "-j2 --no-builtins"; do
        got=$(timeout 60 $SMAK $j 2>/dev/null); gotrc=$?
        [ $gotrc = 0 ] || [ $gotrc = 124 ] || gotrc=1
        # what a failed build prints, and where, is not what is tested here
        [ $wantrc = 0 ] || got=$want
        if [ "$got" == "$want" ] && [ $gotrc = $wantrc ]; then
            echo "PASS: $recipe ${j:-seq}"
        else
            echo "FAIL: $recipe ${j:-seq}"
            echo "  make: status $wantrc, output '$want'"
            echo "  smak: status $gotrc, output '$got'"
            fail=1
        fi
    done
}

check '@exit 0'
check '@exit 3'
check '@exit 0; false'
check '@echo one; exit 0; echo two'
check '@if true; then exit 0; fi; false'
check '@case x in x) exit 0 ;; esac; false'
check '@(exit 0); echo after'
check '@: nothing'
check '@false'

# after a recursive make in the same recipe
mkdir sub
printf 'all:\n\t@echo in sub\n' > sub/Makefile
for last in 'exit 0' 'exit 3'; do
    printf 'all:\n\t@$(MAKE) --no-print-directory -C sub all\n\t@%s\n' "$last" > Makefile
    make >/dev/null 2>&1; wantrc=$?; [ $wantrc = 0 ] || wantrc=1
    timeout 60 $SMAK >/dev/null 2>&1; gotrc=$?; [ $gotrc = 0 ] || [ $gotrc = 124 ] || gotrc=1
    if [ $gotrc = $wantrc ]; then
        echo "PASS: '$last' after a recursive make"
    else
        echo "FAIL: '$last' after a recursive make: make status $wantrc, smak $gotrc"; fail=1
    fi
done

exit $fail
