# Sub-makefile for nested make test

.PHONY: all target1 target2

all: target1 target2
	@echo "Subdir all done"

target1:
	@echo "Building target1 in subdir"
	touch target1.txt

target2:
	@echo "Building target2 in subdir"
	touch target2.txt
