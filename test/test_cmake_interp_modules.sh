#!/bin/bash
# Regression: smak's CMakeLists interpreter (-cmake-interp-only) on what
# zlib and libuv use (found by smak-buildtest, 2026-09-29):
#   - include(CTest), include(CMakeDependentOption) ... found nothing without
#     a bundled cmake: the modules of the cmake on PATH are used now
#   - cmake_dependent_option (from that module), check_type_size
#     (HAVE_OFF64_T with CMAKE_REQUIRED_DEFINITIONS), file(STRINGS ... REGEX)
#   - ARCHIVE_OUTPUT_NAME (zlibstatic -> libz.a)
#   - a .manifest source is not compiled or linked
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v cmake >/dev/null || { echo "SKIP: cmake not installed"; exit 77; }
command -v cc >/dev/null || { echo "SKIP: no C compiler"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT

mkdir src
cat > src/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(mods C)
include(CMakeDependentOption)
include(CheckTypeSize)
include(CTest)
cmake_dependent_option(WITH_TESTS "tests" ON "BUILD_TESTING" OFF)
cmake_dependent_option(WITH_NEVER "never" ON "NOT BUILD_TESTING" OFF)
set(CMAKE_REQUIRED_DEFINITIONS -D_LARGEFILE64_SOURCE=1)
check_type_size(off64_t OFF64_T)
unset(CMAKE_REQUIRED_DEFINITIONS)
file(STRINGS version.txt vline REGEX "^VERSION")
string(REGEX MATCH "([0-9]+)[.][0-9]+" full "${vline}")
set(MAJOR "${CMAKE_MATCH_1}")
add_library(corestatic STATIC core.c)
set_target_properties(corestatic PROPERTIES ARCHIVE_OUTPUT_NAME core)
if(WITH_TESTS AND HAVE_OFF64_T AND OFF64_T EQUAL 8)
  add_executable(app_${MAJOR} main.c app.manifest)
  target_link_libraries(app_${MAJOR} corestatic)
endif()
if(WITH_NEVER)
  add_executable(never main.c)
endif()
EOF
printf 'int core(void) { return 42; }\n' > src/core.c
printf 'int core(void);\nint main(void) { return core() == 42 ? 0 : 1; }\n' > src/main.c
printf '<assembly/>\n' > src/app.manifest
printf 'NAME demo\nVERSION 7.3\n' > src/version.txt

fail=0
mkdir build
(cd build && $SMAK -cmake-interp-only -S ../src -B . > ../interp.log 2>&1) || { echo "FAIL: interpretation"; cat interp.log | tail -5; exit 1; }
if grep -q "unknown commands" interp.log; then
    echo "FAIL: unknown commands"; grep -A5 "unknown commands" interp.log; fail=1
else
    echo "PASS: no unknown commands"
fi
out=$(cd build && timeout 120 $SMAK -j2 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -f build/libcore.a ] && build/app_7 && [ ! -e build/never ]; then
    echo "PASS: build"
else
    echo "FAIL: build (rc=$rc)"; ls build; echo "$out" | tail -5; fail=1
fi
exit $fail
