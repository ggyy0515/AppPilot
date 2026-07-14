#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-release-runtime.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tools" "$work/derived data"
log="$work/calls.log"
state="$work/state"
token='release-runtime-secret'

cat >"$work/tools/file" <<'EOF'
#!/usr/bin/env bash
printf 'Mach-O 64-bit object arm64\n'
EOF
cat >"$work/tools/objcopy" <<'EOF'
#!/usr/bin/env bash
cp "$2" "$3"
EOF
cat >"$work/tools/strings" <<'EOF'
#!/usr/bin/env bash
sed -n 's/^STRING://p' "${@: -1}"
EOF
cat >"$work/tools/nm" <<'EOF'
#!/usr/bin/env bash
sed -n 's/^SYMBOL://p' "${@: -1}"
EOF
cat >"$work/tools/demangle" <<'EOF'
#!/usr/bin/env bash
cat
EOF
cat >"$work/tools/lsof" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_LSOF_STATUS:-1}"
EOF
cat >"$work/tools/select-simulator" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'SIM-UDID\n'
EOF
cat >"$work/tools/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s token=%s\n' "$*" "${IOS_DEBUG_RELEASE_TOKEN:-}" >>"$FAKE_LOG"
if [ "${FAKE_XCODE_FAIL:-0}" = 1 ]; then
  printf 'build failed token=%s\n' "${IOS_DEBUG_RELEASE_TOKEN:-}" >&2
  exit 65
fi
configuration=''
derived=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -configuration) configuration="$2"; shift 2 ;;
    -derivedDataPath) derived="$2"; shift 2 ;;
    *) shift ;;
  esac
done
app="$derived/Build/Products/${configuration}-iphonesimulator/DebugDemo.app"
if [ "$configuration" = Release ]; then target=DebugDemoRelease; else target=DebugDemo; fi
objects="$derived/Build/Intermediates.noindex/$target.build"
mkdir -p "$app/Frameworks/F.framework" "$objects"
printf 'ordinary main\n' >"$app/DebugDemo"
printf 'ordinary framework\n' >"$app/Frameworks/F.framework/F"
if [ "$configuration" = Debug ]; then
  printf 'STRING:/v1/actions\nSYMBOL:IOSDebugRuntime\n' >"$app/DebugDemo.debug.dylib"
  printf 'SYMBOL:DebugActionRegistry\n' >"$objects/runtime.o"
else
  printf 'ordinary release object\n' >"$objects/app.o"
fi
EOF
cat >"$work/tools/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s port=%s token=%s\n' "$*" "${SIMCTL_CHILD_IOS_DEBUG_PORT:-}" "${SIMCTL_CHILD_IOS_DEBUG_TOKEN:-}" >>"$FAKE_LOG"
shift # simctl
case "$1" in
  list) printf '{"devices":{}}\n' ;;
  install)
    case "$3" in *'/Debug/'*) printf Debug >"$FAKE_STATE" ;; *'/Release/'*) printf Release >"$FAKE_STATE" ;; esac
    ;;
  *) ;;
esac
EOF
cat >"$work/tools/ios-debug" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cli %s port=%s token=%s state=%s\n' "$*" "${IOS_DEBUG_RELEASE_PORT:-}" "${IOS_DEBUG_TOKEN:-}" "$(cat "$FAKE_STATE" 2>/dev/null || true)" >>"$FAKE_LOG"
if [ "$(cat "$FAKE_STATE")" = Debug ]; then
  count_file="$FAKE_STATE.count"
  count=0; [ ! -f "$count_file" ] || count="$(cat "$count_file")"
  count=$((count + 1)); printf '%s' "$count" >"$count_file"
  if [ "$count" -lt 2 ]; then
    printf '{"ok":false,"error":{"code":"app_not_reachable"}}\n'; exit 4
  fi
  printf '{"ok":true,"data":{"auth_required":true}}\n'; exit 0
fi
printf '{"ok":false,"error":{"code":"app_not_reachable"}}\n'
exit 4
EOF
chmod +x "$work/tools/"*

common_env=(
  FAKE_LOG="$log" FAKE_STATE="$state"
  FILE_BIN="$work/tools/file" OBJCOPY_BIN="$work/tools/objcopy"
  STRINGS_BIN="$work/tools/strings" NM_BIN="$work/tools/nm"
  DEMANGLE_BIN="$work/tools/demangle" LSOF_BIN="$work/tools/lsof"
  XCODEBUILD_BIN="$work/tools/xcodebuild" XCRUN_BIN="$work/tools/xcrun"
  SELECT_SIMULATOR_BIN="$work/tools/select-simulator"
  IOS_DEBUG_BIN="$work/tools/ios-debug" DERIVED_DATA="$work/derived data"
  IOS_DEBUG_RELEASE_TOKEN="$token" IOS_DEBUG_RELEASE_PORT=19876
  IOS_DEBUG_RELEASE_RETRIES=3 IOS_DEBUG_RELEASE_RETRY_DELAY=0
)

output="$(env "${common_env[@]}" "$root/scripts/release-scan.sh")"
grep -Fq 'PASS: release-scan' <<<"$output"
test "$(grep -c '^xcodebuild ' "$log")" -eq 2
grep -Fq -- '-configuration Debug' "$log"
grep -Fq -- '-configuration Release' "$log"
test "$(grep -c '^cli ' "$log")" -eq 3
test "$(grep '^cli ' "$log" | sed -n '1p' | grep -c 'port=19876')" -eq 1
test "$(grep '^cli ' "$log" | sed -n '3p' | grep -c 'port=19876')" -eq 1
grep -Fq 'launch --terminate-running-process SIM-UDID com.openai.iosdebug.DebugDemo port=19876' "$log"

set +e
occupied="$(env "${common_env[@]}" FAKE_LSOF_STATUS=0 "$root/scripts/release-scan.sh" 2>&1)"
status=$?
set -e
test "$status" -ne 0
grep -Fq 'port 19876 is already in use' <<<"$occupied"

set +e
failed="$(env "${common_env[@]}" FAKE_XCODE_FAIL=1 "$root/scripts/release-scan.sh" 2>&1)"
status=$?
set -e
test "$status" -ne 0
grep -Fq '<redacted>' <<<"$failed"
if grep -Fq "$token" <<<"$failed"; then
  echo 'release-scan failure diagnostics leaked token' >&2
  exit 1
fi

echo "PASS: release-scan-runtime-test"
