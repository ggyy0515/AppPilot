SHELL := /bin/bash
.DEFAULT_GOAL := verify

VERSION ?= dev
GO ?= go
SWIFT ?= swift
XCODEBUILD ?= xcodebuild
PREFIX ?= $(HOME)/.local
CODEX_HOME ?= $(HOME)/.codex
override BUILD_DIR := $(CURDIR)/build
AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug
DERIVED_DATA ?= $(BUILD_DIR)/DerivedData
DEMO_PROJECT := Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj
DEMO_SCHEME := ap-ios-debug-demo
DEMO_RELEASE_SCHEME := ap-ios-debug-demo-release
SHARE_ROOT := $(PREFIX)/share/ap-ios-debug
PACKAGE_INSTALL := $(SHARE_ROOT)/ap-ios-debug-kit
SKILL_INSTALL := $(CODEX_HOME)/skills/ap-ios-debug-skill

.PHONY: print-ap-ios-debug-bin check-ap-ios-names check-ap-ios-names-test swift-format-config-test fmt-check go-vet go-test swift-test build-cli scaffold-smoke demo-test demo-debug demo-release simulator-e2e release-scan device-smoke device-smoke-test validate-skill validate-skill-test check-docs local-install-safety-test install-local uninstall-local install-smoke-isolated verify verify-device clean

print-ap-ios-debug-bin:
	@printf '%s\n' "$(AP_IOS_DEBUG_BIN)"

check-ap-ios-names:
	@./scripts/check-ap-ios-names.sh

check-ap-ios-names-test:
	@./scripts/tests/check-ap-ios-names-test.sh

swift-format-config-test:
	@./scripts/tests/swift-format-config-test.sh

fmt-check: swift-format-config-test
	@test -z "$$(gofmt -l cli)" || { gofmt -l cli; exit 1; }
	@cd swift/ap-ios-debug-kit && $(SWIFT) format lint --recursive --strict \
		--configuration .swift-format Package.swift Sources Tests

go-vet:
	@cd cli && $(GO) vet ./...

go-test:
	@cd cli && $(GO) test ./...

swift-test:
	@$(SWIFT) test --package-path swift/ap-ios-debug-kit

build-cli:
	@mkdir -p "$(BUILD_DIR)"
	@cd cli && $(GO) build -trimpath \
		-ldflags '-X github.com/yangy003/ap-ios-debug-system/internal/buildinfo.Version=$(VERSION)' \
		-o "$(AP_IOS_DEBUG_BIN)" ./cmd/ap-ios-debug

scaffold-smoke: build-cli
	@AP_IOS_DEBUG_BIN="$(AP_IOS_DEBUG_BIN)" ./scripts/scaffold-smoke.sh

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
	@AP_IOS_DEBUG_BIN="$(AP_IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-simulator-e2e" \
		./scripts/simulator-e2e.sh

release-scan: build-cli
	@AP_IOS_DEBUG_BIN="$(AP_IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-release-scan" \
		./scripts/release-scan.sh

device-smoke: build-cli
	@AP_IOS_DEBUG_BIN="$(AP_IOS_DEBUG_BIN)" DERIVED_DATA="$(BUILD_DIR)/DerivedData-device-smoke" \
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
		AP_IOS_DEBUG_BIN="$(AP_IOS_DEBUG_BIN)" \
		PACKAGE_SOURCE="$(CURDIR)/swift/ap-ios-debug-kit" \
		SKILL_SOURCE="$(CURDIR)/codex/skills/ap-ios-debug-skill" \
		./scripts/local-install.sh install
	@PREFIX="$(PREFIX)" CODEX_HOME="$(CODEX_HOME)" ./scripts/install-smoke.sh

uninstall-local:
	@PREFIX="$(PREFIX)" CODEX_HOME="$(CODEX_HOME)" ./scripts/local-install.sh uninstall

install-smoke-isolated: local-install-safety-test
	@set -eu; \
	tmp="$$(mktemp -d /tmp/ap-ios-debug-install-test.XXXXXX)"; \
	trap 'chmod -R u+w "$$tmp" 2>/dev/null || true; rm -rf -- "$$tmp"' EXIT; \
	gomodcache="$$(go env GOMODCACHE)"; \
	gocache="$$(go env GOCACHE)"; \
	mkdir -p "$$tmp/home/.local/bin" "$$tmp/home/.local/share" "$$tmp/home/.codex/skills" \
		"$$tmp/Project/.ap-ios-debug/artifacts"; \
	printf 'unrelated-bin\n' >"$$tmp/home/.local/bin/unrelated"; \
	printf 'unrelated-share\n' >"$$tmp/home/.local/share/unrelated"; \
	printf 'unrelated-skill\n' >"$$tmp/home/.codex/skills/unrelated"; \
	printf 'user-data\n' >"$$tmp/Project/.ap-ios-debug.toml"; \
	printf 'artifact\n' >"$$tmp/Project/.ap-ios-debug/artifacts/keep.txt"; \
	HOME="$$tmp/home" GOMODCACHE="$$gomodcache" GOCACHE="$$gocache" $(MAKE) install-local \
		PREFIX="$$tmp/home/.local" CODEX_HOME="$$tmp/home/.codex"; \
	HOME="$$tmp/home" GOMODCACHE="$$gomodcache" GOCACHE="$$gocache" $(MAKE) uninstall-local \
		PREFIX="$$tmp/home/.local" CODEX_HOME="$$tmp/home/.codex"; \
	test ! -e "$$tmp/home/.local/bin/ap-ios-debug"; \
	test ! -e "$$tmp/home/.local/share/ap-ios-debug/ap-ios-debug-kit"; \
	test ! -e "$$tmp/home/.codex/skills/ap-ios-debug-skill"; \
	test -f "$$tmp/home/.local/bin/unrelated"; \
	test -f "$$tmp/home/.local/share/unrelated"; \
	test -f "$$tmp/home/.codex/skills/unrelated"; \
	test -f "$$tmp/Project/.ap-ios-debug.toml"; \
	test -f "$$tmp/Project/.ap-ios-debug/artifacts/keep.txt"; \
	echo "PASS: install-uninstall-isolated"

verify: check-ap-ios-names check-ap-ios-names-test fmt-check go-vet go-test swift-test build-cli scaffold-smoke \
	demo-test demo-debug demo-release simulator-e2e release-scan \
	validate-skill check-docs install-smoke-isolated device-smoke
	@echo "PASS: make verify"

verify-device: verify
	@AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1 ./scripts/device-smoke.sh

clean:
	@./scripts/clean-build.sh "$(CURDIR)" "$(BUILD_DIR)"
	@$(SWIFT) package --package-path swift/ap-ios-debug-kit reset
	@rm -rf -- "$(CURDIR)/swift/ap-ios-debug-kit/.swiftpm"
