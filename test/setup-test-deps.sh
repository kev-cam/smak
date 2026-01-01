#!/bin/bash
# Setup script for SMAK test dependencies
# Run this before executing the test suite

set -e

echo "Setting up SMAK test dependencies..."
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script needs to be run as root or with sudo"
    echo "Usage: sudo ./setup-test-deps.sh"
    exit 1
fi

# Install Perl PTY module for interactive test automation
echo "Installing libio-pty-perl..."
apt-get update -qq
apt-get install -y libio-pty-perl

# Verify installation
if perl -MIO::Pty -e 'print "IO::Pty installed successfully\n"' 2>/dev/null; then
    echo "✓ IO::Pty module installed and working"
else
    echo "✗ Failed to install IO::Pty module"
    exit 1
fi

echo ""
echo "✓ All test dependencies installed successfully"
echo ""
echo "You can now run the test suite:"
echo "  cd test && ./run-regression"
echo "  or: ./test/test-before-push"
