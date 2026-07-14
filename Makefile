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
SHARE_ROOT := $(PREFIX)/share/ios-debug
PACKAGE_INSTALL := $(SHARE_ROOT)/IOSDebugKit
SKILL_INSTALL := $(CODEX_HOME)/skills/sx-ios-debug

.PHONY: build-cli scaffold-smoke demo-test demo-debug demo-release simulator-e2e release-scan device-smoke device-smoke-test validate-skill validate-skill-test check-docs local-install-safety-test install-local uninstall-local install-smoke-isolated clean

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

validate-skill:
	@./scripts/validate-skill.sh

validate-skill-test:
	@./scripts/tests/validate-skill-test.sh

check-docs:
	@./scripts/check-docs.sh

local-install-safety-test:
	@./scripts/tests/local-install-safety-test.sh

install-local: build-cli validate-skill
	@PREFIX="$(PREFIX)" CODEX_HOME="$(CODEX_HOME)" \
		IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" \
		PACKAGE_SOURCE="$(CURDIR)/swift/IOSDebugKit" \
		SKILL_SOURCE="$(CURDIR)/codex/skills/sx-ios-debug" \
		./scripts/local-install.sh install
	@PREFIX="$(PREFIX)" CODEX_HOME="$(CODEX_HOME)" ./scripts/install-smoke.sh

uninstall-local:
	@PREFIX="$(PREFIX)" CODEX_HOME="$(CODEX_HOME)" ./scripts/local-install.sh uninstall

install-smoke-isolated: local-install-safety-test
	@set -eu; \
	tmp="$$(mktemp -d /tmp/ios-debug-install-test.XXXXXX)"; \
	trap 'chmod -R u+w "$$tmp" 2>/dev/null || true; rm -rf -- "$$tmp"' EXIT; \
	gomodcache="$$(go env GOMODCACHE)"; \
	gocache="$$(go env GOCACHE)"; \
	mkdir -p "$$tmp/home/.local/bin" "$$tmp/home/.local/share" \
		"$$tmp/home/.codex/skills" "$$tmp/Project/.ios-debug/artifacts"; \
	printf 'unrelated-bin\n' >"$$tmp/home/.local/bin/unrelated"; \
	printf 'unrelated-share\n' >"$$tmp/home/.local/share/unrelated"; \
	printf 'unrelated-skill\n' >"$$tmp/home/.codex/skills/unrelated"; \
	printf 'user-data\n' >"$$tmp/Project/.ios-debug.toml"; \
	printf 'artifact\n' >"$$tmp/Project/.ios-debug/artifacts/keep.txt"; \
	HOME="$$tmp/home" GOMODCACHE="$$gomodcache" GOCACHE="$$gocache" $(MAKE) install-local \
		PREFIX="$$tmp/home/.local" CODEX_HOME="$$tmp/home/.codex"; \
	HOME="$$tmp/home" GOMODCACHE="$$gomodcache" GOCACHE="$$gocache" $(MAKE) uninstall-local \
		PREFIX="$$tmp/home/.local" CODEX_HOME="$$tmp/home/.codex"; \
	test ! -e "$$tmp/home/.local/bin/ios-debug"; \
	test ! -e "$$tmp/home/.local/share/ios-debug/IOSDebugKit"; \
	test ! -e "$$tmp/home/.codex/skills/sx-ios-debug"; \
	test -f "$$tmp/home/.local/bin/unrelated"; \
	test -f "$$tmp/home/.local/share/unrelated"; \
	test -f "$$tmp/home/.codex/skills/unrelated"; \
	test -f "$$tmp/Project/.ios-debug.toml"; \
	test -f "$$tmp/Project/.ios-debug/artifacts/keep.txt"; \
	echo "PASS: install-uninstall-isolated"

clean:
	@./scripts/clean-build.sh "$(CURDIR)" "$(BUILD_DIR)"
