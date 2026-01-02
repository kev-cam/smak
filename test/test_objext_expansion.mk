# Test OBJEXT expansion in automake-style Makefiles
# This replicates the issue found in projects/nvc/Makefile

OBJEXT = o
AR = gcc-ar
ARFLAGS = cr
RANLIB = ranlib

# Automake verbosity variables
AM_DEFAULT_VERBOSITY = 0
am__v_AR_0 = @echo "  AR      " $@;
am__v_AR_1 =
am__v_AR_ = $(am__v_AR_$(AM_DEFAULT_VERBOSITY))
AM_V_AR = $(am__v_AR_$(V))

am__v_at_0 = @
am__v_at_1 =
am__v_at_ = $(am__v_at_$(AM_DEFAULT_VERBOSITY))
AM_V_at = $(am__v_at_$(V))

# Object files list with $(OBJEXT) references
lib_libnvc_a_OBJECTS = \
	src/lib.$(OBJEXT) \
	src/util.$(OBJEXT) \
	src/ident.$(OBJEXT) \
	src/parse.$(OBJEXT) \
	src/lexer.$(OBJEXT)

lib_libnvc_a_AR = $(AR) $(ARFLAGS)
lib_libnvc_a_LIBADD =

# Rule for building the library
lib/libnvc.a: $(lib_libnvc_a_OBJECTS)
	$(AM_V_at)-rm -f lib/libnvc.a
	$(AM_V_AR)$(lib_libnvc_a_AR) lib/libnvc.a $(lib_libnvc_a_OBJECTS) $(lib_libnvc_a_LIBADD)
	$(AM_V_at)$(RANLIB) lib/libnvc.a

.PHONY: all
all: lib/libnvc.a
