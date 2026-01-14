# Makefile for running smak tests
# Usage: smak <test-name>  (e.g., smak test_suffix_rules)

SHELL := /bin/bash

# Force default target by having a non-phony target first
default: list
	@true

.PHONY: all list run-all

all: list

list:
	@./list-tests.sh

# Run all tests
run-all:
	@passed=0; failed=0; skipped=0; \
	for t in test*.sh; do \
		name=$${t%.sh}; \
		echo ""; \
		echo "========================================"; \
		echo "Running $$name..."; \
		echo "========================================"; \
		if bash "$$t"; then \
			echo "PASS: $$name"; \
			passed=$$((passed + 1)); \
		elif [ $$? -eq 77 ]; then \
			echo "SKIP: $$name"; \
			skipped=$$((skipped + 1)); \
		else \
			echo "FAIL: $$name"; \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "========================================"; \
	echo "Results: $$passed passed, $$failed failed, $$skipped skipped"; \
	echo "========================================"; \
	[ $$failed -eq 0 ]

# Individual test targets - one rule per test
.PHONY: test_autorescan
test_autorescan:
	@bash $@.sh

.PHONY: test_autorescan-fail
test_autorescan-fail:
	@bash $@.sh

.PHONY: test_benchmark
test_benchmark:
	@bash $@.sh

.PHONY: test_builtin_optimization
test_builtin_optimization:
	@bash $@.sh

.PHONY: test_builtin_optimization-fail
test_builtin_optimization-fail:
	@bash $@.sh

.PHONY: test_categories
test_categories:
	@bash $@.sh

.PHONY: test_command_prefixes
test_command_prefixes:
	@bash $@.sh

.PHONY: test_debug
test_debug:
	@bash $@.sh

.PHONY: test_debug_simple
test_debug_simple:
	@bash $@.sh

.PHONY: test-default-target
test-default-target:
	@bash $@.sh

.PHONY: test_dryrun
test_dryrun:
	@bash $@.sh

.PHONY: test_echo
test_echo:
	@bash $@.sh

.PHONY: test_eval_set
test_eval_set:
	@bash $@.sh

.PHONY: test_format
test_format:
	@bash $@.sh

.PHONY: test_ghdl
test_ghdl:
	@bash $@.sh

.PHONY: test_gmake_funcs
test_gmake_funcs:
	@bash $@.sh

.PHONY: test_individual
test_individual:
	@bash $@.sh

.PHONY: test_iverilog
test_iverilog:
	@bash $@.sh

.PHONY: test_makecmp
test_makecmp:
	@bash $@.sh

.PHONY: test_modify
test_modify:
	@bash $@.sh

.PHONY: test_multiple_pattern_rules
test_multiple_pattern_rules:
	@bash $@.sh

.PHONY: test_nested
test_nested:
	@bash $@.sh

.PHONY: test_norc
test_norc:
	@bash $@.sh

.PHONY: test_nvc
test_nvc:
	@bash $@.sh

.PHONY: test_nvc_objext
test_nvc_objext:
	@bash $@.sh

.PHONY: test_objext_expansion
test_objext_expansion:
	@bash $@.sh

.PHONY: test_phony_repeat
test_phony_repeat:
	@bash $@.sh

.PHONY: test_print
test_print:
	@bash $@.sh

.PHONY: test_print2
test_print2:
	@bash $@.sh

.PHONY: test_print_fixes
test_print_fixes:
	@bash $@.sh

.PHONY: test_projects
test_projects:
	@bash $@.sh

.PHONY: test_rcfile
test_rcfile:
	@bash $@.sh

.PHONY: test_readline
test_readline:
	@bash $@.sh

.PHONY: test_recursive_parallel
test_recursive_parallel:
	@bash $@.sh

.PHONY: test_scanner
test_scanner:
	@bash $@.sh

.PHONY: test_script
test_script:
	@bash $@.sh

.PHONY: test_ssh_localhost
test_ssh_localhost:
	@bash $@.sh

.PHONY: test_suffix_collision
test_suffix_collision:
	@bash $@.sh

.PHONY: test_suffix_rules
test_suffix_rules:
	@bash $@.sh

.PHONY: test_timeout
test_timeout:
	@bash $@.sh

.PHONY: test_var_translation
test_var_translation:
	@bash $@.sh

.PHONY: test_xyce
test_xyce:
	@bash $@.sh
