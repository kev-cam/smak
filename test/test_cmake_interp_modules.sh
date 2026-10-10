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
# xyce-build (2026-10-10): an interpreter-configured build directory must be
# configured again when a CMake input changes (it kept a July Xyce_config.h),
# and Xyce's NEURON option - a CACHE STRING dir under ${PROJECT_SOURCE_DIR}
# tested with EXISTS in an included .cmake, then #cmakedefine - must agree
# with cmake
mkdir -p src/cmake src/models
cat >> src/CMakeLists.txt <<'EOF2'
include(cmake/feature.cmake)
configure_file(cfg.h.cmake ${PROJECT_BINARY_DIR}/cfg.h)
EOF2
cat > src/cmake/feature.cmake <<'EOF2'
if (NOT DEFINED MODELS_DIR)
  set (MODELS_DIR "${PROJECT_SOURCE_DIR}/models" CACHE STRING "models")
endif ()
if ((WITH_MODELS OR NOT DEFINED WITH_MODELS) AND EXISTS "${MODELS_DIR}")
  set (WITH_MODELS TRUE CACHE BOOL "models")
elseif (NOT DEFINED WITH_MODELS)
  set (WITH_MODELS FALSE CACHE BOOL "models")
else ()
  set (WITH_MODELS FALSE CACHE BOOL "models" FORCE)
endif ()
EOF2
printf '#cmakedefine WITH_MODELS\n' > src/cfg.h.cmake
# install.sh and the export file must name the file the link step produced
# (OUTPUT_NAME/VERSION/SOVERSION): xyce-build's install.sh copied the
# nonexistent libXyceLib.so while the build had made libxyce.so
cat >> src/CMakeLists.txt <<'EOF2'
add_library(XyceLib SHARED core.c)
set_target_properties(XyceLib PROPERTIES OUTPUT_NAME xyce VERSION 1.2.3 SOVERSION 1)
install(TARGETS XyceLib EXPORT XyceLibTarget LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)
install(EXPORT XyceLibTarget FILE XyceTargets.cmake NAMESPACE Xyce:: DESTINATION lib/cmake/Xyce)
EOF2
rm -rf b2; mkdir b2
(cd b2 && $SMAK -cmake-interp-only -S ../src -B . >/dev/null 2>&1)
if grep -q '^#define WITH_MODELS' b2/cfg.h; then echo "PASS: option from an EXISTS test on a PROJECT_SOURCE_DIR path"
else echo "FAIL: option from an EXISTS test: $(cat b2/cfg.h)"; fail=1; fi
(cd b2 && timeout 120 $SMAK >/dev/null 2>&1)
sleep 1; printf '#cmakedefine WITH_MODELS\n#define CFG_V2 1\n' > src/cfg.h.cmake
out=$(cd b2 && timeout 120 $SMAK 2>&1)
if grep -q 'CFG_V2' b2/cfg.h && grep -q 're-running the configure' <<<"$out"; then echo "PASS: changed CMake input re-runs the configure"
else echo "FAIL: changed CMake input re-runs the configure"; fail=1; fi
out=$(cd b2 && timeout 120 $SMAK 2>&1)
if ! grep -q 're-running the configure' <<<"$out"; then echo "PASS: unchanged inputs do not re-run the configure"
else echo "FAIL: configure re-run with nothing changed"; fail=1; fi
# a re-run whose configure_file output is unchanged must not touch it (cmake
# keeps the mtime, so nothing that includes it recompiles)
m1=$(stat -c %Y b2/cfg.h); sleep 1; touch src/cmake/feature.cmake
out=$(cd b2 && timeout 120 $SMAK 2>&1); m2=$(stat -c %Y b2/cfg.h)
if grep -q 're-running the configure' <<<"$out" && [ "$m1" = "$m2" ]; then echo "PASS: unchanged configure_file output keeps its mtime"
else echo "FAIL: unchanged configure_file output rewritten (mtime $m1 -> $m2)"; fail=1; fi
if [ -f b2/libxyce.so.1.2.3 ] && [ -L b2/libxyce.so ] && grep -q '_cp_file "[^"]*/libxyce.so.1.2.3"' b2/install.sh \
   && grep -q '_ln_file "libxyce.so.1" "[^"]*/lib" "libxyce.so"' b2/install.sh && ! grep -q 'libXyceLib' b2/install.sh b2/_export_XyceLibTarget_XyceTargets.cmake \
   && grep -q 'lib/libxyce.so' b2/_export_XyceLibTarget_XyceTargets.cmake; then echo "PASS: install.sh and export use the OUTPUT_NAME/VERSION file names"
else echo "FAIL: install.sh/export file names"; ls b2 | grep -i xyce; grep -n 'xyce\|Xyce' b2/install.sh b2/_export_XyceLibTarget_XyceTargets.cmake | head; fail=1; fi
rm -rf inst; (cd b2 && DESTDIR=$d/inst bash ./install.sh >/dev/null 2>&1)
if [ -f inst/usr/local/lib/libxyce.so.1.2.3 ] && [ -L inst/usr/local/lib/libxyce.so ] && [ -L inst/usr/local/lib/libxyce.so.1 ]; then echo "PASS: install.sh installs the shared library and its links"
else echo "FAIL: install.sh install"; ls -la inst/usr/local/lib 2>&1 | head; fail=1; fi
exit $fail
