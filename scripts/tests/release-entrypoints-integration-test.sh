#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-release-entrypoints.XXXXXX")"
trap 'rm -rf "$work"' EXIT

AP_IOS_DEBUG_RELEASE_SCAN_LIBRARY_ONLY=1
# shellcheck source=../release-scan.sh
source "$root/scripts/release-scan.sh"

schemes="$("$XCODEBUILD_BIN" -list -project "$root/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj" 2>"$work/xcode-list.stderr" | \
  awk '/^[[:space:]]*Schemes:/{inside=1; next} inside && NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')"
grep -Fxq 'ap-ios-debug-demo' <<<"$schemes"
grep -Fxq 'ap-ios-debug-demo-release' <<<"$schemes"
if grep -Fxq 'APIOSDebugDemoRelease' <<<"$schemes"; then
  echo 'unsafe auto-created APIOSDebugDemoRelease scheme is visible' >&2
  exit 1
fi

release_derived="$work/make demo release"
"$MAKE_BIN" -C "$root" demo-release XCODEBUILD="$XCODEBUILD_BIN" DERIVED_DATA="$release_derived" >"$work/make-demo-release.log" 2>&1
release_app="$release_derived/Build/Products/Release-iphonesimulator/APIOSDebugDemoRelease.app"
test -x "$release_app/APIOSDebugDemoRelease"
scan_artifacts negative "$release_app" \
  "$release_derived/Build/Intermediates.noindex/APIOSDebugDemoRelease.build" \
  "$work/release-scan"

# The dependency-free target's Debug configuration must remain buildable, but
# explicitly clears DEBUG so the shared sources do not import APIOSDebugKit.
debug_derived="$work/release target debug"
"$XCODEBUILD_BIN" -project "$root/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj" \
  -scheme ap-ios-debug-demo-release -configuration Debug -sdk iphonesimulator \
  -derivedDataPath "$debug_derived" CODE_SIGNING_ALLOWED=NO build \
  >"$work/release-target-debug.log" 2>&1
debug_app="$debug_derived/Build/Products/Debug-iphonesimulator/APIOSDebugDemoRelease.app"
test -x "$debug_app/APIOSDebugDemoRelease"
scan_artifacts negative "$debug_app" \
  "$debug_derived/Build/Intermediates.noindex/APIOSDebugDemoRelease.build" \
  "$work/debug-scan"

archive_derived="$work/archive derived data"
archive_path="$work/Debug Demo.xcarchive"
"$XCODEBUILD_BIN" -project "$root/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj" \
  -scheme ap-ios-debug-demo -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" -derivedDataPath "$archive_derived" \
  CODE_SIGNING_ALLOWED=NO archive >"$work/archive.log" 2>&1
archive_app="$archive_path/Products/Applications/APIOSDebugDemoRelease.app"
test -x "$archive_app/APIOSDebugDemoRelease"
archive_objects="$(/usr/bin/find "$archive_derived" -type d -name 'APIOSDebugDemoRelease.build' -print -quit)"
test -n "$archive_objects"
scan_artifacts negative "$archive_app" "$archive_objects" "$work/archive-scan"

echo "PASS: release-entrypoints-integration-test"
