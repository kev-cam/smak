# Test Makefile for suffix rule collision handling
# This tests that when multiple suffix rules map to the same target extension,
# the correct rule is selected based on which source file exists

.SUFFIXES: .c .cxx .o

# Suffix rule for C files
.c.o:
	gcc -c $< -o $@

# Suffix rule for C++ files
.cxx.o:
	g++ -c $< -o $@

# Test targets - note that only_c has only .c source, only_cxx has only .cxx source
all: only_c.o only_cxx.o

clean:
	rm -f *.o

.PHONY: all clean
