#!/bin/bash

SCRIPT_DIR=$(dirname $0)

case ${SMAK_CMAKE_ANNOUNCE:-no} in
    yes|1) echo "Smak intercpting..." ;;
    debug) set -xv ;;
esac   

# Execute the Perl script with all arguments passed through
exec perl "$SCRIPT_DIR/smak.pl" -cmake "$@"
