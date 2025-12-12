# Auto-generated Makefile for smak testing
# Uses dummy-command to simulate build processes

DUMMY := ../dummy-command

# Source files
SOURCES += src1.txt
SOURCES += src2.txt
SOURCES += src3.txt

# Object/intermediate files
OBJECTS += obj1.o
OBJECTS += obj2.o
OBJECTS += obj3.o
OBJECTS += obj4.o
OBJECTS += obj5.o

# Final targets
TARGETS += target1
TARGETS += target2

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

# Object file rules
obj1.o:  src3.txt src2.txt
	$(DUMMY) -in  src3.txt src2.txt -out $@

obj2.o:  src2.txt src2.txt src2.txt
	$(DUMMY) -in  src2.txt src2.txt src2.txt -out $@

obj3.o:  src2.txt src1.txt
	$(DUMMY) -in  src2.txt src1.txt -out $@

obj4.o:  src3.txt src3.txt
	$(DUMMY) -in  src3.txt src3.txt -out $@

obj5.o:  src3.txt src1.txt
	$(DUMMY) -in  src3.txt src1.txt -out $@

# Final target rules
target1:  obj3.o obj3.o
	$(DUMMY) -in  obj3.o obj3.o -out $@

target2:  obj3.o obj5.o obj4.o
	$(DUMMY) -in  obj3.o obj5.o obj4.o -out $@

# Clean up generated files
clean:
	rm -f $(SOURCES) $(OBJECTS) $(TARGETS)
	@echo "Cleaned all generated files"
