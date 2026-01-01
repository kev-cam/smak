# Test that command prefix "-" (ignore errors) works correctly

.PHONY: all
all:
	@echo "Step 1"
	-rm -f lib/libtest.a
	@echo "Step 2"
