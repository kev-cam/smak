#!/bin/bash
# Regression: smak's built-in `rm -f` removes a dangling symbolic link.
# TightVNC's cfb16/24/32 directories hold links to sources in ../cfb, some
# of which are links themselves.  `clean` removes cfb's first, so
# cfb16/cfb8lineCO.c -> ../cfb/cfb8lineCO.c dangles by the time cfb16's
# `$(RM) $(SRCS)` runs.  The built-in rm tested the name with -e, which
# follows the link, took it for missing and (with -f) said nothing: those
# links were left behind after `smak clean`.
#   - a plain `rm -f` line, sequentially and under -j
#   - the `(rm -f a || true) && (rm -f b || true)` form
#   - a link to an existing file goes too; its target stays
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

cat > Makefile <<'EOF'
clean:
	$(RM) x.o link.c dangling.c
clean-compound:
	(rm -f x.o || true) && (rm -f link.c dangling.c || true)
.PHONY: clean clean-compound
EOF

for goal in clean clean-compound; do
    for j in "" "-j2" "-j2 --no-builtins"; do
        touch real.c x.o
        ln -snf real.c link.c
        ln -snf gone.c dangling.c
        out=$(timeout 120 $SMAK $j $goal 2>&1); rc=$?
        left=$(ls -d x.o link.c dangling.c 2>/dev/null | tr '\n' ' ')
        if [ $rc -eq 0 ] && [ -z "$left" ] && [ ! -L dangling.c ] && [ -f real.c ]; then
            echo "PASS: $goal ${j:-seq}"
        else
            echo "FAIL: $goal ${j:-seq}: exit $rc, left: ${left:-nothing}$([ -f real.c ] || echo ', real.c removed')"
            echo "  $out"; fail=1
        fi
        rm -f x.o link.c dangling.c
    done
done
exit $fail
