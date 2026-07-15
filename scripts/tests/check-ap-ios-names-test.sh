#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
checker="$root/scripts/check-ap-ios-names.sh"
tmp="$(mktemp -d /tmp/ap-ios-name-test.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

good="$tmp/good.txt"
printf '%s\n' 'ap-ios-debug APIOSDebugKit AP_IOS_DEBUG_TOKEN .ap-ios-debug' >"$good"
"$checker" --scan-only "$good" >/dev/null

legacy_values=(ios-debug IOSDebugKit IOS_DEBUG_TOKEN .ios-debug DebugDemo sx-ios-debug)
for value in "${legacy_values[@]}"; do
  bad="$tmp/bad.txt"
  printf '%s\n' "$value" >"$bad"
  if "$checker" --scan-only "$bad" >/dev/null 2>&1; then
    echo "FAIL: accepted legacy value $value" >&2
    exit 1
  fi
done

fixture="$tmp/repo"
mkdir -p \
  "$fixture/cli/cmd/ap-ios-debug" \
  "$fixture/swift/ap-ios-debug-kit" \
  "$fixture/codex/skills/ap-ios-debug-skill" \
  "$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes"
printf 'package main\n' >"$fixture/cli/cmd/ap-ios-debug/main.go"
printf 'module github.com/yangy003/ap-ios-debug-system\n' >"$fixture/cli/go.mod"
printf '%s\n' \
  'name: "ap-ios-debug-kit"' \
  '.library(name: "APIOSDebugCore"' \
  '.library(name: "APIOSDebugKit"' >"$fixture/swift/ap-ios-debug-kit/Package.swift"
printf '%s\n' '---' 'name: ap-ios-debug-skill' '---' >"$fixture/codex/skills/ap-ios-debug-skill/SKILL.md"
printf 'PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo;\n' \
  >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj"
touch \
  "$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme" \
  "$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme"
printf 'AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug\n' >"$fixture/Makefile"
printf '# AppPilot\n' >"$fixture/README.md"
git -C "$fixture" init -q
git -C "$fixture" add .
AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null

mkdir -p "$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests"
printf 'canonical content\n' >"$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests/IOSDebugKitTargetTests.swift"
git -C "$fixture" add .
if AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null 2>&1; then
  echo 'FAIL: accepted tracked path with a legacy name' >&2
  exit 1
fi
rm "$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests/IOSDebugKitTargetTests.swift"
git -C "$fixture" add -u

rm "$fixture/codex/skills/ap-ios-debug-skill/SKILL.md"
if AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null 2>&1; then
  echo 'FAIL: missing canonical skill was accepted' >&2
  exit 1
fi

echo 'PASS: ap-ios-name-contract-fixtures'
