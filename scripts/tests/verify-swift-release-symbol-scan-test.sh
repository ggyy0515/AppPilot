#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../verify-swift-release.sh
source "$root/scripts/verify-swift-release.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-symbol-scan-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

expect_rejected() {
  local fixture="$1"
  if verify_release_symbols "$fixture" >/dev/null 2>&1; then
    echo "Expected forbidden Release symbol fixture to be rejected: $fixture" >&2
    exit 1
  fi
}

expect_accepted() {
  local fixture="$1"
  if ! verify_release_symbols "$fixture"; then
    echo "Expected clean Release symbol fixture to be accepted: $fixture" >&2
    exit 1
  fi
}

printf '%s\n' '0000000000000000 T _IOSDebugRuntime_forbidden' '0000000000000010 T _clean' > "$work/small-leak.symbols"
expect_rejected "$work/small-leak.symbols"

printf '%s\n' '0000000000000000 T _$s11IOSDebugKit19DebugActionRegistryC6sharedACvgZ' > "$work/large-leak.symbols"
awk 'BEGIN { for (i = 0; i < 200000; i++) print "0000000000000010 T _clean_" i }' >> "$work/large-leak.symbols"
expect_rejected "$work/large-leak.symbols"

printf '%s\n' \
  '/tmp/IOSDebugRuntime.o:' \
  '/tmp/DebugActionRegistry.o:' \
  '/tmp/ScreenshotCapture.o:' \
  '/tmp/RecordingController.o:' \
  '/tmp/iosDebugAction.o:' \
  '0000000000000010 T _clean' > "$work/headings-only.symbols"
expect_accepted "$work/headings-only.symbols"

printf '%s\n' '0000000000000010 T _clean' '                 U _$s10Foundation4DataV' > "$work/clean.symbols"
expect_accepted "$work/clean.symbols"

echo "Swift Release symbol scan fixtures passed."
