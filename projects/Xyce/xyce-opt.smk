# xyce-opt.smk - Smak script to convert debug build to optimized build
#
# Usage: USR_SMAK_OPT='-Ks xyce-opt.smk' smak [target]
#
# This script modifies compiler flags to remove debug symbols and add
# optimization, allowing an optimized build from a debug-configured source
# tree without reconfiguring CMake.

# Strategy:
# 1. Remove -g (debug symbols) and -O0 (no optimization)
# 2. Add -O3 (aggressive optimization) and -DNDEBUG (disable asserts)
# 3. Optionally suffix output binary with -opt

# Example modifications for typical CMake-generated Makefiles:
# ============================================================

# If your debug Makefile has rules like:
#   Xyce.C.o: Xyce.C
#       $(CXX) -g -O0 $(OTHER_FLAGS) -c Xyce.C -o Xyce.C.o
#
# You would add:
# mod-rule Xyce.C.o : $(CXX) -O3 -DNDEBUG $(OTHER_FLAGS) -c Xyce.C -o $@

# For the main executable link rule:
# If debug Makefile has:
#   Xyce: Xyce.C.o lib1.a lib2.a
#       $(CXX) -g Xyce.C.o lib1.a lib2.a -o Xyce $(LDFLAGS)
#
# You would add:
# mod-rule Xyce : $(CXX) -O3 $^ -o Xyce-opt $(LDFLAGS)

# INSTRUCTIONS TO CUSTOMIZE:
# ==========================
# 1. Run: cmake -DCMAKE_BUILD_TYPE=Debug ... (your debug configuration)
# 2. Examine the generated Makefile in your build directory
# 3. Look for compilation rules (*.o targets) and link rules (executable targets)
# 4. For each rule with -g -O0, add a mod-rule command below that replaces
#    those flags with -O3 -DNDEBUG
# 5. Save this file
# 6. Build with: USR_SMAK_OPT='-Ks xyce-opt.smk' smak -f path/to/Makefile all
#
# Example for a typical CMake build:
# ==================================
# After examining build/src/Makefile, you might add:

# Modify main Xyce source file compilation
# mod-rule src/Xyce.C.o : $(CXX) -O3 -DNDEBUG -std=c++17 -Iinclude -c src/Xyce.C -o $@

# Modify package object files (repeat for each package)
# mod-rule src/CircuitPKG/N_CIR_Xyce.C.o : $(CXX) -O3 -DNDEBUG -std=c++17 -Iinclude -c src/CircuitPKG/N_CIR_Xyce.C -o $@

# Modify the final link step to create optimized binary
# mod-rule Xyce : $(CXX) -O3 $^ -o Xyce-opt -ltrilinos -lblas -llapack

# NOTE: The above are examples. Actual rules depend on your Makefile structure.
# Use `smak -f Makefile -Kd` then `list` to see available targets,
# then `show <target>` to see the rule that needs modification.

