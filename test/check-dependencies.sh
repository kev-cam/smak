#!/bin/bash
# Check for required Perl modules for automated testing

echo "Checking Perl module dependencies..."
echo ""

missing=0

# Check for IO::Pty
if perl -MIO::Pty -e 'exit 0' 2>/dev/null; then
    echo "✓ IO::Pty is installed"
else
    echo "✗ IO::Pty is MISSING"
    echo "  Install with: sudo apt-get install libio-pty-perl"
    missing=1
fi

# Check for Term::ReadLine::Gnu
if perl -MTerm::ReadLine -e 'my $t = Term::ReadLine->new("test"); exit($t->ReadLine eq "Term::ReadLine::Gnu" ? 0 : 1)' 2>/dev/null; then
    echo "✓ Term::ReadLine::Gnu is installed"
else
    echo "✗ Term::ReadLine::Gnu is MISSING (using stub)"
    echo "  Install with: sudo apt-get install libterm-readline-gnu-perl"
    missing=1
fi

echo ""
if [ $missing -eq 0 ]; then
    echo "All dependencies satisfied!"
    exit 0
else
    echo "Please install the missing modules for automated testing to work."
    exit 1
fi
