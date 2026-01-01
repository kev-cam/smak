#!/bin/bash
# Update reference dry-run outputs for all project Makefiles
# Run this when you've verified a Makefile parses correctly and want to save the reference output

echo "Updating project Makefile dry-run references..."
echo ""

PROJECTS_DIR="../projects"
UPDATED=0
FAILED=0

# Find all Makefiles in projects directory
while IFS= read -r -d '' makefile; do
    # Get the directory and basename
    dir=$(dirname "$makefile")
    base=$(basename "$makefile")

    # Skip .smak-dry files
    if [[ "$base" == *.smak-dry ]]; then
        continue
    fi

    echo "Processing: $makefile"

    # Run smak --dry-run
    cd "$dir" || continue
    output=$(../../smak --dry-run -f "$base" 2>&1)
    exit_code=$?
    cd - > /dev/null || exit 1

    # Check if it parsed successfully
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 2 ]; then
        echo "  ✗ ERROR: smak exited with code $exit_code"
        echo "$output" | head -10
        ((FAILED++))
        continue
    fi

    # Check for parsing errors
    if echo "$output" | grep -q "^Error:"; then
        echo "  ✗ ERROR: Parse errors detected"
        echo "$output" | grep "^Error:"
        ((FAILED++))
        continue
    fi

    # Save reference output
    reference="${makefile}.smak-dry"
    echo "$output" > "$reference"
    echo "  ✓ Updated: $reference"
    ((UPDATED++))

done < <(find "$PROJECTS_DIR" -type f -name "Makefile*" ! -name "*.smak-dry" -print0 | sort -z)

echo ""
echo "========================================="
echo "Updated: $UPDATED files"
echo "Failed:  $FAILED files"
echo "========================================="

if [ $FAILED -gt 0 ]; then
    exit 1
else
    exit 0
fi
