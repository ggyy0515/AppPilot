#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
subject="$root/scripts/device-smoke.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-device-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain [$2]"; }
assert_not_contains() { ! grep -Fq "$2" "$1" || fail "$1 leaked [$2]"; }

bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/uuidgen" <<'EOF'
#!/bin/bash
state="${FIXTURE_STATE:?}"
n=0; [[ -f "$state/uuid-count" ]] && n="$(cat "$state/uuid-count")"
n=$((n + 1)); echo "$n" >"$state/uuid-count"
printf 'fixture-secret-%s-0123456789abcdef\n' "$n"
EOF

cat >"$bin/sleep" <<'EOF'
#!/bin/bash
printf 'sleep=%s\n' "$1" >>"${FIXTURE_STATE:?}/events"
EOF

cat >"$bin/xcodebuild" <<'EOF'
#!/bin/bash
state="${FIXTURE_STATE:?}"
printf 'xcodebuild\n' >>"$state/events"
case "${FIXTURE_SCENARIO:-success}" in
  signing_failure) echo 'Signing for APIOSDebugDemo requires a development team.' >&2; exit 65 ;;
  signing_profile_failure) echo "error: No profiles for 'com.openai.ap-ios-debug-demo' were found: Xcode couldn't find any iOS App Development provisioning profiles." >&2; exit 65 ;;
  signing_codesign_failure) echo 'Command CodeSign failed with a nonzero exit code' >&2; exit 65 ;;
  compile_failure) echo '/tmp/ContentView.swift:12:3: error: cannot find value' >&2; exit 65 ;;
  compile_provisioning_path) echo '/tmp/ProvisioningView.swift:12:3: error: cannot find value' >&2; exit 65 ;;
  compile_certificate_message) echo 'note: ordinary certificate metadata was loaded'; echo '/tmp/ContentView.swift:3:1: error: cannot find value' >&2; exit 65 ;;
  compile_codesign_helper) echo '/tmp/CodeSignHelper.swift:9:2: error: cannot find value' >&2; exit 65 ;;
esac
derived=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then derived="$2"; shift 2; else shift; fi
done
mkdir -p "$derived/Build/Products/Debug-iphoneos/APIOSDebugDemo.app"
EOF

cat >"$bin/xcrun" <<'EOF'
#!/bin/bash
state="${FIXTURE_STATE:?}"
scenario="${FIXTURE_SCENARIO:-success}"
shift # devicectl
if [[ "$*" == device\ install\ app* ]]; then
  printf 'install\n' >>"$state/events"
  [[ "$scenario" == post_sign_failure ]] && { echo 'install failed' >&2; exit 1; }
  exit 0
fi
if [[ "$*" == device\ process\ launch* ]]; then
  [[ -n "${DEVICECTL_CHILD_AP_IOS_DEBUG_TOKEN:-}" ]] || { echo 'missing child token' >&2; exit 1; }
  printf '%s' "$DEVICECTL_CHILD_AP_IOS_DEBUG_TOKEN" | shasum -a 256 | awk '{print $1}' >"$state/token-sha"
  printf 'launch-token=set\n' >>"$state/events"
  touch "$state/launched"
  output=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--json-output" ]]; then output="$2"; shift 2; else shift; fi
  done
  pid=4242; [[ "$scenario" == launch_bad_pid ]] && pid='"oops"'
  printf '{"result":{"process":{"processIdentifier":%s}}}\n' "$pid" >"$output"
  exit 0
fi
if [[ "$*" == device\ process\ terminate* ]]; then
  printf 'terminate\n' >>"$state/events"
  [[ "$scenario" == cleanup_errors ]] && { echo 'Authorization: Bearer cleanup-secret' >&2; exit 1; }
  exit 0
fi
echo "unexpected xcrun: $*" >&2
exit 1
EOF

cat >"$bin/validate-mp4" <<'EOF'
#!/bin/bash
test -s "$1"
printf 'avfoundation=valid\n' >>"${FIXTURE_STATE:?}/events"
EOF

cat >"$bin/ap-ios-debug" <<'EOF'
#!/bin/bash
set -euo pipefail
state="${FIXTURE_STATE:?}"
scenario="${FIXTURE_SCENARIO:-success}"
args=" $* "
token="${AP_IOS_DEBUG_TOKEN:-}"
printf 'cli token=%s args=%s\n' "$([[ -n "$token" ]] && echo set || echo unset)" "$*" >>"$state/events"

emit_error() { printf '{"ok":false,"error":{"code":"%s","message":"fixture"}}\n' "$1"; exit "$2"; }
is_correct_token() {
  [[ -f "$state/token-sha" ]] || return 1
  [[ "$(printf '%s' "$token" | shasum -a 256 | awk '{print $1}')" == "$(cat "$state/token-sha")" ]]
}

if [[ "$args" == *' devices resolve '* ]]; then
  case "$scenario" in
    no_device|multiple_devices|device_untrusted|device_locked) emit_error "$scenario" 3 ;;
    resolve_meta) printf '{"ok":true,"data":{"device":{}},"meta":{"protocol_version":1,"device_id":"udid-1"}}\n';;
    resolve_data) printf '{"ok":true,"data":{"device":{"udid":"udid-1"}},"meta":{"protocol_version":1}}\n';;
    resolve_mismatch) printf '{"ok":true,"data":{"device":{"udid":"udid-2"}},"meta":{"device_id":"udid-1"}}\n';;
    resolve_nonstring) printf '{"ok":true,"data":{"device":{}},"meta":{"device_id":42}}\n';;
    *) printf '{"ok":true,"data":{"device":{"udid":"udid-1"}},"meta":{"protocol_version":1,"device_id":"udid-1"}}\n';;
  esac
  exit 0
fi

if [[ "$args" == *' app probe '* ]]; then
  if [[ ! -f "$state/launched" ]]; then
    case "$scenario" in
      readiness_device_locked) emit_error device_locked 3 ;;
      readiness_device_untrusted) emit_error device_untrusted 3 ;;
      *) emit_error app_not_reachable 5 ;;
    esac
  fi
  if [[ "$scenario" == readiness_retries ]]; then
    n=0; [[ -f "$state/probes" ]] && n="$(cat "$state/probes")"; n=$((n+1)); echo "$n" >"$state/probes"
    (( n < 3 )) && { echo 'temporary fixture-secret-1-0123456789abcdef' >&2; exit 4; }
  fi
  is_correct_token || emit_error auth_failed 5
  printf '{"ok":true,"data":{"protocol_version":1,"auth_required":true,"reachable":true}}\n'
  exit 0
fi

if [[ "$args" == *' actions list '* ]]; then
  [[ -n "$token" ]] || emit_error auth_required 5
  is_correct_token || emit_error auth_failed 5
  printf '{"ok":true,"data":{"actions":[{"identifier":"counter.increment"}]}}\n'; exit 0
fi
if [[ "$args" == *' actions activate '* ]]; then printf '{"ok":true,"data":{}}\n'; exit 0; fi
if [[ "$args" == *' state get '* ]]; then printf '{"ok":true,"data":{"last_action":"counter.increment"}}\n'; exit 0; fi
if [[ "$args" == *' screenshot capture '* ]]; then
  out="${!#}"; printf '\211PNG\r\n\032\nfixture' >"$out"; chmod 600 "$out"
  sha="$(shasum -a 256 "$out" | awk '{print $1}')"; size="$(stat -f %z "$out")"
  reported="$out"; [[ "$scenario" == screenshot_bad_path ]] && reported="$out.wrong"
  printf '{"ok":true,"data":{"path":"%s","byte_count":%s,"mime":"image/png","sha256":"%s"}}\n' "$reported" "$size" "$sha"; exit 0
fi
if [[ "$args" == *' recording start '* ]]; then
  echo recording >"$state/recording"; printf 'recording-start\n' >>"$state/events"
  printf '{"ok":true,"data":{"state":"recording","elapsed_ms":0,"recording_id":"rec-1"}}\n'; exit 0
fi
if [[ "$args" == *' recording status '* ]]; then
  phase=idle; [[ -f "$state/recording" ]] && phase="$(cat "$state/recording")"
  if [[ "$scenario" == recording_status_failure && "$phase" == recording ]]; then emit_error transport_failure 4; fi
  printf '{"ok":true,"data":{"state":"%s","elapsed_ms":1000}}\n' "$phase"; exit 0
fi
if [[ "$args" == *' recording stop '* ]]; then
  out="${!#}"; printf '....ftypisom....moovfixture' >"$out"; chmod 600 "$out"; echo idle >"$state/recording"
  printf 'recording-stop-delete\n' >>"$state/events"
  sha="$(shasum -a 256 "$out" | awk '{print $1}')"; size="$(stat -f %z "$out")"
  duration=5000; [[ "$scenario" == recording_long ]] && duration=25000
  deleted=true; [[ "$scenario" == recording_not_deleted ]] && deleted=false
  printf '{"ok":true,"data":{"path":"%s","byte_count":%s,"mime":"video/mp4","sha256":"%s","recording_id":"rec-1","duration_ms":%s,"device_file_deleted":%s}}\n' "$out" "$size" "$sha" "$duration" "$deleted"; exit 0
fi
echo "unexpected ap-ios-debug: $*" >&2
exit 9
EOF

chmod +x "$bin"/*

run_case() {
  local scenario="$1"; shift
  local dir="$tmp/fixture cases/$scenario"
  rm -rf "$dir"; mkdir -p "$dir"
  set +e
  env FIXTURE_SCENARIO="$scenario" FIXTURE_STATE="$dir" \
    AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1 AP_IOS_DEBUG_DEVICE='Fixture Phone' \
    AP_IOS_DEBUG_DEVELOPMENT_TEAM=ABCDE12345 AP_IOS_DEBUG_BIN="$bin/ap-ios-debug" \
    XCRUN_BIN="$bin/xcrun" XCODEBUILD_BIN="$bin/xcodebuild" \
    UUIDGEN_BIN="$bin/uuidgen" SLEEP_BIN="$bin/sleep" \
    MP4_VALIDATOR_BIN="$bin/validate-mp4" DERIVED_DATA="$dir/Derived Data" \
    TMPDIR="$dir" "$subject" >"$dir/stdout" 2>"$dir/stderr"
  CASE_STATUS=$?
  set -e
  CASE_DIR="$dir"
}

# Default guard is exactly one SKIP and does not touch injected tools.
guard="$tmp/guard"; mkdir -p "$guard"
env FIXTURE_STATE="$guard" AP_IOS_DEBUG_BIN="$bin/ap-ios-debug" XCRUN_BIN="$bin/xcrun" \
  "$subject" >"$guard/stdout" 2>"$guard/stderr"
assert_eq "$(cat "$guard/stdout")" 'SKIP: device-smoke requires AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1'
[[ ! -e "$guard/events" ]] || fail 'opt-out invoked a dependency'

for scenario in no_device multiple_devices device_untrusted device_locked; do
  run_case "$scenario"
  assert_eq "$CASE_STATUS" 0
  assert_eq "$(cat "$CASE_DIR/stdout")" "SKIP: device-smoke $scenario"
done

for scenario in readiness_device_locked readiness_device_untrusted; do
  run_case "$scenario"
  assert_eq "$CASE_STATUS" 0
  expected="${scenario#readiness_}"
  assert_eq "$(cat "$CASE_DIR/stdout")" "SKIP: device-smoke $expected"
  [[ ! -e "$CASE_DIR/launched" ]] || fail "$scenario reached App launch"
done

run_case signing_failure
assert_eq "$CASE_STATUS" 0
assert_eq "$(cat "$CASE_DIR/stdout")" 'SKIP: device-smoke signing or provisioning is unavailable'

for scenario in signing_profile_failure signing_codesign_failure; do
  run_case "$scenario"
  assert_eq "$CASE_STATUS" 0
  assert_eq "$(cat "$CASE_DIR/stdout")" 'SKIP: device-smoke signing or provisioning is unavailable'
done

for scenario in compile_failure compile_provisioning_path compile_certificate_message compile_codesign_helper; do
  run_case "$scenario"
  [[ "$CASE_STATUS" -ne 0 ]] || fail "$scenario was incorrectly skipped"
  assert_contains "$CASE_DIR/stderr" 'cannot find value'
done

run_case post_sign_failure
[[ "$CASE_STATUS" -ne 0 ]] || fail 'post-sign failure was incorrectly skipped'
assert_contains "$CASE_DIR/events" 'install'

run_case launch_bad_pid
[[ "$CASE_STATUS" -ne 0 ]] || fail 'invalid launch PID passed'

run_case resolve_meta; assert_eq "$CASE_STATUS" 0
run_case resolve_data; assert_eq "$CASE_STATUS" 0
run_case resolve_mismatch; [[ "$CASE_STATUS" -ne 0 ]] || fail 'mismatched UDIDs passed'
run_case resolve_nonstring; [[ "$CASE_STATUS" -ne 0 ]] || fail 'non-string UDID passed'

run_case readiness_retries
assert_eq "$CASE_STATUS" 0
assert_eq "$(cat "$CASE_DIR/probes")" 3
assert_contains "$CASE_DIR/events" 'sleep=0.25'

run_case success
assert_eq "$CASE_STATUS" 0
assert_contains "$CASE_DIR/stdout" 'PASS: device-smoke device_id=udid-1'
assert_contains "$CASE_DIR/events" 'launch-token=set'
assert_contains "$CASE_DIR/events" 'cli token=unset args=--json --transport usb --device udid-1 --port 9876 actions list'
assert_contains "$CASE_DIR/events" 'recording-stop-delete'
assert_contains "$CASE_DIR/events" 'avfoundation=valid'
assert_contains "$CASE_DIR/events" 'terminate'
assert_not_contains "$CASE_DIR/stdout" 'fixture-secret-'
assert_not_contains "$CASE_DIR/stderr" 'fixture-secret-'

for scenario in screenshot_bad_path recording_long recording_not_deleted; do
  run_case "$scenario"
  [[ "$CASE_STATUS" -ne 0 ]] || fail "$scenario incorrectly passed"
  assert_contains "$CASE_DIR/events" 'terminate'
done

run_case cleanup_errors
assert_eq "$CASE_STATUS" 0
assert_contains "$CASE_DIR/stdout" 'PASS: device-smoke device_id=udid-1'
assert_contains "$CASE_DIR/stderr" '<redacted>'
assert_not_contains "$CASE_DIR/stderr" 'cleanup-secret'

run_case recording_status_failure
[[ "$CASE_STATUS" -ne 0 ]] || fail 'recording status failure passed'
assert_contains "$CASE_DIR/events" 'recording-stop-delete'
assert_contains "$CASE_DIR/events" 'terminate'
assert_not_contains "$CASE_DIR/stderr" 'fixture-secret-1-0123456789abcdef'

echo 'PASS: device-smoke fixtures'
