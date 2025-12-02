#!/bin/bash
# Test -Ks script option

echo "Testing -Ks script option..."
echo ""

echo "Test 1: Basic -Ks with target"
./smak -f Makefile.nested -Ks test.fixes mytest

echo ""
echo "Test 2: -Ks with environment variable"
USR_SMAK_OPT='-Ks test.fixes' ./smak -f Makefile.nested all

echo ""
echo "Test 3: -Ks with debug mode"
echo "list
show all
quit" | ./smak -f Makefile.nested -Ks test.fixes -Kd | grep -A 5 "All targets"

echo ""
echo "Test 4: Multiple targets"
./smak -f Makefile.nested -Ks test.fixes all mytest

echo ""
echo "All tests completed"
