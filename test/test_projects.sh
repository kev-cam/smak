#!/bin/bash
# Test building real-world projects with smak
# Does smak clean + smak -j4 in each project directory
# This test is run only in full regression mode (-f)

SMAK="${USR_SMAK_SCRIPT:-smak}"
FAILED=0
PASSED=0
SKIPPED=0

PROJECTS=(
    /usr/local/src/iverilog
    /usr/local/src/dnsmasq
    /usr/local/src/nvc-build
    /usr/local/src/ghdl
    /usr/local/src/xyce-build
    /usr/local/src/Trilinos-Build
)

for dir in "${PROJECTS[@]}"; do
    name=$(basename "$dir")

    if [ ! -d "$dir" ]; then
        echo "  SKIP $name (directory not found)"
        ((SKIPPED++))
        continue
    fi

    echo -n "  $name: clean..."
    CLEAN_OUT=$($SMAK -C "$dir" clean 2>&1)
    CLEAN_RC=$?
    # clean failure is not fatal (target may not exist)

    echo -n " build -j4..."
    START=$(date +%s)
    BUILD_OUT=$($SMAK -C "$dir" -j4 2>&1)
    BUILD_RC=$?
    END=$(date +%s)
    DUR=$((END - START))

    if [ $BUILD_RC -eq 0 ]; then
        echo " PASS (${DUR}s)"
        ((PASSED++))
    else
        echo " FAIL (exit $BUILD_RC, ${DUR}s)"
        echo "$BUILD_OUT" | tail -20
        ((FAILED++))
    fi
done

echo ""
echo "Projects: $PASSED passed, $FAILED failed, $SKIPPED skipped"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
exit 0
