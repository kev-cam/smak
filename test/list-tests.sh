#!/bin/bash
# List available tests
echo "Available tests:"
echo ""
for f in test_*.sh test-*.sh; do
    [ -f "$f" ] && echo "  ${f%.sh}"
done | sort
echo ""
echo "Run a test: smak <test-name>"
echo "Run all: smak run-all"
