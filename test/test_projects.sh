#!/bin/bash
# Test real-world Makefiles from projects directory
# This test verifies that project Makefiles parse correctly and produce consistent dry-run output

echo "Testing project Makefiles..."
echo ""

PROJECTS_DIR="../projects"
FAILED=0
PASSED=0
UPDATED=0

# Find all Makefiles in projects directory
while IFS= read -r -d '' makefile; do
    # Get the directory and basename
    dir=$(dirname "$makefile")
    base=$(basename "$makefile")

    # Skip .smak-dry files
    if [[ "$base" == *.smak-dry ]]; then
        continue
    fi

    echo "Testing: $makefile"

    # Run smak --dry-run
    cd "$dir" || continue
    output=$(${USR_SMAK_SCRIPT:-smak} --dry-run -f "$base" 2>&1)
    exit_code=$?
    cd - > /dev/null || exit 1

    # Check if it parsed successfully (exit code 0 or 2 are acceptable for dry-run)
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 2 ]; then
        echo "  ✗ FAIL: smak exited with code $exit_code"
        echo "$output" | head -20
        ((FAILED++))
        continue
    fi

    # Check for parsing errors/warnings
    if echo "$output" | grep -q "^Error:"; then
        echo "  ✗ FAIL: Parse errors detected"
        echo "$output" | grep "^Error:"
        ((FAILED++))
        continue
    fi

    # Check if reference output exists
    reference="${makefile}.smak-dry"
    if [ ! -f "$reference" ]; then
        echo "  ℹ Creating reference output: $reference"
        echo "$output" > "$reference"
        ((UPDATED++))
    else
        # Compare with reference output
        if diff -q <(echo "$output") "$reference" > /dev/null 2>&1; then
            echo "  ✓ PASS: Output matches reference"
            ((PASSED++))
        else
            echo "  ✗ FAIL: Output differs from reference"
            echo "    Run: diff <(${USR_SMAK_SCRIPT:-smak} --dry-run -f $base) $reference"
            ((FAILED++))
        fi
    fi

done < <(find "$PROJECTS_DIR" -type f -name "Makefile*" -print0 | sort -z)

echo ""
echo "========================================="
echo "Results:"
echo "  Passed:  $PASSED"
echo "  Failed:  $FAILED"
echo "  Updated: $UPDATED"
echo "========================================="

if [ $FAILED -gt 0 ]; then
    exit 1
else
    exit 0
fi
