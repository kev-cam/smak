#!/bin/bash
# Regression: recipe lines keep shell semantics under smak -j, compared with
# GNU make.  Found by smak-buildtest on jq and tmux (2026-09-28):
#   - `if ...; then ...; fi | sed > $@` was split on `;` (jq config_opts.inc)
#     and the worker's builtin mkdir created a directory "src && if test ..."
#   - automake depcomp `depbase=...; cc ... -MF $depbase.Tpo && mv $depbase.Tpo`
#     was split on `&&`, losing $depbase (jq, htop)
#   - `${VAR}` (brace form) in prerequisites stayed unexpanded in the
#     job-master, so ${LIBOBJDIR}x.o fell back to the builtin rule (tmux)
#   - a recursive $(MAKE) wrapped in shell code (automake all-recursive)
#     deadlocked the layered scheduler (jq)
#   - output of recipes run for a relayed sub-make was lost
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v make >/dev/null || { echo "SKIP: GNU make not installed"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
fail=0

mkdir -p src sub/lib
cat > Makefile <<'EOF'
LIBOBJDIR = lib/
LIBOBJS = ${LIBOBJDIR}one.o
CFLAGS_X = -DMARK

all: src/opts.inc out/dep.txt sublib
	@echo "top done"

src/opts.inc:
	mkdir -p src
	if test -x ./nothing; then \
	  echo yes; \
	else echo "(unknown)"; \
	fi | sed -e 's/^/#define X /' > $@

out/dep.txt: $(LIBOBJS)
	@depbase=`echo $@ | sed 's|\.txt$$||'`; \
	echo "built $$depbase" > $$depbase.tmp && \
	mv $$depbase.tmp $@

lib/one.o: lib/one.c
	@mkdir -p out && cp lib/one.c $@ && echo "flags $(CFLAGS_X)" >> $@

sublib:
	@fail=; for t in inner; do \
	  $(MAKE) -C sub $$t || fail=yes; \
	done; test -z "$$fail"
EOF
mkdir -p lib; echo 'one' > lib/one.c
cat > sub/Makefile <<'EOF'
inner: lib/a.o lib/b.o
	@cat lib/a.o lib/b.o > inner.txt; echo "inner linked"
lib/%.o: lib/%.c
	@cp $< $@; echo "sub compiled $@"
EOF
echo a > sub/lib/a.c; echo b > sub/lib/b.c

clean() { rm -rf src/opts.inc out lib/one.o sub/inner.txt sub/lib/*.o; }
clean; want=$(make -s --no-print-directory 2>&1 | sort)
want_files=$(cat src/opts.inc out/dep.txt lib/one.o sub/inner.txt 2>&1)
for j in "" "-j4"; do
    clean
    got=$(timeout 60 $SMAK -s $j 2>&1 | sort); rc=$?
    files=$(cat src/opts.inc out/dep.txt lib/one.o sub/inner.txt 2>&1)
    stray=$(ls -d src* lib* 2>/dev/null | grep -v -x -e src -e lib)
    if [ "$got" == "$want" ] && [ "$files" == "$want_files" ] && [ -z "$stray" ]; then
        echo "PASS: ${j:-seq}"
    else
        echo "FAIL: ${j:-seq} (rc=$rc)"
        diff <(echo "$want") <(echo "$got") | head -10
        diff <(echo "$want_files") <(echo "$files") | head -10
        [ -n "$stray" ] && echo "  stray: $stray"
        fail=1
    fi
done
exit $fail
