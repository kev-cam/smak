#!/bin/bash
# Test -norc option to skip .smak.rc files

echo "Testing -norc option..."
echo ""

# Save original rc file if it exists
ORIG_RC_EXISTS=0
if [ -f .smak.rc ]; then
    cp .smak.rc .smak.rc.backup
    ORIG_RC_EXISTS=1
fi

# Create a test rc file that sets a custom makefile variable
cat > .smak.rc <<'EOF'
# Test rc file - try to set makefile to a non-existent file
# If this is read, smak will fail to find TestMakefile.norc
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

echo "Test 1: Default behavior (should read .smak.rc and use TestMakefile.norc)"
OUTPUT_WITH_RC=$(../smak all 2>&1)
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
echo "Test 2: With -norc flag (should NOT read .smak.rc, use default Makefile)"
OUTPUT_WITHOUT_RC=$(../smak -norc all 2>&1)
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
OUTPUT_ENV=$(SMAK_RCFILE=.smak.rc ../smak -norc all 2>&1)
if echo "$OUTPUT_ENV" | grep -q "Using default Makefile"; then
    echo "  PASS: SMAK_RCFILE ignored with -norc"
elif echo "$OUTPUT_ENV" | grep -q "Using TestMakefile.norc"; then
    echo "  FAIL: SMAK_RCFILE was used despite -norc"
    echo "  Output: $OUTPUT_ENV"
else
    echo "  ERROR: Unexpected output"
    echo "  Output: $OUTPUT_ENV"
fi

# Restore original rc file
if [ $ORIG_RC_EXISTS -eq 1 ]; then
    mv .smak.rc.backup .smak.rc
else
    rm -f .smak.rc
fi

# Cleanup
rm -f Makefile TestMakefile.norc .smak.rc.test

echo ""
echo "All tests completed"
