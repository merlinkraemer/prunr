# Makefile for Prunr - Terminal-based development workflow

SCHEME = Prunr
CONFIG = Debug
BUILD_DIR = $(PWD)/build
LOCAL_BUILD_ROOT = $(PWD)/.build
DERIVED_DATA = $(LOCAL_BUILD_ROOT)/derivedData
SOURCE_PACKAGES = $(LOCAL_BUILD_ROOT)/sourcePackages
APP_SUPPORT_DIR = $(HOME)/Library/Application Support/Prunr
BUNDLE_ID = com.prunr.app
XCODE_APP ?= /Applications/Xcode.app
XCODE_DEVELOPER_DIR ?= $(XCODE_APP)/Contents/Developer
XCODEBUILD = env DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" xcodebuild

# Colors for output
BLUE = \033[0;34m
GREEN = \033[0;32m
RED = \033[0;31m
YELLOW = \033[0;33m
NC = \033[0m # No Color

STRESS_ROOT ?= $(PWD)/tmp/stress-tree
STRESS_DATASET ?= $(STRESS_ROOT)/dataset
STRESS_RESULTS_ROOT ?= $(PWD)/tmp/stress-results
STRESS_DB_PATH ?= $(STRESS_RESULTS_ROOT)/state/prunr-stress.db
STRESS_RUNNER = $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(SCHEME).app/Contents/MacOS/$(SCHEME)
STRESS_EXPECT_UNCHANGED ?= 1
STRESS_FILES ?= 100000
STRESS_FILE_SIZE ?= 4096
STRESS_FANOUT ?= 250
STRESS_MUTATE_COUNT ?= 1000
STRESS_MUTATE_BYTES ?= 1048576

.PHONY: all build run dev launch clean clean-build reset-dev-state help doctor test open logs stress-create stress-stats stress-scan stress-repeat stress-report stress-mutate stress-clean

all: help

help:
	@echo "$(BLUE)Prunr - Terminal Development Commands$(NC)"
	@echo ""
	@echo "$(GREEN)make build$(NC)    - Build the app"
	@echo "$(GREEN)make run$(NC)      - Kill existing instance, build, and run"
	@echo "$(GREEN)make dev$(NC)      - Kill, reset app state, clean local build artifacts, rebuild, and run"
	@echo "$(GREEN)make clean$(NC)    - Clean build directory"
	@echo "$(GREEN)make doctor$(NC)   - Check local macOS/Xcode dev prerequisites"
	@echo "$(GREEN)make test$(NC)     - Run tests (if any)"
	@echo "$(GREEN)make stress-create$(NC) - Generate a synthetic scan tree"
	@echo "$(GREEN)make stress-stats$(NC)  - Inspect the synthetic scan tree"
	@echo "$(GREEN)make stress-scan$(NC)   - Run a baseline/full scan on the synthetic dataset"
	@echo "$(GREEN)make stress-repeat$(NC) - Run a repeat scan and compare against the previous snapshot"
	@echo "$(GREEN)make stress-report$(NC) - Summarize machine-readable stress scan results"
	@echo "$(GREEN)make stress-mutate$(NC) - Apply deterministic file mutations"
	@echo "$(GREEN)make stress-clean$(NC)  - Remove the synthetic scan tree"
	@echo "$(GREEN)make open$(NC)     - Open in Xcode"
	@echo "$(GREEN)make logs$(NC)     - Show recent app logs"
	@echo ""

build:
	@echo "$(BLUE)Building $(SCHEME) ($(CONFIG))...$(NC)"
	exec $(XCODEBUILD) build \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) \
		-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)
	@echo "$(GREEN)Build complete!$(NC)"

run: kill build launch

launch:
	@echo "$(BLUE)Launching $(SCHEME)...$(NC)"
	open $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(SCHEME).app

dev: kill reset-dev-state clean-build build launch

kill:
	@echo "$(YELLOW)Stopping any running $(SCHEME) instances...$(NC)"
	@pkill -x "$(SCHEME)" 2>/dev/null || true
	@sleep 0.5

clean:
	@echo "$(YELLOW)Cleaning build directory...$(NC)"
	exec $(XCODEBUILD) clean \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) \
		-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)
	rm -rf $(BUILD_DIR)
	rm -rf $(LOCAL_BUILD_ROOT)
	@echo "$(GREEN)Clean complete!$(NC)"

clean-build:
	@echo "$(YELLOW)Removing local build artifacts...$(NC)"
	rm -rf $(BUILD_DIR)
	@lsof +D "$(LOCAL_BUILD_ROOT)" 2>/dev/null | awk 'NR>1{print $$2}' | sort -u | xargs -r kill 2>/dev/null || true
	@sleep 0.5
	rm -rf $(LOCAL_BUILD_ROOT)
	@echo "$(GREEN)Local build artifacts removed!$(NC)"

reset-dev-state:
	@echo "$(YELLOW)Resetting local app state...$(NC)"
	rm -rf "$(APP_SUPPORT_DIR)"
	@defaults delete "$(BUNDLE_ID)" 2>/dev/null || true
	@echo "$(GREEN)Local app state reset!$(NC)"

doctor:
	@echo "$(BLUE)Checking Prunr macOS dev environment...$(NC)"
	@if [ ! -d "$(XCODE_APP)" ]; then \
		echo "$(RED)Missing $(XCODE_APP). Install Xcode from the App Store first.$(NC)"; \
		exit 1; \
	fi
	@echo "Xcode app: $(XCODE_APP)"
	@echo "Developer dir: $(XCODE_DEVELOPER_DIR)"
	@active_dir="$$(xcode-select -p 2>/dev/null || true)"; \
	if [ "$$active_dir" != "$(XCODE_DEVELOPER_DIR)" ]; then \
		echo "$(YELLOW)xcode-select is not pointing at Xcode.$(NC)"; \
		echo "  Run: sudo xcode-select -s $(XCODE_DEVELOPER_DIR)"; \
	else \
		echo "$(GREEN)xcode-select points at Xcode.$(NC)"; \
	fi
	@if ! $(XCODEBUILD) -version >/dev/null 2>&1; then \
		echo "$(YELLOW)xcodebuild is not ready yet.$(NC)"; \
		echo "  Likely fix: sudo xcodebuild -license"; \
		exit 1; \
	fi
	@echo "$(GREEN)xcodebuild is available.$(NC)"
	@if ! xcrun simctl list devices >/dev/null 2>&1; then \
		echo "$(YELLOW)simctl is not ready yet. Open Xcode once to finish first-run setup.$(NC)"; \
	else \
		echo "$(GREEN)simctl is available.$(NC)"; \
	fi

test:
	@echo "$(BLUE)Running tests...$(NC)"
	@output_file="$$(mktemp)"; \
	$(XCODEBUILD) test \
		-project $(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) \
		-clonedSourcePackagesDirPath $(SOURCE_PACKAGES) \
		> "$$output_file" 2>&1; \
	status=$$?; \
	cat "$$output_file"; \
	if grep -Eq "There are no test bundles available to test|No test bundles" "$$output_file"; then \
		echo "$(YELLOW)No app-owned XCTest bundles are configured yet$(NC)"; \
	elif [ $$status -ne 0 ]; then \
		rm -f "$$output_file"; \
		exit $$status; \
	fi; \
	rm -f "$$output_file"

stress-create:
	@echo "$(BLUE)Generating synthetic stress tree at $(STRESS_ROOT)...$(NC)"
	exec swift scripts/stress_tree.swift create \
		--root "$(STRESS_ROOT)" \
		--files $(STRESS_FILES) \
		--file-size $(STRESS_FILE_SIZE) \
		--fanout $(STRESS_FANOUT)

stress-stats:
	@echo "$(BLUE)Inspecting synthetic stress tree at $(STRESS_ROOT)...$(NC)"
	exec swift scripts/stress_tree.swift stats \
		--root "$(STRESS_ROOT)"

stress-scan:
	@echo "$(BLUE)Running baseline/full stress scan for $(STRESS_DATASET)...$(NC)"
	@label="$${STRESS_RUN_LABEL:-baseline}"; \
	exec "$(STRESS_RUNNER)" stress-scan \
		--mode baseline \
		--dataset "$(STRESS_DATASET)" \
		--results-dir "$(STRESS_RESULTS_ROOT)" \
		--db-path "$(STRESS_DB_PATH)" \
		--label "$$label" \
		--expect-unchanged false

stress-repeat:
	@echo "$(BLUE)Running repeat stress scan for $(STRESS_DATASET)...$(NC)"
	@label="$${STRESS_RUN_LABEL:-repeat}"; \
	exec "$(STRESS_RUNNER)" stress-scan \
		--mode repeat \
		--dataset "$(STRESS_DATASET)" \
		--results-dir "$(STRESS_RESULTS_ROOT)" \
		--db-path "$(STRESS_DB_PATH)" \
		--label "$$label" \
		--expect-unchanged "$(STRESS_EXPECT_UNCHANGED)"

stress-report:
	@echo "$(BLUE)Summarizing stress scan results under $(STRESS_RESULTS_ROOT)...$(NC)"
	exec "$(STRESS_RUNNER)" stress-report \
		--results-dir "$(STRESS_RESULTS_ROOT)" \
		--output "$(STRESS_RESULTS_ROOT)/report.json"

stress-mutate:
	@echo "$(BLUE)Applying deterministic mutations under $(STRESS_ROOT)...$(NC)"
	exec swift scripts/stress_tree.swift mutate \
		--root "$(STRESS_ROOT)" \
		--count $(STRESS_MUTATE_COUNT) \
		--bytes $(STRESS_MUTATE_BYTES)

stress-clean:
	@echo "$(YELLOW)Removing synthetic stress tree at $(STRESS_ROOT)...$(NC)"
	exec swift scripts/stress_tree.swift clean \
		--root "$(STRESS_ROOT)"

open:
	@echo "$(BLUE)Opening in Xcode...$(NC)"
	open $(SCHEME).xcodeproj

logs:
	@echo "$(BLUE)Recent logs for $(SCHEME):$(NC)"
	@log show --predicate 'subsystem == "com.apple.SwiftUI" OR process == "$(SCHEME)"' \
		--last 5m --style compact 2>/dev/null || echo "No recent logs found"
