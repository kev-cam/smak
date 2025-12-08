# Test Makefile for parallel builds

all: task1 task2 task3 task4

task1:
	@echo "Task 1 starting..."
	@sleep 1
	@echo "Task 1 done!"

task2:
	@echo "Task 2 starting..."
	@sleep 1
	@echo "Task 2 done!"

task3:
	@echo "Task 3 starting..."
	@sleep 1
	@echo "Task 3 done!"

task4:
	@echo "Task 4 starting..."
	@sleep 1
	@echo "Task 4 done!"

.PHONY: all task1 task2 task3 task4
