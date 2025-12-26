# Test case for pattern rules and vpath
# This tests the fix for pattern dependency resolution and vpath handling

DUMMY := ../dummy-command

# Pattern rules with vpath
vpath %.cc src
vpath %.h .

# Compiler flags simulation
CFLAGS := -DTEST

# Targets
PROG := program

# Pattern rule: %.o depends on %.cc and config.h
%.o: %.cc config.h
	@echo "Compiling $< -> $@"
	$(DUMMY) -in $< config.h -out $@

# Final program depends on object files
$(PROG): main.o helper.o
	@echo "Linking $@"
	$(DUMMY) -in main.o helper.o -out $@

# Phony targets
.PHONY: all clean

all: $(PROG)

clean:
	rm -f *.o $(PROG)
	@echo "Cleaned all generated files"
