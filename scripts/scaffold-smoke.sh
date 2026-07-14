#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
binary="${IOS_DEBUG_BIN:-$root/build/ios-debug}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-scaffold.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
project="$tmp/Project"
smoke_home="$tmp/home"
mkdir -p "$project" "$smoke_home"
project="$(cd "$project" && pwd -P)"

show_capture() {
  local output="$1"
  local errors="$output.stderr"
  if [ -s "$output" ]; then
    echo "--- captured JSON/stdout ---" >&2
    cat "$output" >&2
  fi
  if [ -s "$errors" ]; then
    echo "--- captured stderr ---" >&2
    cat "$errors" >&2
  fi
}

run_or_die() {
  local output="$1"
  shift
  local status
  set +e
  env -u IOS_DEBUG_TOKEN HOME="$smoke_home" "$@" >"$output" 2>"$output.stderr"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "FAIL: command exited $status: $*" >&2
    show_capture "$output"
    return "$status"
  fi
}

run_expect_status() {
  local expected="$1"
  local output="$2"
  shift 2
  local status
  set +e
  env -u IOS_DEBUG_TOKEN HOME="$smoke_home" "$@" >"$output" 2>"$output.stderr"
  status=$?
  set -e
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: expected exit $expected, got $status: $*" >&2
    show_capture "$output"
    return 1
  fi
}

test -x "$binary" || { echo "FAIL: missing $binary" >&2; exit 1; }

run_or_die "$tmp/dry.json" "$binary" --json app scaffold --into "$project" --dry-run
test ! -e "$project/.ios-debug.toml"
grep -q '"dry_run":true' "$tmp/dry.json"
grep -q '"status":"create"' "$tmp/dry.json"

run_or_die "$tmp/apply.json" "$binary" --json app scaffold --into "$project"
cmp "$root/tests/fixtures/scaffold/.ios-debug.toml" "$project/.ios-debug.toml"
cmp "$root/swift/IOSDebugKit/Templates/IOSDebugBootstrap.swift" \
    "$project/DebugTools/IOSDebugBootstrap.swift"
diff -qr --exclude .build --exclude .swiftpm \
    "$root/swift/IOSDebugKit" "$project/DebugTools/IOSDebugKit"

run_or_die "$tmp/again.json" "$binary" --json app scaffold --into "$project"
grep -q '"status":"unchanged"' "$tmp/again.json"

sed "s|$project|<PROJECT_ROOT>|g" "$tmp/apply.json" >"$tmp/normalized.json"
while IFS= read -r line; do grep -Fq "$line" "$tmp/normalized.json"; done \
    <"$root/tests/fixtures/scaffold/xcode-steps.txt"

printf '\nconflict = true\n' >>"$project/.ios-debug.toml"
before="$(shasum -a 256 "$project/.ios-debug.toml" | awk '{print $1}')"
run_expect_status 2 "$tmp/conflict.json" "$binary" --json app scaffold --into "$project"
grep -q '"code":"config_invalid"' "$tmp/conflict.json"
test "$before" = "$(shasum -a 256 "$project/.ios-debug.toml" | awk '{print $1}')"
echo "PASS: scaffold-smoke"
