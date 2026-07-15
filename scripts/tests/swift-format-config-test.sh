#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
config="$root/swift/ap-ios-debug-kit/.swift-format"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-swift-format.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

swift format dump-configuration >"$tmp/default.json"
swift format dump-configuration --effective --configuration "$config" >"$tmp/effective.json"

cp "$tmp/default.json" "$tmp/expected.json"
plutil -replace rules.OnlyOneTrailingClosureArgument -bool false "$tmp/expected.json"
plutil -replace rules.ReplaceForEachWithForLoop -bool false "$tmp/expected.json"
plutil -extract rules xml1 -o "$tmp/expected.plist" "$tmp/expected.json"
plutil -extract rules xml1 -o "$tmp/effective.plist" "$tmp/effective.json"
cmp "$tmp/expected.plist" "$tmp/effective.plist"

test "$(plutil -extract rules.DoNotUseSemicolons raw -o - "$tmp/effective.json")" = true
test "$(plutil -extract rules.AlwaysUseLowerCamelCase raw -o - "$tmp/effective.json")" = true

printf 'public let Bad_name = 1;\n' >"$tmp/Bad.swift"
if swift format lint --strict --configuration "$config" "$tmp/Bad.swift" >"$tmp/bad.out" 2>&1; then
  echo "FAIL: invalid Swift fixture unexpectedly passed strict lint" >&2
  exit 1
fi

echo "PASS: swift-format-config"
