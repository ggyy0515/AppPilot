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
  "$fixture/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes" \
  "$fixture/scripts/tests"
printf 'package main\n' >"$fixture/cli/cmd/ap-ios-debug/main.go"
printf 'module github.com/yangy003/ap-ios-debug-system/cli\n\ngo 1.26.2\n' >"$fixture/cli/go.mod"
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
printf 'AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug\n' >"$fixture/Makefile"
printf '# AppPilot\n' >"$fixture/README.md"
printf '%s\n' \
  'legacy_binary="$prefix/bin/ios-debug"' \
  'legacy_package="$prefix/share/ios-debug/IOSDebugKit"' \
  'legacy_skill="$codex_home/skills/sx-ios-debug"' >"$fixture/scripts/local-install.sh"
printf '#!/bin/bash\nset -euo pipefail\n' >"$fixture/scripts/tests/local-install-safety-test.sh"
git -C "$fixture" init -q
git -C "$fixture" add .
AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null

assert_rejected() {
  local label="$1"
  if AP_IOS_NAME_ROOT="$fixture" "$checker" >/dev/null 2>&1; then
    echo "FAIL: accepted $label" >&2
    exit 1
  fi
}

printf '%s\n' '// module github.com/yangy003/ap-ios-debug-system/cli' 'module example.invalid/wrong' 'go 1.26.2' >"$fixture/cli/go.mod"
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
