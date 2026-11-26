#!/bin/bash
# Regression: a substitution reference in a rule line, compared with GNU make.
# TightVNC's Makefiles have `OBJS = $(SRCS:.c=.o)` and `lib.a: $(OBJS)`; the
# rule-line expansion looked `SRCS:.c=.o` up as a variable name, so lib.a had
# no prerequisites: nothing was compiled, `ar cqs lib.a` made an empty
# archive and smak exited 0.  The same reference worked in a recipe.
#   - through a variable and written directly, in prerequisites and targets
#     (`$(OBJS): defs.h` at the start of a line took the colon inside the
#     reference for the rule's)
#   - the % form ($(SRCS:%.c=lib%.a))
#   - in an included makefile (it has its own parser)
#   - in a vpath directive
# Found building TightVNC (2026-11-26).
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT
fail=0

mkdir -p sub/src
touch a.c b.c sub/src/v.c defs.h inc.h
cat > Makefile <<'EOF'
SRCS = a.c b.c
OBJS = $(SRCS:.c=.o)
LIBS = $(SRCS:%.c=lib%.a)
D = sub
vpath %.c $(D:%=%/src)
all: lib.a direct $(LIBS) inc.a v.o
	@echo "all: $^"
lib.a: $(OBJS)
	@echo "ar $@ $^"; touch $@
direct: $(SRCS:.c=.o) $(SRCS:%.c=%.c)
	@echo "direct: $^"
$(SRCS:.c=.o): %.o: %.c
	@echo "cc $< -> $@ ($^)"; touch $@
$(OBJS): defs.h
%.o: %.c
	@echo "vpath cc $< -> $@"; touch $@
$(LIBS):
	@echo "lib $@"
include inc.mk
.PHONY: all direct $(LIBS)
EOF
cat > inc.mk <<'EOF'
INCOBJS = $(SRCS:.c=.o)
$(INCOBJS): inc.h
inc.a: $(INCOBJS) $(SRCS:.c=.c)
	@echo "inc $@ $^"; touch $@
EOF

want=$(make 2>&1)
rm -f *.o *.a
for j in "" "-j2" "-j2 --no-builtins"; do
    got=$(timeout 120 $SMAK $j 2>&1)
    rm -f *.o *.a
    if [ -n "$j" ]; then g=$(sort <<<"$got"); w=$(sort <<<"$want"); else g=$got; w=$want; fi
    if [ "$g" == "$w" ]; then
        echo "PASS: substitution references in rule lines ${j:-seq}"
    else
        echo "FAIL: substitution references in rule lines ${j:-seq}"
        echo "  make: $want"; echo "  smak: $got"; fail=1
    fi
done
exit $fail
