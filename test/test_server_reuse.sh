#!/bin/bash
# Regression: persistent job server reuse (found by smak-buildtest,
# 2026-09-28):
#   - `smak-attach -pid N` then a bare `build` said "No default target found"
#     and exited 0; it must build the makefile's default goal
#   - `set reconnect = 1` in the rc file stored the old server's port but
#     never used it: every run started another job server
#   - output of a reused server went to the terminal of the session that
#     started it instead of the reconnecting client
#   - smak-attach died when TERM is unset
#   - an attached rebuild reported success once a.o was compiled: `all`
#     counted the existing prog as done while its relink was still queued
#     (htop server mode: Action.o rebuilt, nothing relinked)
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
ATTACH=$(dirname "$SMAK")/smak-attach
d=$(mktemp -d); cd "$d"
export USER=${USER:-smaktest}
unset USR_SMAK_OPT
cleanup() { "$ATTACH" --kill-all >/dev/null 2>&1; rm -rf "$d"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

cat > Makefile <<'EOF'
all: prog
prog: a.o b.o
	@cat a.o b.o > prog; echo "linked prog"
%.o: %.c
	@cp $< $@; echo "compiled $@"
EOF
echo a > a.c; echo b > b.c
printf 'set reconnect = 1\nset job_server_idle_timeout = 120\n' > rc
export SMAK_RCFILE=$d/rc

out=$(printf 'build all\ndetach\n' | timeout 60 $SMAK -cli -j2 2>&1)
pid=$(grep -a -o 'job server [0-9]*' <<<"$out" | awk '{print $3}')
check "cli build + detach leaves the server running" '[ -n "$pid" ] && kill -0 $pid 2>/dev/null && [ -f prog ]'

touch -d '1 minute ago' a.o b.o prog; touch a.c
out=$(printf 'build\ndetach\n' | TERM= timeout 60 "$ATTACH" -pid "$pid" 2>&1)
check "smak-attach bare build builds the default goal" 'grep -q "Build succeeded" <<<"$out" && [ a.o -nt a.c ]'
check "the attached build relinks before it reports success" 'grep -A99 "linked prog" <<<"$out" | grep -q "Build succeeded" && [ prog -nt a.c ]'

touch -d '1 minute ago' a.o b.o prog; touch b.c
out=$(timeout 60 $SMAK -j2 2>&1)
check "reconnect reuses the detached server" 'grep -q "Reusing job server $pid" <<<"$out"'
check "reused server output reaches this client" 'grep -q "compiled b.o" <<<"$out"'
check "still exactly one job server" '[ "$(pgrep -c -x smak-server)" -ge 1 ] && kill -0 $pid'

"$ATTACH" --kill-all >/dev/null 2>&1
sleep 1
check "kill-all stops it" '! kill -0 $pid 2>/dev/null'
exit $fail
