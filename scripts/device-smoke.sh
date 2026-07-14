#!/bin/bash
set -euo pipefail

if [[ "${IOS_DEBUG_REAL_DEVICE_SMOKE:-0}" != "1" ]]; then
  echo "SKIP: device-smoke requires IOS_DEBUG_REAL_DEVICE_SMOKE=1"
  exit 0
fi

root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=secret-scan.sh
source "$root/scripts/secret-scan.sh"

binary="${IOS_DEBUG_BIN:-$root/build/ios-debug}"
xcrun_bin="${XCRUN_BIN:-xcrun}"
xcodebuild_bin="${XCODEBUILD_BIN:-xcodebuild}"
uuidgen_bin="${UUIDGEN_BIN:-uuidgen}"
sleep_bin="${SLEEP_BIN:-sleep}"
mp4_validator="${MP4_VALIDATOR_BIN:-$root/scripts/validate-mp4.swift}"
device="${IOS_DEBUG_DEVICE:-}"
team="${IOS_DEBUG_DEVELOPMENT_TEAM:-}"

if [[ -z "$device" ]]; then
  echo "SKIP: device-smoke requires IOS_DEBUG_DEVICE for an explicit trusted device"
  exit 0
fi
if [[ -z "$team" ]]; then
  echo "SKIP: device-smoke requires IOS_DEBUG_DEVELOPMENT_TEAM for signing"
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-device.XXXXXX")"
derived="${DERIVED_DATA:-$root/build/DerivedData-device-smoke}"
bundle_id="com.openai.iosdebug.DebugDemo"
token="$($uuidgen_bin | tr '[:upper:]' '[:lower:]')-$($uuidgen_bin | tr '[:upper:]' '[:lower:]')"
wrong_token="$($uuidgen_bin | tr '[:upper:]' '[:lower:]')-$($uuidgen_bin | tr '[:upper:]' '[:lower:]')"
device_id=""
launched_pid=""
recording_active=0
failure_stage="initialize device smoke"
failure_capture=""
skip_reason=""
secrets_scanned=0

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
  if [[ -s "$output" ]]; then
    echo "--- captured stdout/log (last 200 lines) ---" >&2
    tail -n 200 "$output" | redact_stream >&2
  fi
  if [[ -s "$output.stderr" ]]; then
    echo "--- captured stderr (last 200 lines) ---" >&2
    tail -n 200 "$output.stderr" | redact_stream >&2
  fi
}

run_capture() {
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
  return "$status"
}

json_optional() {
  local path="$1"
  local file="$2"
  local value
  set +e
  value="$(plutil -extract "$path" raw -o - "$file" 2>/dev/null)"
  local status=$?
  set -e
  if [[ "$status" -eq 0 && "$value" != "null" ]]; then
    printf '%s' "$value"
  fi
}

json_optional_string() {
  local path="$1"
  local file="$2"
  local type
  set +e
  type="$(plutil -type "$path" -o - "$file" 2>/dev/null)"
  local status=$?
  set -e
  if [[ "$status" -eq 0 && "$type" == string ]]; then
    json_optional "$path" "$file"
  fi
}

extract_signing_reason() {
  perl -ne '
    if (
      /^\s*(?:(?:.*:\s+)?error:\s+)?Signing for .+ requires a development team\.(?: Select a development team.*)?\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?.+ requires a provisioning profile\.(?: Select a provisioning profile.*)?\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?No profiles for .+ were found(?::.*)?\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?Provisioning profile .+ (?:doesn.t|does not) include .+\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?(?:Command )?CodeSign .*failed(?: with a nonzero exit code)?\.?\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?No signing certificate .+ found\.?\s*$/i ||
      /^\s*(?:(?:.*:\s+)?error:\s+)?.+ requires a signing certificate\.?\s*$/i
    ) {
      print;
      $matched = 1;
      exit 0;
    }
    END { exit 1 unless $matched }
  ' "$@"
}

skip() {
  skip_reason="$1"
  if [[ -n "${2:-}" ]]; then show_capture "$2"; fi
  echo "SKIP: device-smoke $skip_reason"
  exit 0
}

cleanup() {
  local original_status=$?
  trap - EXIT INT TERM
  set +e

  if [[ "$original_status" -ne 0 ]]; then
    echo "FAIL: $failure_stage" >&2
    if [[ -n "$failure_capture" ]]; then show_capture "$failure_capture"; fi
  fi

  if [[ "$recording_active" -eq 1 && -n "$device_id" ]]; then
    cleanup_mp4="$tmp/cleanup-recording.mp4"
    IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording status \
      >"$tmp/cleanup-recording-status.json" 2>"$tmp/cleanup-recording-status.json.stderr" || true
    IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording stop --out "$cleanup_mp4" \
      >"$tmp/cleanup-recording-stop.json" 2>"$tmp/cleanup-recording-stop.json.stderr" || {
        echo "WARN: best-effort recording cleanup failed." >&2
        show_capture "$tmp/cleanup-recording-stop.json"
      }
  fi

  if [[ -n "$launched_pid" && -n "$device_id" ]]; then
    "$xcrun_bin" devicectl device process terminate --device "$device_id" --pid "$launched_pid" \
      --json-output "$tmp/terminate.json" >"$tmp/terminate.log" 2>"$tmp/terminate.log.stderr" || {
        echo "WARN: best-effort App termination failed." >&2
        show_capture "$tmp/terminate.log"
      }
  fi

  if [[ "$original_status" -eq 0 && -z "$skip_reason" && "$secrets_scanned" -eq 0 ]]; then
    scan_directory_for_secrets "$tmp" "$tmp/secret-scan.txt" "$token" "$wrong_token" || original_status=$?
    if [[ "$original_status" -ne 0 ]]; then
      echo "FAIL: captured streams contain a secret" >&2
      show_capture "$tmp/secret-scan.txt"
    fi
  fi

  rm -rf "$tmp"
  exit "$original_status"
}
trap cleanup EXIT INT TERM

test -x "$binary" || { failure_stage="locate ios-debug CLI"; exit 1; }

# Device discovery is the prerequisite gate. A full doctor before App launch
# would incorrectly fail its App probe and hide a usable signed-device setup.
resolve="$tmp/device.json"
if ! run_capture "resolve and check device readiness" "$resolve" \
  env IOS_DEBUG_TOKEN="$token" "$binary" --json devices resolve --name "$device"; then
  code="$(json_optional error.code "$resolve")"
  case "$code" in
    no_device|multiple_devices|device_untrusted|device_locked) skip "$code" "$resolve" ;;
    *) exit 1 ;;
  esac
fi

meta_udid="$(json_optional_string meta.device_id "$resolve")"
data_udid="$(json_optional_string data.device.udid "$resolve")"
if [[ -n "$meta_udid" && -n "$data_udid" && "$meta_udid" != "$data_udid" ]]; then
  failure_stage="validate resolved device identity"
  failure_capture="$resolve"
  exit 1
fi
device_id="${meta_udid:-$data_udid}"
if [[ -z "$device_id" || "$device_id" =~ [[:space:]] ]]; then
  failure_stage="validate resolved device identity"
  failure_capture="$resolve"
  exit 1
fi

cli=("$binary" --json --transport usb --device "$device_id" --port 9876)

# `devices resolve` owns unique selection. A pre-launch App probe additionally
# runs the CLI's trust/lock readiness check; failure to connect is expected
# because this invocation has not installed or launched DebugDemo yet.
preflight="$tmp/device-readiness.json"
if ! run_capture "check selected device trust and lock readiness" "$preflight" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" app probe; then
  code="$(json_optional error.code "$preflight")"
  case "$code" in
    no_device|multiple_devices|device_untrusted|device_locked) skip "$code" "$preflight" ;;
    app_not_reachable|transport_failure|request_timeout) ;;
    *) exit 1 ;;
  esac
fi

xcode_log="$tmp/xcodebuild.log"
if ! run_capture "build and sign DebugDemo" "$xcode_log" \
  "$xcodebuild_bin" -project "$root/Examples/DebugDemo/DebugDemo.xcodeproj" \
    -scheme DebugDemo -configuration Debug -destination "id=$device_id" \
    -derivedDataPath "$derived" DEVELOPMENT_TEAM="$team" \
    -allowProvisioningUpdates build; then
  if extract_signing_reason "$xcode_log" "$xcode_log.stderr" >"$tmp/signing-reason.txt"; then
    skip "signing or provisioning is unavailable" "$tmp/signing-reason.txt"
  fi
  exit 1
fi

app="$derived/Build/Products/Debug-iphoneos/DebugDemo.app"
run_capture "validate signed DebugDemo build product" "$tmp/app-check.txt" test -d "$app"
run_capture "install signed DebugDemo" "$tmp/install.log" \
  "$xcrun_bin" devicectl device install app --device "$device_id" "$app" \
    --json-output "$tmp/install.json"
run_capture "launch DebugDemo with authentication" "$tmp/launch.log" \
  env DEVICECTL_CHILD_IOS_DEBUG_TOKEN="$token" \
    "$xcrun_bin" devicectl device process launch --device "$device_id" --terminate-existing \
      "$bundle_id" --json-output "$tmp/launch.json"
launched_pid="$(json_optional result.process.processIdentifier "$tmp/launch.json")"
if [[ -z "$launched_pid" ]]; then
  launched_pid="$(json_optional result.processIdentifier "$tmp/launch.json")"
fi
if [[ ! "$launched_pid" =~ ^[0-9]+$ || "$launched_pid" -eq 0 ]]; then
  failure_stage="read launched DebugDemo process identifier"
  failure_capture="$tmp/launch.json"
  exit 1
fi

ready=0
for attempt in {1..30}; do
  if run_capture "wait for authenticated App readiness" "$tmp/probe.json" \
    env IOS_DEBUG_TOKEN="$token" "${cli[@]}" app probe; then
    if [[ "$(json_optional data.reachable "$tmp/probe.json")" == "true" && \
          "$(json_optional data.auth_required "$tmp/probe.json")" == "true" ]]; then
      ready=1
      break
    fi
  fi
  cp "$tmp/probe.json" "$tmp/probe-last.json" 2>/dev/null || true
  cp "$tmp/probe.json.stderr" "$tmp/probe-last.json.stderr" 2>/dev/null || true
  "$sleep_bin" 0.25
done
if [[ "$ready" -ne 1 ]]; then
  failure_stage="wait for authenticated App readiness after 30 attempts"
  failure_capture="$tmp/probe-last.json"
  exit 1
fi

# Health proves reachability. Protected requests prove missing, wrong, and
# correct Bearer behavior against the launched device App.
set +e
env -u IOS_DEBUG_TOKEN "${cli[@]}" actions list >"$tmp/auth-missing.json" 2>"$tmp/auth-missing.json.stderr"
missing_status=$?
env IOS_DEBUG_TOKEN="$wrong_token" "${cli[@]}" actions list >"$tmp/auth-wrong.json" 2>"$tmp/auth-wrong.json.stderr"
wrong_status=$?
set -e
if [[ "$missing_status" -ne 5 || "$(json_optional error.code "$tmp/auth-missing.json")" != auth_required ]]; then
  failure_stage="validate missing-token authentication"
  failure_capture="$tmp/auth-missing.json"
  exit 1
fi
if [[ "$wrong_status" -ne 5 || "$(json_optional error.code "$tmp/auth-wrong.json")" != auth_failed ]]; then
  failure_stage="validate wrong-token authentication"
  failure_capture="$tmp/auth-wrong.json"
  exit 1
fi

run_capture "list authenticated actions" "$tmp/actions.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions list
grep -q '"identifier":"counter.increment"' "$tmp/actions.json"
run_capture "activate counter action" "$tmp/activate.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" actions activate counter.increment
run_capture "read incremented state" "$tmp/state.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" state get
test "$(json_optional data.last_action "$tmp/state.json")" = counter.increment

png="$tmp/device.png"
run_capture "capture screenshot" "$tmp/screenshot.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" screenshot capture --out "$png"
png_path="$(json_optional data.path "$tmp/screenshot.json")"
png_size="$(json_optional data.byte_count "$tmp/screenshot.json")"
png_sha="$(json_optional data.sha256 "$tmp/screenshot.json")"
test "$png_path" = "$png"
test -s "$png"
test "$png_size" = "$(stat -f %z "$png")"
test "$(stat -f %Lp "$png")" = 600
test "$(od -An -tx1 -N8 "$png" | tr -d ' \n')" = 89504e470d0a1a0a
test "$(shasum -a 256 "$png" | awk '{print $1}')" = "$png_sha"

run_capture "start short recording" "$tmp/recording-start.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording start
test "$(json_optional data.state "$tmp/recording-start.json")" = recording
recording_active=1
"$sleep_bin" 5
run_capture "read active recording status" "$tmp/recording-status.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording status
test "$(json_optional data.state "$tmp/recording-status.json")" = recording
elapsed_ms="$(json_optional data.elapsed_ms "$tmp/recording-status.json")"
test "$elapsed_ms" -ge 0
test "$elapsed_ms" -le 15000

mp4="$tmp/device.mp4"
run_capture "stop, download, verify, and delete recording" "$tmp/recording-stop.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording stop --out "$mp4"
recording_active=0
test "$(json_optional data.path "$tmp/recording-stop.json")" = "$mp4"
test "$(json_optional data.byte_count "$tmp/recording-stop.json")" = "$(stat -f %z "$mp4")"
test "$(json_optional data.mime "$tmp/recording-stop.json")" = video/mp4
test "$(json_optional data.duration_ms "$tmp/recording-stop.json")" -gt 0
test "$(json_optional data.duration_ms "$tmp/recording-stop.json")" -le 20000
test "$(json_optional data.device_file_deleted "$tmp/recording-stop.json")" = true
test -s "$mp4"
test "$(stat -f %Lp "$mp4")" = 600
test "$(shasum -a 256 "$mp4" | awk '{print $1}')" = "$(json_optional data.sha256 "$tmp/recording-stop.json")"
run_capture "validate recording with AVFoundation" "$tmp/mp4-validation.log" "$mp4_validator" "$mp4"
run_capture "validate final recording state" "$tmp/recording-final.json" \
  env IOS_DEBUG_TOKEN="$token" "${cli[@]}" recording status
test "$(json_optional data.state "$tmp/recording-final.json")" = idle

failure_stage="verify captured stdout and stderr contain no secrets"
failure_capture="$tmp/secret-scan.txt"
scan_directory_for_secrets "$tmp" "$tmp/secret-scan.txt" "$token" "$wrong_token"
secrets_scanned=1
echo "PASS: device-smoke device_id=$device_id"
