# Smak Build Failure Analysis

## Test Run Information
- **Date**: 2025-12-12 20:34:00
- **Test**: failure-1-test1
- **Configuration**: 5 sources, 10 objects, 3 targets
- **Command**: `./run-tests -f 1 -t 1200`

## Makefile Structure

The generated Makefile has:
- Variables defined BEFORE phony declaration (lines 7-28)
- `.PHONY: all clean starters` declaration (line 31)
- `all: $(TARGETS)` rule (line 33)
- Individual target rules with proper dependencies and commands

Example from Makefile:
```makefile
TARGETS += target1
TARGETS += target2
TARGETS += target3

.PHONY: all clean starters

all: $(TARGETS)

src4.txt:
	@echo "Creating starter file: $@"
	@echo "Source 4" > $@
```

## GNU Make Behavior (CORRECT)

GNU make handles this Makefile correctly:
```bash
$ make -n all
echo "Creating starter file: src4.txt"
echo "Source 4" > src4.txt
echo "Creating starter file: src5.txt"
echo "Source 5" > src5.txt
../dummy-command -in  src4.txt src5.txt -out obj9.o
../dummy-command -in  src4.txt src4.txt -out obj10.o
../dummy-command -in  obj9.o obj10.o -out target1
[... continues building all dependencies ...]
```

## Smak Bugs Identified

### Bug #1: Variable Expansion in Phony Targets

**Symptom**: When building `all`, smak builds 0 dependencies

**Debug Output**:
```
DEBUG[1781]: Building target 'all' (depth=0, makefile=Makefile)
DEBUG[1908]:   Has rule: no
DEBUG[1919]:   Found .PHONY with deps: all, clean, starters
DEBUG[1930]:   After expansion: all, clean, starters
DEBUG[1943]:   is_phony=1
DEBUG[1963]:   Building 0 dependencies...
```

**Analysis**:
- Line 1919 finds the `.PHONY` declaration
- Line 1930 shows "After expansion: all, clean, starters"
- This suggests smak is looking at the `.PHONY` line for dependencies
- The actual rule `all: $(TARGETS)` on line 33 is being ignored
- `$(TARGETS)` is never expanded to `target1 target2 target3`

**Expected Behavior**:
- Should parse `all: $(TARGETS)` rule
- Should expand `$(TARGETS)` to `target1 target2 target3`
- Should build those 3 dependencies

### Bug #2: Rule Lookup/Content Detection

**Symptom**: Rules with content are reported as having no content

**Test**: `SMAK_DEBUG=1 smak src4.txt`

**Debug Output**:
```
DEBUG[1781]: Building target 'src4.txt' (depth=0, makefile=Makefile)
DEBUG[1908]:   Has rule: no
DEBUG[1919]:   Found .PHONY with deps: all, clean, starters
DEBUG[1930]:   After expansion: all, clean, starters
DEBUG[1943]:   is_phony=0
DEBUG[1963]:   Building 0 dependencies...
DEBUG[1968]:   Finished building dependencies
DEBUG[1971]:   Checking if should execute rule: rule defined=yes, has content=no
DEBUG[1975]:   Rule value: ''
```

**Analysis**:
- Line 1908: `Has rule: no` - Initially doesn't find the rule
- Line 1971: `rule defined=yes, has content=no` - Later acknowledges rule exists but has no content
- Line 1975: `Rule value: ''` - Rule content is empty string

**Actual Makefile Content** (lines 51-53):
```makefile
src4.txt:
	@echo "Creating starter file: $@"
	@echo "Source 4" > $@
```

**The rule clearly has content!**

This appears to be a critical bug in smak's rule parsing or storage. The rule is defined in the Makefile with commands, but smak either:
1. Fails to parse the recipe lines, or
2. Parses them but stores empty content, or
3. Looks up the wrong rule object

### Bug #3: Hang with "Waiting forprocess"

**Symptom**: Smak prints "Waiting forprocess: NNN" and appears to hang

**Debug Output**:
```
Waiting forprocess: 20258
```

**Analysis**:
- This message appears at the end of failed builds
- The process ID changes each time
- Smak doesn't exit cleanly
- This causes the build to hang until timeout

## Impact

These bugs make smak **completely unable to build** the generated test Makefiles:

1. Can't build via `all` target (Bug #1 - variable expansion)
2. Can't build individual targets (Bug #2 - rule content lost)
3. Hangs instead of exiting (Bug #3 - process cleanup)

## Comparison: GNU Make vs Smak

| Aspect | GNU Make | Smak |
|--------|----------|------|
| Variable expansion in dependencies | ✅ Works | ❌ Broken |
| Rule content parsing | ✅ Works | ❌ Broken |
| Building phony targets | ✅ Works | ❌ Broken |
| Process cleanup | ✅ Works | ❌ Hangs |

## Test Success Rate

- **Tests run**: 1
- **Passed**: 0
- **Failed**: 1
- **Pass rate**: 0.0%

All failures are due to smak bugs, not Makefile issues. The generated Makefiles are valid and work correctly with GNU make.

## Recommendations

1. **Fix variable expansion**: Smak needs to expand `$(TARGETS)` when parsing `all: $(TARGETS)`
2. **Fix rule parsing**: Investigate why rule content is being lost or not stored
3. **Fix process cleanup**: Fix the "Waiting forprocess" hang
4. **Add debug output**: Line numbers in Makefile would help debugging
5. **Add regression tests**: Use these generated Makefiles as smak test cases

## Files for Reproduction

All artifacts saved in: `test/failures-20251212-203400/failure-1-test1/`
- `Makefile` - The failing Makefile (works with GNU make)
- `logs/build-sequential.log` - Full debug output from smak
