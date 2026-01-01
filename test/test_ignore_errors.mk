.PHONY: test
test:
	@echo "Step 1"
	-false
	@echo "Step 2 - this should run even though false failed"
	@echo "Test passed!"
