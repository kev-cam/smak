#!/bin/bash
# Test -Ks script option

echo "Testing -Ks script option..."
echo ""

echo "Test 1: Basic -Ks with target"
${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Ks test.fixes mytest

echo ""
echo "Test 2: -Ks with environment variable"
USR_SMAK_OPT='-Ks test.fixes' ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested all

echo ""
echo "Test 3: -Ks with debug mode"
echo "quit" | ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Ks test.fixes -Kd > /dev/null 2>&1

echo ""
echo "Test 4: Multiple targets"
${USR_SMAK_SCRIPT:-smak} -f Makefile.nested -Ks test.fixes all mytest

echo ""
echo "All tests completed"
