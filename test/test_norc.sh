#!/bin/bash
# Test -norc option to skip .smak.rc files

echo "Testing -norc option..."
echo ""

# Create a test rc file that sets a custom makefile variable
cat > test_norc.rc <<'EOF'
# Test rc file
set makefile = "TestMakefile.norc"
EOF

# Create the default Makefile
cat > Makefile <<'EOF'
.PHONY: all
all:
	@echo "Using default Makefile"
EOF

# Create the custom makefile that rc file tries to use
cat > TestMakefile.norc <<'EOF'
.PHONY: all
all:
	@echo "Using TestMakefile.norc from rc file"
EOF

echo "Test 1: With SMAK_RCFILE (should read rc file and use TestMakefile.norc)"
OUTPUT_WITH_RC=$(SMAK_RCFILE=test_norc.rc ${USR_SMAK_SCRIPT:-smak} all 2>&1)
if echo "$OUTPUT_WITH_RC" | grep -q "Using TestMakefile.norc"; then
    echo "  PASS: RC file was read (makefile variable was set)"
elif echo "$OUTPUT_WITH_RC" | grep -q "Using default Makefile"; then
    echo "  FAIL: RC file was not read (used default Makefile instead)"
    echo "  Output: $OUTPUT_WITH_RC"
else
    echo "  ERROR: Unexpected output"
    echo "  Output: $OUTPUT_WITH_RC"
fi

echo ""
echo "Test 2: With -norc flag (should NOT read default .smak.rc)"
OUTPUT_WITHOUT_RC=$(${USR_SMAK_SCRIPT:-smak} -norc all 2>&1)
if echo "$OUTPUT_WITHOUT_RC" | grep -q "Using default Makefile"; then
    echo "  PASS: RC file was ignored (used default Makefile)"
elif echo "$OUTPUT_WITHOUT_RC" | grep -q "Using TestMakefile.norc"; then
    echo "  FAIL: RC file was read despite -norc flag"
    echo "  Output: $OUTPUT_WITHOUT_RC"
else
    echo "  ERROR: Unexpected output"
    echo "  Output: $OUTPUT_WITHOUT_RC"
fi

echo ""
echo "Test 3: Verify -norc overrides SMAK_RCFILE environment variable"
OUTPUT_ENV=$(SMAK_RCFILE=test_norc.rc ${USR_SMAK_SCRIPT:-smak} -norc all 2>&1)
if echo "$OUTPUT_ENV" | grep -q "Using default Makefile"; then
    echo "  PASS: SMAK_RCFILE ignored with -norc"
elif echo "$OUTPUT_ENV" | grep -q "Using TestMakefile.norc"; then
    echo "  FAIL: SMAK_RCFILE was used despite -norc"
    echo "  Output: $OUTPUT_ENV"
else
    echo "  ERROR: Unexpected output"
    echo "  Output: $OUTPUT_ENV"
fi

# Cleanup
rm -f Makefile TestMakefile.norc test_norc.rc

echo ""
echo "All tests completed"
