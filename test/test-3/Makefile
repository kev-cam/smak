# Auto-generated Makefile for smak testing
# Uses dummy-command to simulate build processes

DUMMY := ../dummy-command

# Source files
SOURCES += src1.txt
SOURCES += src2.txt
SOURCES += src3.txt
SOURCES += src4.txt
SOURCES += src5.txt

# Object/intermediate files
OBJECTS += obj1.o
OBJECTS += obj2.o
OBJECTS += obj3.o
OBJECTS += obj4.o
OBJECTS += obj5.o

# Final targets
TARGETS += target1
TARGETS += target2
TARGETS += target3

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

src3.txt:
	@echo "Creating starter file: $@"
	@echo "Source 3" > $@

src4.txt:
	@echo "Creating starter file: $@"
	@echo "Source 4" > $@

src5.txt:
	@echo "Creating starter file: $@"
	@echo "Source 5" > $@

# Object file rules
obj1.o:  src1.txt
	$(DUMMY) -in  src1.txt -out $@

obj2.o:  src2.txt
	$(DUMMY) -in  src2.txt -out $@

obj3.o:  src1.txt src3.txt src4.txt
	$(DUMMY) -in  src1.txt src3.txt src4.txt -out $@

obj4.o:  src5.txt
	$(DUMMY) -in  src5.txt -out $@

obj5.o:  src5.txt src1.txt
	$(DUMMY) -in  src5.txt src1.txt -out $@

# Final target rules
target1:  obj5.o obj3.o
	$(DUMMY) -in  obj5.o obj3.o -out $@

target2:  obj3.o obj3.o obj1.o
	$(DUMMY) -in  obj3.o obj3.o obj1.o -out $@

target3:  obj5.o obj2.o obj5.o obj4.o
	$(DUMMY) -in  obj5.o obj2.o obj5.o obj4.o -out $@

# Clean up generated files
clean:
	rm -f $(SOURCES) $(OBJECTS) $(TARGETS)
	@echo "Cleaned all generated files"
