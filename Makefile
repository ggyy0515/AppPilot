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

.PHONY: build-cli scaffold-smoke clean

build-cli:
	@mkdir -p "$(BUILD_DIR)"
	@cd cli && $(GO) build -trimpath \
		-ldflags '-X github.com/yangy003/ios-debug-system/cli/internal/buildinfo.Version=$(VERSION)' \
		-o "$(IOS_DEBUG_BIN)" ./cmd/ios-debug

scaffold-smoke: build-cli
	@IOS_DEBUG_BIN="$(IOS_DEBUG_BIN)" ./scripts/scaffold-smoke.sh

clean:
	@./scripts/clean-build.sh "$(CURDIR)" "$(BUILD_DIR)"
