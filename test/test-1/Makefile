# Auto-generated Makefile for smak testing
# Uses dummy-command to simulate build processes

DUMMY := ../dummy-command

# Source files
SOURCES += src1.txt
SOURCES += src2.txt

# Object/intermediate files
OBJECTS += obj1.o
OBJECTS += obj2.o

# Final targets
TARGETS += target1

# Phony targets
.PHONY: all clean starters

all: $(TARGETS)

# Create starter source files
starters: $(SOURCES)

# Source file rules
src1.txt:
	@echo "Creating starter file: $@"
	@echo "Source 1" > $@

src2.txt:
	@echo "Creating starter file: $@"
	@echo "Source 2" > $@

# Object file rules
obj1.o:  src2.txt src1.txt
	$(DUMMY) -in  src2.txt src1.txt -out $@

obj2.o:  src2.txt
	$(DUMMY) -in  src2.txt -out $@

# Final target rules
target1:  obj1.o obj2.o
	$(DUMMY) -in  obj1.o obj2.o -out $@

# Clean up generated files
clean:
	rm -f $(SOURCES) $(OBJECTS) $(TARGETS)
	@echo "Cleaned all generated files"
