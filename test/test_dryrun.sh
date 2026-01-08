#!/bin/bash
# Test dry-run, make-cmp, and ! commands

echo "Testing --dry-run"
echo ""

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

rm -f Makefile.nested-dry.log

exit $sts

