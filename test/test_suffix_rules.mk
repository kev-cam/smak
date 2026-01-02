# Test Makefile for C/C++ suffix rules
# This tests that .c.o and .cxx.o suffix rules work correctly
# and use the appropriate compiler for each file type

.SUFFIXES: .c .cxx .o

# Suffix rule for C files
.c.o:
	gcc -c $< -o $@

# Suffix rule for C++ files
.cxx.o:
	g++ -c $< -o $@

# Test targets
all: test_c.o test_cxx.o

clean:
	rm -f *.o

.PHONY: all clean
