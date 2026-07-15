#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
checker="$root/scripts/check-ap-ios-names.sh"
tmp="$(mktemp -d /tmp/ap-ios-name-test.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

if ! git -C "$root" check-ignore -q .ap-ios-debug/artifacts/test.png; then
  echo 'FAIL: canonical repository artifacts are not ignored' >&2
  exit 1
fi
if git -C "$root" check-ignore -q .ios-debug/artifacts/test.png; then
  echo 'FAIL: legacy repository artifacts remain actively ignored' >&2
  exit 1
fi

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

wire_header="$tmp/wire-header.txt"
printf '%s\n' 'keep headers beginning with x-ios-debug-protocol-version' >"$wire_header"
"$checker" --scan-only "$wire_header" >/dev/null
printf '%s\n' 'X-IOS-Debug-Protocol-Version' >"$wire_header"
"$checker" --scan-only "$wire_header" >/dev/null
printf '%s\n' 'x-ios-debug is not a complete frozen header name' >"$wire_header"
if "$checker" --scan-only "$wire_header" >/dev/null 2>&1; then
  echo 'FAIL: wire-protocol exception accepted a non-header legacy name' >&2
  exit 1
fi
uppercase_non_headers=(
  'X-IOS-Debug'
  'X-IOS-Debug-'
  'X-IOS-Debugger'
  'IOS-Debug'
  'X-Ios-Debug-Protocol-Version'
  'x-IOS-Debug-Protocol-Version'
  'AP-IOS-Debug'
)
for value in "${uppercase_non_headers[@]}"; do
  printf '%s\n' "$value" >"$wire_header"
  uppercase_status=0
  "$checker" --scan-only "$wire_header" >/dev/null 2>&1 || uppercase_status=$?
  if [[ "$uppercase_status" -eq 0 ]]; then
    echo "FAIL: wire-protocol exception accepted uppercase non-header $value" >&2
    exit 1
  fi
  if [[ "$uppercase_status" -ne 1 ]]; then
    echo "FAIL: uppercase non-header $value returned $uppercase_status, expected 1" >&2
    exit 1
  fi
done

canonical_prefix_case_variants=(
  'ap-IOS-Debug'
  'ap-Ios-Debug'
  'ap-iOS-debug'
  'ap-ios-Debug'
  'ap-ios-DEBUG'
)
for value in "${canonical_prefix_case_variants[@]}"; do
  printf '%s\n' "$value" >"$wire_header"
  variant_status=0
  "$checker" --scan-only "$wire_header" >/dev/null 2>&1 || variant_status=$?
  if [[ "$variant_status" -eq 0 ]]; then
    echo "FAIL: canonical prefix accepted noncanonical case $value" >&2
    exit 1
  fi
  if [[ "$variant_status" -ne 1 ]]; then
    echo "FAIL: noncanonical case $value returned $variant_status, expected 1" >&2
    exit 1
  fi
done

approved_external_tokens=(
  'ap-ios-debug'
  'ap-ios-debug-kit'
  'ap-ios-debug-demo'
  'ap-ios-debug-system'
  'ap-ios-debug-skill'
  'ap-ios-debug.local'
  '/tmp/ap-ios-debug/artifacts/test.png'
  'Use ap-ios-debug, then continue.'
  'github.com/yangy003/ap-ios-debug-system'
  'mktemp -d /tmp/ap-ios-debug-install-test.XXXXXX'
)
for value in "${approved_external_tokens[@]}"; do
  printf '%s\n' "$value" >"$wire_header"
  "$checker" --scan-only "$wire_header" >/dev/null
done

external_token_case_variants=(
  'ap-ios-debug-Kit'
  'ap-ios-debug-DEMO'
  'ap-ios-debug-System'
  'ap-ios-debug-Skill'
  'ap-ios-debug.Local'
  'ap-ios-debugX'
  'ap-ios-debug-install-test.XXXXXY'
)
for value in "${external_token_case_variants[@]}"; do
  printf '%s\n' "$value" >"$wire_header"
  token_status=0
  "$checker" --scan-only "$wire_header" >/dev/null 2>&1 || token_status=$?
  if [[ "$token_status" -eq 0 ]]; then
    echo "FAIL: external token accepted invalid canonical spelling $value" >&2
    exit 1
  fi
  if [[ "$token_status" -ne 1 ]]; then
    echo "FAIL: invalid external token $value returned $token_status, expected 1" >&2
    exit 1
  fi
done

cli_plan="$root/docs/superpowers/plans/2026-07-13-ap-ios-debug-cli.md"
if rg -q 'x-''ap-ios-debug-' "$cli_plan"; then
  echo 'FAIL: CLI plan renamed a frozen wire header prefix' >&2
  exit 1
fi
if ! rg -q 'not beginning `content-` or `x-ios-debug-`' "$cli_plan"; then
  echo 'FAIL: CLI plan is missing the frozen lowercase wire header prefix' >&2
  exit 1
fi

fixture="$tmp/repo"
mkdir -p \
  "$fixture/cli/cmd/ap-ios-debug" \
  "$fixture/swift/ap-ios-debug-kit" \
  "$fixture/codex/skills/ap-ios-debug-skill" \
  "$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes" \
  "$fixture/scripts/tests"
printf 'package main\n' >"$fixture/cli/cmd/ap-ios-debug/main.go"
printf 'module github.com/yangy003/ap-ios-debug-system\n\ngo 1.26.2\n' >"$fixture/cli/go.mod"
printf '%s\n' \
  '// swift-tools-version: 6.0' \
  'import PackageDescription' \
  'let package = Package(' \
  '  name: "ap-ios-debug-kit",' \
  '  products: [' \
  '    .library(name: "APIOSDebugCore", targets: ["APIOSDebugCore"]),' \
  '    .library(name: "APIOSDebugKit", targets: ["APIOSDebugKit"]),' \
  '  ],' \
  '  targets: [' \
  '    .target(name: "APIOSDebugCore"),' \
  '    .target(name: "APIOSDebugKit"),' \
  '  ]' \
  ')' >"$fixture/swift/ap-ios-debug-kit/Package.swift"
printf '%s\n' '---' 'name: ap-ios-debug-skill' '---' >"$fixture/codex/skills/ap-ios-debug-skill/SKILL.md"
printf '%s\n' \
  'PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo;' \
  'PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo.tests;' \
  >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<Scheme version="1.7"><LaunchAction buildConfiguration="Debug"><BuildableProductRunnable><BuildableReference BlueprintName="APIOSDebugDemo" ReferencedContainer="container:ap-ios-debug-demo.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>' \
  >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<Scheme version="1.7"><LaunchAction buildConfiguration="Release"><BuildableProductRunnable><BuildableReference BlueprintName="APIOSDebugDemoRelease" ReferencedContainer="container:ap-ios-debug-demo.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>' \
  >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme"
printf '%s\n' \
  'BUILD_DIR := $(CURDIR)/build' \
  'AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug' \
  '.PHONY: print-ap-ios-debug-bin' \
  'print-ap-ios-debug-bin:' \
  $'\t@echo "$(AP_IOS_DEBUG_BIN)"' >"$fixture/Makefile"
printf '# AppPilot\n' >"$fixture/README.md"
printf '%s\n' \
  'legacy_binary="$prefix/bin/ios-debug"' \
  'legacy_package="$prefix/share/ios-debug/IOSDebugKit"' \
  'legacy_skill="$codex_home/skills/sx-ios-debug"' >"$fixture/scripts/local-install.sh"
printf '#!/bin/bash\nset -euo pipefail\n' >"$fixture/scripts/tests/local-install-safety-test.sh"
git -C "$fixture" init -q
git -C "$fixture" add .
AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null

fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
real_git="$(command -v git)"
printf '%s\n' '#!/bin/bash' \
  'if [[ "${1:-}" = ls-files ]]; then exit 7; fi' \
  'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
chmod 0755 "$fake_bin/git"
if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null 2>&1; then
  echo 'FAIL: git ls-files failure was accepted' >&2
  exit 1
fi

assert_rejected() {
  local label="$1"
  if AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null 2>&1; then
    echo "FAIL: accepted $label" >&2
    exit 1
  fi
}

printf '%s\n' '// module github.com/yangy003/ap-ios-debug-system' 'module example.invalid/wrong' 'go 1.26.2' >"$fixture/cli/go.mod"
assert_rejected 'wrong Go module hidden by a comment'
git -C "$fixture" checkout -- cli/go.mod

perl -0pi -e 's/name: "ap-ios-debug-kit",/name: "wrong-package",\n  \/\/ name: "ap-ios-debug-kit",/' "$fixture/swift/ap-ios-debug-kit/Package.swift"
assert_rejected 'wrong Swift package name hidden by a comment'
git -C "$fixture" checkout -- swift/ap-ios-debug-kit/Package.swift

perl -0pi -e 's/\.library\(name: "APIOSDebugCore", targets: \["APIOSDebugCore"\]\),/.library(name: "WrongCore", targets: ["APIOSDebugCore"]),\/\/ .library(name: "APIOSDebugCore", targets: ["APIOSDebugCore"]),/' "$fixture/swift/ap-ios-debug-kit/Package.swift"
assert_rejected 'wrong Swift products hidden by a comment'
git -C "$fixture" checkout -- swift/ap-ios-debug-kit/Package.swift

printf '%s\n' '---' 'name: wrong-skill' '---' '# name: ap-ios-debug-skill' >"$fixture/codex/skills/ap-ios-debug-skill/SKILL.md"
assert_rejected 'wrong skill frontmatter hidden by body text'
git -C "$fixture" checkout -- codex/skills/ap-ios-debug-skill/SKILL.md

printf '%s\n' '// PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo;' 'PRODUCT_BUNDLE_IDENTIFIER = example.invalid.wrong;' 'PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo.tests;' >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj"
assert_rejected 'wrong bundle identifier hidden by a comment'
git -C "$fixture" checkout -- Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Scheme version="1.7"><LaunchAction buildConfiguration="Release"><BuildableProductRunnable><BuildableReference BlueprintName="WrongDemo" ReferencedContainer="container:wrong.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>' >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme"
assert_rejected 'wrong Debug scheme metadata'
git -C "$fixture" checkout -- Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Scheme version="1.7"><LaunchAction buildConfiguration="Debug"><BuildableProductRunnable><BuildableReference BlueprintName="WrongRelease" ReferencedContainer="container:wrong.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>' >"$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme"
assert_rejected 'wrong Release scheme metadata'
git -C "$fixture" checkout -- Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme

printf '%s\n' '# AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug' 'AP_IOS_DEBUG_BIN := wrong' >"$fixture/Makefile"
assert_rejected 'wrong Make assignment hidden by a comment'
git -C "$fixture" checkout -- Makefile

printf 'AP_IOS_DEBUG_BIN = /tmp/wrong\n' >>"$fixture/Makefile"
assert_rejected 'later Make assignment overriding the canonical value'
git -C "$fixture" checkout -- Makefile

printf '%s\n' \
  '# AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug' \
  'AP_IOS_DEBUG_BIN ?= $(BUILD_DIR)/ap-ios-debug' \
  'AP_IOS_DEBUG_BIN = /tmp/wrong' \
  '.PHONY: print-ap-ios-debug-bin' \
  'print-ap-ios-debug-bin:' \
  $'\t@echo "$(AP_IOS_DEBUG_BIN)"' >"$fixture/Makefile"
assert_rejected 'wrong effective Make value hidden by comment and another operator'
git -C "$fixture" checkout -- Makefile

printf '%s\n' 'body text' '# Wrong' '# AppPilot' >"$fixture/README.md"
assert_rejected 'wrong first README heading'
git -C "$fixture" checkout -- README.md

rm "$fixture/scripts/local-install.sh"
assert_rejected 'missing installer'
git -C "$fixture" checkout -- scripts/local-install.sh

printf '%s\n' 'legacy_binary="$prefix/bin/ios-debug"' 'legacy_package="$prefix/share/ios-debug/IOSDebugKit"' >"$fixture/scripts/local-install.sh"
assert_rejected 'installer missing an exact cleanup mapping'
git -C "$fixture" checkout -- scripts/local-install.sh

printf 'echo ios-debug\n' >>"$fixture/scripts/local-install.sh"
assert_rejected 'extra installer legacy leakage'
git -C "$fixture" checkout -- scripts/local-install.sh

printf 'echo ios-debug\n' >>"$fixture/scripts/tests/local-install-safety-test.sh"
assert_rejected 'extra local-install safety fixture legacy leakage'
git -C "$fixture" checkout -- scripts/tests/local-install-safety-test.sh

mkdir -p "$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests"
printf 'canonical content\n' >"$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests/IOSDebugKitTargetTests.swift"
git -C "$fixture" add .
assert_rejected 'tracked path with a legacy name'
rm "$fixture/swift/ap-ios-debug-kit/Tests/APIOSDebugKitTests/IOSDebugKitTargetTests.swift"
git -C "$fixture" add -u

rm "$fixture/codex/skills/ap-ios-debug-skill/SKILL.md"
assert_rejected 'missing canonical skill'

echo 'PASS: ap-ios-name-contract-fixtures'
