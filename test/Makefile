CC = gcc
CFLAGS = -Wall -O2

all: program

program: main.o utils.o
	$(CC) $(CFLAGS) -o program main.o utils.o

main.o: main.c
	$(CC) $(CFLAGS) -c main.c

utils.o: utils.c
	$(CC) $(CFLAGS) -c utils.c

clean:
	rm -f *.o program

VERILOG_FILES = $(wildcard *.v)
GATE_NETLISTS = $(patsubst %.v,work/%_syn.v,$(VERILOG_FILES))
