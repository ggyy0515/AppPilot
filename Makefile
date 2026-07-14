SHELL := /bin/bash
.DEFAULT_GOAL := verify

VERSION ?= dev
GO ?= go
SWIFT ?= swift
XCODEBUILD ?= xcodebuild
PREFIX ?= $(HOME)/.local
CODEX_HOME ?= $(HOME)/.codex
override BUILD_DIR := $(CURDIR)/build
IOS_DEBUG_BIN := $(BUILD_DIR)/ios-debug
DERIVED_DATA ?= $(BUILD_DIR)/DerivedData
DEMO_PROJECT := Examples/DebugDemo/DebugDemo.xcodeproj
DEMO_SCHEME := DebugDemo
DEMO_RELEASE_SCHEME := DebugDemo-Release

.PHONY: build-cli scaffold-smoke demo-test demo-debug demo-release simulator-e2e release-scan device-smoke device-smoke-test clean

build-cli:
	@mkdir -p "$(BUILD_DIR)"
	@cd cli && $(GO) build -trimpath \
		-ldflags '-X github.com/yangy003/ios-debug-system/cli/internal/buildinfo.Version=$(VERSION)' \
		-o "$(IOS_DEBUG_BIN)" ./cmd/ios-debug

scaffold-smoke: build-cli
	@IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" ./scripts/scaffold-smoke.sh

demo-test:
	@$(XCODEBUILD) -project "$(DEMO_PROJECT)" -scheme "$(DEMO_SCHEME)" \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		-derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO test

demo-debug:
	@$(XCODEBUILD) -project "$(DEMO_PROJECT)" -scheme "$(DEMO_SCHEME)" \
		-configuration Debug -sdk iphonesimulator \
		-derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

demo-release:
	@$(XCODEBUILD) -project "$(DEMO_PROJECT)" -scheme "$(DEMO_RELEASE_SCHEME)" \
		-configuration Release -sdk iphonesimulator \
		-derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

simulator-e2e: build-cli
	@IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-simulator-e2e" \
		./scripts/simulator-e2e.sh

release-scan: build-cli
	@IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-release-scan" \
		./scripts/release-scan.sh

device-smoke: build-cli
	@IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-device-smoke" \
		./scripts/device-smoke.sh

device-smoke-test:
	@./scripts/tests/device-smoke-test.sh

clean:
	@./scripts/clean-build.sh "$(CURDIR)" "$(BUILD_DIR)"
