#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MAKE_BIN="${MAKE_BIN:-make}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"
LSOF_BIN="${LSOF_BIN:-/usr/sbin/lsof}"
SELECT_SIMULATOR_BIN="${SELECT_SIMULATOR_BIN:-$root/scripts/select-simulator.swift}"
FILE_BIN="${FILE_BIN:-/usr/bin/file}"
OBJCOPY_BIN="${OBJCOPY_BIN:-$("$XCRUN_BIN" --find llvm-objcopy 2>/dev/null || true)}"
STRIP_BIN="${STRIP_BIN:-$("$XCRUN_BIN" --find strip 2>/dev/null || true)}"
STRINGS_BIN="${STRINGS_BIN:-/usr/bin/strings}"
NM_BIN="${NM_BIN:-/usr/bin/nm}"
DEMANGLE_BIN="${DEMANGLE_BIN:-$("$XCRUN_BIN" --find swift-demangle 2>/dev/null || true)}"
GREP_BIN="${GREP_BIN:-/usr/bin/grep}"

producer() {
  local label="$1"
  local output="$2"
  shift 2
  local status=0
  "$@" >"$output" 2>"$output.stderr" || status=$?
  [ "$status" -eq 0 ] || {
    echo "FAIL: $label producer failed with exit $status" >&2
    return "$status"
  }
}

pattern_status() {
  local pattern="$1"
  local input="$2"
  local diagnostic="$3"
  local status=0
  "$GREP_BIN" -E "$pattern" "$input" >"$diagnostic" 2>"$diagnostic.stderr" || status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) echo "FAIL: grep producer failed with exit $status" >&2; return "$status" ;;
  esac
}

strip_copy() {
  local input="$1"
  local output="$2"
  local diagnostic="$3"
  if [ -n "$OBJCOPY_BIN" ]; then
    producer "objcopy $input" "$diagnostic" \
      "$OBJCOPY_BIN" --strip-debug "$input" "$output"
  elif [ -n "$STRIP_BIN" ]; then
    producer "strip $input" "$diagnostic" \
      "$STRIP_BIN" -S -o "$output" "$input"
  else
    echo "FAIL: strip-copy producer failed: tool missing" >&2
    return 127
  fi
}

collect_scan_inputs() {
  local app="$1"
  local objects="$2"
  local workspace="$3"
  local candidates="$workspace/candidates.txt"
  local object_candidates="$workspace/object-candidates.txt"
  local input file_output status index=0

  : >"$workspace/inputs.txt"
  producer "find App files" "$candidates" /usr/bin/find "$app" -type f -print || return $?
  while IFS= read -r input; do
    index=$((index + 1))
    file_output="$workspace/file-$index.txt"
    producer "classify App image" "$file_output" "$FILE_BIN" -b "$input" || return $?
    status=0
    pattern_status '^Mach-O([[:space:]]|$)' "$file_output" "$file_output.match" || status=$?
    if [ "$status" -eq 0 ]; then printf '%s\n' "$input" >>"$workspace/inputs.txt"; fi
  done <"$candidates"

  if [ -d "$objects" ]; then
    producer "find DerivedData objects" "$object_candidates" /usr/bin/find "$objects" -type f -name '*.o' -print || return $?
    while IFS= read -r input; do printf '%s\n' "$input" >>"$workspace/inputs.txt"; done <"$object_candidates"
  fi
  if [ ! -s "$workspace/inputs.txt" ]; then
    echo "FAIL: scan found no Mach-O images or object files" >&2
    return 1
  fi
}

scan_artifacts() {
  local mode="$1"
  local app="$2"
  local objects="$3"
  local workspace="$4"
  local index=0 input stripped strings_output nm_output symbols_output line status
  local runtime_pattern='APIOSDebugRuntime|DebugActionRegistry|RecordingController|ScreenshotCapture|HTTPRouter|NetworkDebugServer|iosDebugAction'
  local route_pattern='/v1/(actions|screenshot|recording)'
  local network_pattern='NWListener|NetworkDebugServer'

  mkdir -p "$workspace"
  test -n "$DEMANGLE_BIN" || { echo "FAIL: demangle producer failed: tool missing" >&2; return 127; }
  collect_scan_inputs "$app" "$objects" "$workspace" || return $?
  : >"$workspace/all.strings"
  : >"$workspace/all.symbols"

  while IFS= read -r input; do
    index=$((index + 1))
    stripped="$workspace/image-$index.stripped"
    strings_output="$workspace/image-$index.strings"
    nm_output="$workspace/image-$index.nm"
    symbols_output="$workspace/image-$index.symbols"
    strip_copy "$input" "$stripped" "$workspace/image-$index.strip" || return $?
    producer "strings $input" "$strings_output" "$STRINGS_BIN" -a "$stripped" || return $?
    producer "nm $input" "$nm_output" "$NM_BIN" -gjU "$stripped" || return $?
    producer "demangle $input" "$symbols_output" "$DEMANGLE_BIN" <"$nm_output" || return $?
    while IFS= read -r line; do printf '%s\n' "$line" >>"$workspace/all.strings"; done <"$strings_output"
    while IFS= read -r line; do
      case "$line" in
        ''|*:) continue ;;
        *) printf '%s\n' "$line" >>"$workspace/all.symbols" ;;
      esac
    done <"$symbols_output"
  done <"$workspace/inputs.txt"

  if [ "$mode" = positive ]; then
    status=0
    pattern_status '/v1/actions([^A-Za-z0-9._-]|$)' "$workspace/all.strings" "$workspace/positive-route.match" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "FAIL: Debug positive control did not contain /v1/actions" >&2
      return 1
    fi
    status=0
    pattern_status "$runtime_pattern" "$workspace/all.symbols" "$workspace/positive-symbol.match" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "FAIL: Debug positive control did not contain an APIOSDebugKit runtime symbol" >&2
      return 1
    fi
    return 0
  fi

  local patterns=("$route_pattern" "$runtime_pattern" "$network_pattern" "$runtime_pattern")
  local files=("$workspace/all.strings" "$workspace/all.strings" "$workspace/all.strings" "$workspace/all.symbols")
  local messages=(
    'Release artifact contains a forbidden route'
    'Release artifact contains an APIOSDebugKit runtime type string'
    'Release artifact contains a Network listener marker'
    'Release artifact contains an APIOSDebugKit runtime symbol'
  )
  for index in 0 1 2 3; do
    local pattern="${patterns[$index]}"
    local file="${files[$index]}"
    local message="${messages[$index]}"
    status=0
    pattern_status "$pattern" "$file" "$workspace/negative-$RANDOM.match" || status=$?
    if [ "$status" -eq 0 ]; then
      echo "FAIL: $message" >&2
      return 1
    elif [ "$status" -ne 1 ]; then
      return "$status"
    fi
  done
}

if [ "${AP_IOS_DEBUG_RELEASE_SCAN_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

# Runtime orchestration is intentionally below the library guard so fixture
# tests exercise the exact scanner without requiring Xcode or a simulator.
binary="${AP_IOS_DEBUG_BIN:-$root/build/ap-ios-debug}"
derived="${DERIVED_DATA:-$root/build/DerivedData-release-scan}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-release.XXXXXX")"
bundle_id="com.openai.ap-ios-debug-demo"
udid=""
token="${AP_IOS_DEBUG_RELEASE_TOKEN:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
port="${AP_IOS_DEBUG_RELEASE_PORT:-9876}"
release_scheme="${AP_IOS_DEBUG_RELEASE_SCHEME:-ap-ios-debug-demo-release}"
failure_stage="initialize Release scan"
failure_capture=""

redact_stream() {
  AP_IOS_DEBUG_REDACT_TOKEN="$token" perl -pe '
    s/\Q$ENV{AP_IOS_DEBUG_REDACT_TOKEN}\E/<redacted>/g if length($ENV{AP_IOS_DEBUG_REDACT_TOKEN} // "");
    s/(Authorization\s*:\s*Bearer\s+)\S+/${1}<redacted>/ig;
    s/(AP_IOS_DEBUG_TOKEN\s*[=:]\s*)\S+/${1}<redacted>/ig;
  '
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $failure_stage" >&2
    for output in "$tmp/xcodebuild-debug.log" "$tmp/xcodebuild-release.log" "$tmp/probe-debug.json" "$tmp/probe-release.json" "$failure_capture"; do
      if [ -d "$output" ]; then
        echo "--- $(basename "$output") scan diagnostics ---" >&2
        while IFS= read -r scan_log; do
          tail -n 40 "$scan_log" | redact_stream >&2
        done < <(/usr/bin/find "$output" -type f \( -name '*.stderr' -o -name '*.match' \) -size +0c -print)
        continue
      fi
      if [ -n "$output" ] && [ -s "$output" ]; then
        echo "--- $(basename "$output") (last 200 lines) ---" >&2
        tail -n 200 "$output" | redact_stream >&2
      fi
      if [ -n "$output" ] && [ -s "$output.stderr" ]; then
        tail -n 200 "$output.stderr" | redact_stream >&2
      fi
    done
  fi
  if [ -n "$udid" ]; then "$XCRUN_BIN" simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

run_stage() {
  local stage="$1"
  local output="$2"
  shift 2
  failure_stage="$stage"
  failure_capture="$output"
  producer "$stage" "$output" "$@"
}

probe_debug_until_ready() {
  local attempts="${AP_IOS_DEBUG_RELEASE_RETRIES:-30}"
  local delay="${AP_IOS_DEBUG_RELEASE_RETRY_DELAY:-0.25}"
  local attempt status match
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status=0
    env AP_IOS_DEBUG_TOKEN="$token" "$binary" --json --transport tcp --tcp-host 127.0.0.1 \
      --port "$port" --device "$udid" app probe \
      >"$tmp/probe-debug.json" 2>"$tmp/probe-debug.json.stderr" || status=$?
    if [ "$status" -eq 0 ]; then
      match=0
      pattern_status '"ok":true' "$tmp/probe-debug.json" "$tmp/probe-debug.match" || match=$?
      if [ "$match" -eq 0 ]; then return 0; fi
    fi
    if [ "$attempt" -lt "$attempts" ] && [ "$delay" != 0 ]; then sleep "$delay"; fi
  done
  echo "Debug probe did not become ready after $attempts attempts." >>"$tmp/probe-debug.json.stderr"
  return 1
}

failure_stage="validate TCP port"
failure_capture="$tmp/port-check.txt"
port_status=0
"$LSOF_BIN" -nP -iTCP:"$port" -sTCP:LISTEN >"$tmp/port-check.txt" 2>"$tmp/port-check.txt.stderr" || port_status=$?
case "$port_status" in
  0) echo "FAIL: port $port is already in use" >&2; exit 1 ;;
  1) ;;
  *) echo "FAIL: port-check producer failed with exit $port_status" >&2; exit "$port_status" ;;
esac

run_stage "locate ap-ios-debug CLI" "$tmp/cli-check.txt" test -x "$binary"

debug_derived="$derived/Debug"
release_derived="$derived/Release"
run_stage "build Debug positive control" "$tmp/xcodebuild-debug.log" \
  "$XCODEBUILD_BIN" -project "$root/Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj" \
  -scheme ap-ios-debug-demo -configuration Debug -sdk iphonesimulator \
  -derivedDataPath "$debug_derived" CODE_SIGNING_ALLOWED=NO build
debug_app="$debug_derived/Build/Products/Debug-iphonesimulator/APIOSDebugDemo.app"
failure_stage="scan Debug positive control"
failure_capture="$tmp/debug-scan"
scan_artifacts positive "$debug_app" "$debug_derived/Build/Intermediates.noindex/APIOSDebugDemo.build" "$tmp/debug-scan"

run_stage "build Release exclusion control" "$tmp/xcodebuild-release.log" \
  "$MAKE_BIN" -C "$root" demo-release \
  XCODEBUILD="$XCODEBUILD_BIN" DEMO_RELEASE_SCHEME="$release_scheme" DERIVED_DATA="$release_derived"
release_app="$release_derived/Build/Products/Release-iphonesimulator/APIOSDebugDemoRelease.app"
failure_stage="scan Release artifacts"
failure_capture="$tmp/release-scan"
# Scan App-owned objects as well as every Mach-O shipped in the bundle. SwiftPM
# may compile APIOSDebugCore package artifacts while resolving the graph; those
# are not App artifacts unless they are present in the final bundle/link image.
scan_artifacts negative "$release_app" "$release_derived/Build/Intermediates.noindex/APIOSDebugDemoRelease.build" "$tmp/release-scan"

run_stage "list available simulators" "$tmp/simulators.json" \
  "$XCRUN_BIN" simctl list devices available -j
run_stage "select simulator" "$tmp/simulator.txt" "$SELECT_SIMULATOR_BIN" <"$tmp/simulators.json"
udid="$(tail -n 1 "$tmp/simulator.txt")"
test -n "$udid"

# A selected simulator may already be booted. Preserve and classify the boot
# result, then require bootstatus to prove it is usable.
boot_status=0
"$XCRUN_BIN" simctl boot "$udid" >"$tmp/boot.txt" 2>"$tmp/boot.txt.stderr" || boot_status=$?
case "$boot_status" in 0|149) ;; *) failure_stage="boot simulator"; failure_capture="$tmp/boot.txt"; exit "$boot_status" ;; esac
run_stage "wait for simulator boot" "$tmp/bootstatus.txt" "$XCRUN_BIN" simctl bootstatus "$udid" -b

run_stage "install Debug positive control" "$tmp/install-debug.txt" \
  "$XCRUN_BIN" simctl install "$udid" "$debug_app"
run_stage "launch Debug positive control" "$tmp/launch-debug.txt" env \
  SIMCTL_CHILD_AP_IOS_DEBUG_PORT="$port" SIMCTL_CHILD_AP_IOS_DEBUG_TOKEN="$token" \
  "$XCRUN_BIN" simctl launch --terminate-running-process "$udid" "$bundle_id"
failure_stage="probe Debug positive control"
failure_capture="$tmp/probe-debug.json"
probe_debug_until_ready

run_stage "terminate Debug positive control" "$tmp/terminate-debug.txt" \
  "$XCRUN_BIN" simctl terminate "$udid" "$bundle_id"
run_stage "install Release exclusion control" "$tmp/install-release.txt" \
  "$XCRUN_BIN" simctl install "$udid" "$release_app"
run_stage "launch Release exclusion control" "$tmp/launch-release.txt" env \
  SIMCTL_CHILD_AP_IOS_DEBUG_PORT="$port" SIMCTL_CHILD_AP_IOS_DEBUG_TOKEN="$token" \
  "$XCRUN_BIN" simctl launch --terminate-running-process "$udid" "$bundle_id"

failure_stage="prove Release app has no debug listener"
failure_capture="$tmp/probe-release.json"
release_probe_status=0
env AP_IOS_DEBUG_TOKEN="$token" "$binary" --json --transport tcp --tcp-host 127.0.0.1 \
  --port "$port" --device "$udid" app probe \
  >"$tmp/probe-release.json" 2>"$tmp/probe-release.json.stderr" || release_probe_status=$?
if [ "$release_probe_status" -ne 4 ]; then
  echo "Expected Release probe exit 4, got $release_probe_status." >>"$tmp/probe-release.json.stderr"
  exit 1
fi
release_match=0
pattern_status '"code":"app_not_reachable"' "$tmp/probe-release.json" "$tmp/probe-release.match" || release_match=$?
if [ "$release_match" -ne 0 ]; then
  echo 'Release probe did not return app_not_reachable.' >>"$tmp/probe-release.json.stderr"
  exit 1
fi

echo "PASS: release-scan"
