#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=secret-scan.sh
source "$root/scripts/secret-scan.sh"
binary="${IOS_DEBUG_BIN:-$root/build/ios-debug}"
derived="${DERIVED_DATA:-$root/build/DerivedData-simulator-e2e}"
bundle_id="com.openai.iosdebug.DebugDemo"
scheme="${IOS_DEBUG_E2E_SCHEME:-DebugDemo}"
app_port=9876
port="${IOS_DEBUG_E2E_PORT:-$app_port}"
token="${IOS_DEBUG_E2E_TOKEN:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
wrong_token="${IOS_DEBUG_E2E_WRONG_TOKEN:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-simulator.XXXXXX")"
udid=""
failure_stage="initialize simulator E2E"
failure_capture=""

redact_stream() {
  IOS_DEBUG_REDACT_TOKEN="$token" IOS_DEBUG_REDACT_WRONG_TOKEN="$wrong_token" perl -pe '
    for my $secret ($ENV{IOS_DEBUG_REDACT_TOKEN}, $ENV{IOS_DEBUG_REDACT_WRONG_TOKEN}) {
      s/\Q$secret\E/<redacted>/g if defined($secret) && length($secret);
    }
    s/(Authorization\s*:\s*Bearer\s+)\S+/${1}<redacted>/ig;
    s/(Bearer\s+)\S+/${1}<redacted>/ig;
    s/(IOS_DEBUG_TOKEN\s*[=:]\s*)\S+/${1}<redacted>/ig;
  '
}

show_capture() {
  local output="$1"
  if [ -s "$output" ]; then
    echo "--- captured stdout/log (last 200 lines) ---" >&2
    tail -n 200 "$output" | redact_stream >&2
  fi
  if [ -s "$output.stderr" ]; then
    echo "--- captured stderr (last 200 lines) ---" >&2
    tail -n 200 "$output.stderr" | redact_stream >&2
  fi
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $failure_stage" >&2
    if [ -n "$failure_capture" ]; then
      show_capture "$failure_capture"
    fi
  fi
  if [ -n "$udid" ]; then
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

run_or_die() {
  local stage="$1"
  local output="$2"
  shift 2
  failure_stage="$stage"
  failure_capture="$output"
  local status
  set +e
  "$@" >"$output" 2>"$output.stderr"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

run_expect_status() {
  local expected="$1"
  local stage="$2"
  local output="$3"
  shift 3
  failure_stage="$stage"
  failure_capture="$output"
  local status
  set +e
  "$@" >"$output" 2>"$output.stderr"
  status=$?
  set -e
  if [ "$status" -ne "$expected" ]; then
    echo "Expected exit $expected, got $status." >"$output.stderr.expected"
    cat "$output.stderr.expected" >>"$output.stderr"
    return 1
  fi
}

run_or_die "locate ios-debug CLI" "$tmp/cli-check.txt" test -x "$binary"
run_or_die "select simulator" "$tmp/simulator.txt" bash -c \
  'xcrun simctl list devices available -j | "$1"' _ "$root/scripts/select-simulator.swift"
udid="$(tail -n 1 "$tmp/simulator.txt")"

# `simctl boot` returns a nonzero status when an already-booted device is selected.
xcrun simctl boot "$udid" >"$tmp/boot.txt" 2>"$tmp/boot.txt.stderr" || true
run_or_die "wait for simulator boot" "$tmp/bootstatus.txt" xcrun simctl bootstatus "$udid" -b

run_or_die "build DebugDemo ($scheme)" "$tmp/xcodebuild.log" \
  xcodebuild -project "$root/Examples/DebugDemo/DebugDemo.xcodeproj" \
  -scheme "$scheme" -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO build
app="$derived/Build/Products/Debug-iphonesimulator/DebugDemo.app"
run_or_die "validate DebugDemo build product" "$tmp/app-check.txt" test -d "$app"
run_or_die "install DebugDemo" "$tmp/install.txt" xcrun simctl install "$udid" "$app"
run_or_die "launch DebugDemo" "$tmp/launch.txt" env \
  SIMCTL_CHILD_IOS_DEBUG_PORT="$app_port" \
  SIMCTL_CHILD_IOS_DEBUG_TOKEN="$token" \
  xcrun simctl launch --terminate-running-process "$udid" "$bundle_id"

cli=("$binary" --json --transport tcp --tcp-host 127.0.0.1 --port "$port" --device "$udid")
failure_stage="wait for anonymous health probe"
failure_capture="$tmp/probe.json"
ready=0
for attempt in {1..30}; do
  set +e
  env -u IOS_DEBUG_TOKEN "${cli[@]}" app probe >"$tmp/probe.json" 2>"$tmp/probe.json.stderr"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  exit 1
fi
run_or_die "validate anonymous health response" "$tmp/health-check.txt" \
  grep -Eq '"ok":true.*"auth_required":true.*"reachable":true' "$tmp/probe.json"
run_or_die "read anonymous health contract" "$tmp/anonymous-health.json" \
  env -u IOS_DEBUG_TOKEN "${cli[@]}" request get /v1/health
run_or_die "validate minimal anonymous health contract" "$tmp/anonymous-health-check.txt" bash -c '
  set -euo pipefail
  file="$1"
  test "$(plutil -extract data.protocol_version raw -o - "$file")" = 1
  test "$(plutil -extract data.auth_required raw -o - "$file")" = true
  test "$(plutil -extract data.reachable raw -o - "$file")" = true
  if /usr/bin/grep -Eq "\"(service|app_bundle_identifier|app_version)\"" "$file"; then
    exit 1
  else
    test "$?" -eq 1
  fi
' _ "$tmp/anonymous-health.json"

run_expect_status 5 "validate protected request without token" "$tmp/missing-token.json" \
  env -u IOS_DEBUG_TOKEN "${cli[@]}" actions list
run_or_die "validate auth_required response" "$tmp/missing-token-check.txt" \
  grep -q '"code":"auth_required"' "$tmp/missing-token.json"
run_expect_status 5 "validate protected request with wrong token" "$tmp/wrong-token.json" \
  env IOS_DEBUG_TOKEN="$wrong_token" "${cli[@]}" actions list
run_or_die "validate auth_failed response" "$tmp/wrong-token-check.txt" \
  grep -q '"code":"auth_failed"' "$tmp/wrong-token.json"

run_expect_status 5 "validate HEAD without token" "$tmp/head-missing.json" \
  env -u IOS_DEBUG_TOKEN "${cli[@]}" request head /v1/state
run_or_die "validate HEAD auth_required response" "$tmp/head-missing-check.txt" \
  grep -q '"code":"auth_required"' "$tmp/head-missing.json"
run_expect_status 5 "validate HEAD with wrong token" "$tmp/head-wrong.json" \
  env IOS_DEBUG_TOKEN="$wrong_token" "${cli[@]}" request head /v1/state
run_or_die "validate HEAD auth_failed response" "$tmp/head-wrong-check.txt" \
  grep -q '"code":"auth_failed"' "$tmp/head-wrong.json"
run_or_die "validate authenticated HEAD" "$tmp/head.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" request head /v1/state
run_or_die "validate authenticated HEAD success" "$tmp/head-check.txt" \
  grep -q '"ok":true' "$tmp/head.json"

run_or_die "list authenticated actions" "$tmp/actions.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions list
for id in counter.increment counter.reset header.settings; do
  run_or_die "validate action $id" "$tmp/action-$id-check.txt" \
    grep -q "\"identifier\":\"$id\"" "$tmp/actions.json"
done
run_or_die "dry-run counter action" "$tmp/dry-run.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions activate counter.increment --dry-run
run_or_die "validate dry-run response" "$tmp/dry-run-check.txt" grep -q '"ok":true' "$tmp/dry-run.json"

run_or_die "read initial state" "$tmp/before.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" state get
run_or_die "validate initial counter" "$tmp/before-check.txt" bash -c \
  'test "$(plutil -extract data.counter raw -o - "$1")" = 0' _ "$tmp/before.json"
run_or_die "activate counter action" "$tmp/activate.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions activate counter.increment
run_or_die "read incremented state" "$tmp/after.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" state get
run_or_die "validate incremented state" "$tmp/after-check.txt" bash -c \
  'test "$(plutil -extract data.counter raw -o - "$1")" = 1 && test "$(plutil -extract data.last_action raw -o - "$1")" = counter.increment' \
  _ "$tmp/after.json"

run_or_die "activate settings action" "$tmp/settings.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions activate header.settings
run_or_die "read settings state" "$tmp/settings-state.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" state get
run_or_die "validate settings state" "$tmp/settings-check.txt" bash -c \
  'test "$(plutil -extract data.screen raw -o - "$1")" = settings' _ "$tmp/settings-state.json"

png="$tmp/settings.png"
run_or_die "capture screenshot" "$tmp/screenshot.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" screenshot capture --out "$png"
run_or_die "validate screenshot" "$tmp/screenshot-check.txt" bash -c '
  test -s "$1" &&
  test "$(stat -f %Lp "$1")" = 600 &&
  test "$(sips -g format "$1" | awk '\''/format:/{print $2}'\'')" = png &&
  test "$(shasum -a 256 "$1" | awk '\''{print $1}'\'')" = "$(plutil -extract data.sha256 raw -o - "$2")"
' _ "$png" "$tmp/screenshot.json"

failure_stage="verify captured streams contain no secrets"
failure_capture="$tmp/secret-scan.txt"
set +e
scan_directory_for_secrets "$tmp" "$tmp/secret-scan.txt" "$token" "$wrong_token"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "PASS: simulator-e2e"
