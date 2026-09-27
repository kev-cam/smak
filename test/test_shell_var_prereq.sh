#!/bin/bash
# Regression: a prerequisite named through a recursively-expanded variable
# whose value calls $(shell ...) must be expanded before it is split into
# words.  dnsmasq names its compile-options stamp this way:
#   sum?=$(shell echo ... | ( md5sum 2>/dev/null || md5 ) | cut -f 1 -d ' ')
#   $(objs): .copts_$(sum) $(hdrs)
# needs_rebuild() split the raw $(shell ...) text on spaces, so a no-op run
# rebuilt every object (sequential) or failed on a dependency named "'" (-j).
# Found by smak-buildtest on dnsmasq (2026-09-27).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
cat > Makefile <<'EOF'
sum?=$(shell echo x | ( md5sum 2>/dev/null || md5 ) | cut -f 1 -d ' ')
stamp = .st_$(sum)
all: out.txt
out.txt: $(stamp) dep.h
	@echo build; touch $@
$(stamp): dep.h
	@touch $@
EOF
touch -d '2 minutes ago' dep.h
fail=0
for j in "" "-j2"; do
    rm -f out.txt .st_*
    $SMAK $j >/dev/null 2>&1
    out=$($SMAK $j 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAIL: no-op run ${j:-seq} exited $rc: $out"; fail=1
    elif grep -q '^build' <<<"$out"; then
        echo "FAIL: no-op run ${j:-seq} rebuilt out.txt"; fail=1
    else
        echo "PASS: no-op run ${j:-seq} rebuilt nothing"
    fi
done
exit $fail
