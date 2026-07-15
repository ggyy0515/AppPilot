#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
package="$root/swift/ap-ios-debug-kit"

test -f "$package/Package.swift"
test -d "$package/Sources/APIOSDebugCore"
test -d "$package/Sources/APIOSDebugKit"
test -f "$package/Templates/APIOSDebugBootstrap.swift"
grep -Fq 'name: "ap-ios-debug-kit"' "$package/Package.swift"
grep -Fq '.library(name: "APIOSDebugKit"' "$package/Package.swift"
grep -Fq 'public final class APIOSDebugRuntime' "$package/Sources/APIOSDebugKit/APIOSDebugRuntime.swift"
grep -Fq 'enum APIOSDebugBootstrap' "$package/Templates/APIOSDebugBootstrap.swift"
if rg --pcre2 '(?<!AP)IOSDebug' "$package"; then
  echo 'FAIL: legacy Swift identifier remains' >&2
  exit 1
fi
echo 'PASS: ap-ios-swift-names'
