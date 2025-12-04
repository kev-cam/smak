#!/bin/bash

SCRIPT_DIR=$(dirname $0)

# Execute the Perl script with all arguments passed through
exec perl "$SCRIPT_DIR/smak.pl" -cmake "$@"
