#!/bin/bash
# Regression: SmakCMake (cmake-metadata mode) link steps.  Found by
# smak-buildtest on zlib, cJSON and libuv (2026-09-28):
#   - link.txt was run from the top build dir, but its paths (../libz.a) are
#     relative to the target's own binary dir -> "cannot find ../libz.a"
#   - Makefile2 dependencies on top-level targets (CMakeFiles/x.dir/all,
#     no directory prefix) and target names with '-' were not parsed, so an
#     executable in a subdirectory linked before its library existed
#   - versioned shared libraries got no soname/dev symlinks
#     (cmake -E cmake_symlink_library), so programs could not start and a
#     following `make` relinked everything
# and the same project through smak's own CMakeLists interpreter
# (-cmake-interp-only): OUTPUT_NAME/VERSION/SOVERSION were ignored and there
# was no build-tree RPATH, so app-shared could not find its library.
set -u
SMAK=${SMAK:-$(cd "$(dirname "$0")/.." && pwd)/smak}
command -v cmake >/dev/null || { echo "SKIP: cmake not installed"; exit 77; }
command -v cc >/dev/null || { echo "SKIP: no C compiler"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
unset USR_SMAK_OPT

mkdir -p src/app
cat > src/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(linkdirs C)
add_library(core-static STATIC core.c)
add_library(core-shared SHARED core.c)
set_target_properties(core-shared PROPERTIES VERSION 1.2.3 SOVERSION 1 OUTPUT_NAME core)
add_subdirectory(app)
EOF
printf 'int core(void) { return 42; }\n' > src/core.c
cat > src/app/CMakeLists.txt <<'EOF'
add_executable(app-static main.c)
target_link_libraries(app-static core-static)
add_executable(app-shared main.c)
target_link_libraries(app-shared core-shared)
EOF
printf 'int core(void);\nint main(void) { return core() == 42 ? 0 : 1; }\n' > src/app/main.c

fail=0
for j in "" "-j4"; do
    rm -rf build; cmake -S src -B build >/dev/null 2>&1 || { echo "SKIP: cmake configure failed"; exit 77; }
    out=$(cd build && timeout 120 $SMAK $j 2>&1); rc=$?
    redo=$(cd build && make 2>&1 | grep -c -E 'Building|Linking')
    if [ $rc -eq 0 ] && [ -L build/libcore.so.1 ] && [ -L build/libcore.so ] \
       && build/app/app-static && build/app/app-shared && [ "$redo" -eq 0 ]; then
        echo "PASS: ${j:-seq}"
    else
        echo "FAIL: ${j:-seq} (rc=$rc, make redid $redo steps)"
        grep -E 'cannot find|undefined|\*\*\*' <<<"$out" | head -5
        ls -la build/libcore* 2>&1 | head -5
        fail=1
    fi
done
for j in "" "-j4"; do
    rm -rf ibuild; mkdir ibuild
    (cd ibuild && $SMAK -cmake-interp-only -S ../src -B . >/dev/null 2>&1) || { echo "FAIL: interp ${j:-seq}: interpretation failed"; fail=1; continue; }
    out=$(cd ibuild && timeout 120 $SMAK $j 2>&1); rc=$?
    if [ $rc -eq 0 ] && [ -f ibuild/libcore.so.1.2.3 ] && [ -L ibuild/libcore.so.1 ] \
       && ibuild/app/app-static && ibuild/app/app-shared; then
        echo "PASS: interp ${j:-seq}"
    else
        echo "FAIL: interp ${j:-seq} (rc=$rc)"; ls ibuild ibuild/app 2>&1 | head; fail=1
    fi
done
exit $fail
