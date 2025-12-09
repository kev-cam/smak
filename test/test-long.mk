# Test Makefile for monitoring with smak-attach

all: task1 task2 task3 task4 task5 task6

task1:
	@echo "Task 1 starting..."
	@sleep 3
	@echo "Task 1 done!"

task2:
	@echo "Task 2 starting..."
	@sleep 3
	@echo "Task 2 done!"

task3:
	@echo "Task 3 starting..."
	@sleep 3
	@echo "Task 3 done!"

task4:
	@echo "Task 4 starting..."
	@sleep 3
	@echo "Task 4 done!"

task5:
	@echo "Task 5 starting..."
	@sleep 3
	@echo "Task 5 done!"

task6:
	@echo "Task 6 starting..."
	@sleep 3
	@echo "Task 6 done!"

.PHONY: all task1 task2 task3 task4 task5 task6
