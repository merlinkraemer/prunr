# Makefile for Prunr - Terminal-based development workflow

SCHEME = Prunr
CONFIG = Debug
BUILD_DIR = $(PWD)/build
DERIVED_DATA = $(PWD)/.build/derivedData

# Colors for output
BLUE = \033[0;34m
GREEN = \033[0;32m
RED = \033[0;31m
YELLOW = \033[0;33m
NC = \033[0m # No Color

.PHONY: all build run dev clean help test open logs

all: help

help:
	@echo "$(BLUE)Prunr - Terminal Development Commands$(NC)"
	@echo ""
	@echo "$(GREEN)make build$(NC)    - Build the app"
	@echo "$(GREEN)make run$(NC)      - Kill existing instance, build, and run"
	@echo "$(GREEN)make dev$(NC)      - Alias for 'make run'"
	@echo "$(GREEN)make clean$(NC)    - Clean build directory"
	@echo "$(GREEN)make test$(NC)     - Run tests (if any)"
	@echo "$(GREEN)make open$(NC)     - Open in Xcode"
	@echo "$(GREEN)make logs$(NC)     - Show recent app logs"
	@echo ""

build:
	@echo "$(BLUE)Building $(SCHEME) ($(CONFIG))...$(NC)"
	xcodebuild build \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) \
		| grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" || true
	@echo "$(GREEN)Build complete!$(NC)"

run: kill build
	@echo "$(BLUE)Launching $(SCHEME)...$(NC)"
	open $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(SCHEME).app

dev: run

kill:
	@echo "$(YELLOW)Stopping any running $(SCHEME) instances...$(NC)"
	@pkill -x "$(SCHEME)" 2>/dev/null || true
	@sleep 0.5

clean:
	@echo "$(YELLOW)Cleaning build directory...$(NC)"
	xcodebuild clean \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA)
	rm -rf $(BUILD_DIR)
	rm -rf $(DERIVED_DATA)
	@echo "$(GREEN)Clean complete!$(NC)"

test:
	@echo "$(BLUE)Running tests...$(NC)"
	@if xcodebuild test \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) 2>&1 | grep -q "No test bundles"; then \
		echo "$(YELLOW)No tests found in the project$(NC)"; \
	else \
		xcodebuild test \
			-project $(SCHEME).xcodeproj \
			-scheme $(SCHEME) \
			-configuration $(CONFIG) \
			-derivedDataPath $(DERIVED_DATA); \
	fi

open:
	@echo "$(BLUE)Opening in Xcode...$(NC)"
	open $(SCHEME).xcodeproj

logs:
	@echo "$(BLUE)Recent logs for $(SCHEME):$(NC)"
	@log show --predicate 'subsystem == "com.apple.SwiftUI" OR process == "$(SCHEME)"' \
		--last 5m --style compact 2>/dev/null || echo "No recent logs found"
