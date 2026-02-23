#!/bin/bash
# Test building real-world projects with smak
# Phase 1: clean, build blockers, smak -check in parallel, report (stop if any fail)
# Phase 2: clean, smak -jN build, make to verify nothing left undone
# Only projects that passed Phase 1 participate in Phase 2.
# This test is run only in full regression mode (-f)

SMAK="${USR_SMAK_SCRIPT:-smak}"
JOBS=${SMAK_TEST_JOBS:-4}

PROJECTS=(
    /usr/local/src/dnsmasq
    /usr/local/src/Trilinos-Build
    /usr/local/src/iverilog
    /usr/local/src/nvc-build
    /usr/local/src/ghdl
    /usr/local/src/xyce-build
)

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Build per-project blockers that make -n needs to exist.
# These are files referenced as prerequisites in recursive sub-makes
# that don't have local rules — they're produced by sibling targets.
build_blockers() {
    local dir="$1"
    local name=$(basename "$dir")
    case "$name" in
        iverilog)
            # vvp/Makefile needs ../version.exe for vvp.man target
            make -C "$dir" version.exe >/dev/null 2>&1
            ;;
        ghdl)
            # libraries sub-make needs ghdl_mcode as prerequisite
            make -C "$dir" ghdl_mcode >/dev/null 2>&1
            ;;
        xyce-build)
            # Xyce.dir/build.make has file dep src/Xyce: src/libxyce.a
            # but only XyceLib.dir/build.make knows how to build it;
            # touch satisfies make -n's existence check
            touch "$dir/src/libxyce.a" 2>/dev/null
            ;;
    esac
}

# ── Phase 1: clean + build blockers + smak -check (parallel) ─────
echo "Phase 1: clean + blockers + smak -check"
echo "────────────────────────────────────────"

PIDS=()

for dir in "${PROJECTS[@]}"; do
    name=$(basename "$dir")
    if [ ! -d "$dir" ]; then
        echo "SKIP" > "$TMPDIR/$name.rc"
        continue
    fi

    (
        # Clean
        $SMAK -C "$dir" clean >/dev/null 2>&1
        rm -rf /tmp/dkc/smak/"$name" 2>/dev/null
        make -C "$dir" clean >/dev/null 2>&1

        # Build blockers
        build_blockers "$dir"

        # Check
        $SMAK -C "$dir" -check > "$TMPDIR/$name.out" 2>&1
        echo $? > "$TMPDIR/$name.rc"
    ) &
    PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
    wait "$pid"
done

# Report Phase 1
P1_PASSED=0
P1_FAILED=0
P1_SKIPPED=0
P1_PASS_LIST=()

for dir in "${PROJECTS[@]}"; do
    name=$(basename "$dir")
    rc=$(cat "$TMPDIR/$name.rc" 2>/dev/null)

    if [ "$rc" = "SKIP" ]; then
        echo "  SKIP $name (directory not found)"
        ((P1_SKIPPED++))
    elif [ "$rc" = "0" ]; then
        COUNT=$(grep -o 'agree on [0-9]* command' "$TMPDIR/$name.out" | grep -o '[0-9]*')
        echo "  PASS $name (${COUNT:-?} commands)"
        ((P1_PASSED++))
        P1_PASS_LIST+=("$dir")
    else
        echo "  FAIL $name"
        tail -20 "$TMPDIR/$name.out"
        ((P1_FAILED++))
    fi
done

echo ""
echo "Phase 1: $P1_PASSED passed, $P1_FAILED failed, $P1_SKIPPED skipped"

if [ $P1_FAILED -gt 0 ]; then
    echo ""
    echo "Phase 1 FAILED — stopping."
    exit 1
fi
echo ""

# ── Phase 2: clean + smak -jN build + make verify ─────────────────
echo "Phase 2: clean + smak -j${JOBS} build + make verify"
echo "──────────────────────────────────────────────────"

P2_FAILED=0
P2_PASSED=0

for dir in "${P1_PASS_LIST[@]}"; do
    name=$(basename "$dir")

    echo -n "  $name: clean..."

    $SMAK -C "$dir" clean >/dev/null 2>&1
    rm -rf /tmp/dkc/smak/"$name" 2>/dev/null
    make -C "$dir" clean >/dev/null 2>&1

    echo -n " build -j${JOBS}..."
    START=$(date +%s)
    BUILD_OUT=$($SMAK -C "$dir" -j${JOBS} 2>&1)
    BUILD_RC=$?
    END=$(date +%s)
    DUR=$((END - START))

    if [ $BUILD_RC -ne 0 ]; then
        echo " FAIL (exit $BUILD_RC, ${DUR}s)"
        echo "$BUILD_OUT" | tail -20
        ((P2_FAILED++))
        continue
    fi

    # Run make to verify nothing was left undone
    echo -n " make verify..."
    VERIFY_OUT=$(make -C "$dir" 2>&1)
    VERIFY_RC=$?

    if echo "$VERIFY_OUT" | grep -qiE 'up.to.date|nothing to be done|is up to date'; then
        echo " PASS (${DUR}s)"
        ((P2_PASSED++))
    elif [ $VERIFY_RC -eq 0 ]; then
        if echo "$VERIFY_OUT" | grep -qE '^\s*(cc|gcc|g\+\+|c\+\+|ar |ld )|Compiling'; then
            echo " FAIL (make found undone work, ${DUR}s)"
            echo "  make output:"
            echo "$VERIFY_OUT" | head -10
            ((P2_FAILED++))
        else
            echo " PASS (${DUR}s)"
            ((P2_PASSED++))
        fi
    else
        echo " FAIL (make verify failed, exit $VERIFY_RC, ${DUR}s)"
        echo "$VERIFY_OUT" | tail -10
        ((P2_FAILED++))
    fi
done

echo ""
echo "Phase 2: $P2_PASSED passed, $P2_FAILED failed"
echo ""

TOTAL_FAILED=$((P1_FAILED + P2_FAILED))
TOTAL_PASSED=$((P1_PASSED + P2_PASSED))
echo "Total: $TOTAL_PASSED passed, $TOTAL_FAILED failed"

if [ $TOTAL_FAILED -gt 0 ]; then
    exit 1
fi
exit 0
