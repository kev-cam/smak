#!/bin/bash
# Test dry-run, make-cmp, and ! commands

echo "Testing --dry-run"
echo ""

# Clean up test.o to ensure dry-run shows what would be built
rm -f test.o

timeout 5 ${USR_SMAK_SCRIPT:-smak} -f Makefile.nested-dry --dry-run > Makefile.nested-dry.log
sts=$?
wait
cat Makefile.nested-dry.log

case $sts in
    0) set -- `grep Makefile.nested-dry Makefile.nested-dry.log | grep no-gcc | wc -l`
       if [ $1 != 1 ] ; then
	   sts=2
       fi
       ;;
esac

rm -f Makefile.nested-dry.log test.o

exit $sts

