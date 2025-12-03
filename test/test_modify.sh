#!/bin/bash
# Test rule modification and save/load functionality

echo "Testing rule modification and save/load..."
echo ""

# Clean up any previous test files
rm -f Makefile.nested-smak

echo "Test 1: Add a new rule, modify dependencies, and save"
cat <<'EOF' | ../smak -f Makefile.nested -Kd
add-rule newtest : test.o : gcc -o newtest test.o
list
show newtest
mod-deps all : test.o newtest
show all
save
quit
EOF

echo ""
echo "Test 2: Check that the save file was created"
if [ -f "Makefile.nested-smak" ]; then
    echo "Save file created successfully:"
    cat Makefile.nested-smak
else
    echo "ERROR: Save file not created!"
fi

echo ""
echo "Test 3: Load the saved modifications"
../smak -f Makefile.nested -Kd < Makefile.nested-smak

echo ""
echo "Test 4: Test delete rule"
cat <<'EOF' | ../smak -f Makefile.nested -Kd
add-rule temptest : foo.o : gcc -o temptest foo.o
list
del-rule temptest
list
quit
EOF

echo ""
echo "Test 5: Test modify rule"
cat <<'EOF' | ../smak -f Makefile.nested -Kd
mod-rule all : echo Building all\n\techo Done
show all
quit
EOF

echo ""
echo "All tests completed"
