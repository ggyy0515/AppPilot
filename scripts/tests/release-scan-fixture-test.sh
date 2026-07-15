#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-release-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/tools" "$work/fixture with spaces/Debug.app/Frameworks/Kit.framework" \
  "$work/fixture with spaces/objects"

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
chmod +x "$work/tools/"*

export FILE_BIN="$work/tools/file"
export OBJCOPY_BIN="$work/tools/objcopy"
export STRINGS_BIN="$work/tools/strings"
export NM_BIN="$work/tools/nm"
export DEMANGLE_BIN="$work/tools/demangle"
export AP_IOS_DEBUG_RELEASE_SCAN_LIBRARY_ONLY=1
# shellcheck source=../release-scan.sh
source "$root/scripts/release-scan.sh"

# Tool discovery must preserve an xcrun override whose path contains spaces.
mkdir -p "$work/tool discovery with spaces"
cat >"$work/tool discovery with spaces/xcrun" <<EOF
#!/usr/bin/env bash
case "\$2" in
  llvm-objcopy) printf '%s\\n' '$work/tools/objcopy' ;;
  strip) printf '%s\\n' '$work/tools/strip' ;;
  swift-demangle) printf '%s\\n' '$work/tools/demangle' ;;
  *) exit 72 ;;
esac
EOF
chmod +x "$work/tool discovery with spaces/xcrun"
discovered="$({
  unset OBJCOPY_BIN STRIP_BIN DEMANGLE_BIN
  XCRUN_BIN="$work/tool discovery with spaces/xcrun"
  AP_IOS_DEBUG_RELEASE_SCAN_LIBRARY_ONLY=1
  source "$root/scripts/release-scan.sh"
  printf '%s\n%s\n%s\n' "$OBJCOPY_BIN" "$STRIP_BIN" "$DEMANGLE_BIN"
})"
grep -Fxq "$work/tools/objcopy" <<<"$discovered"
grep -Fxq "$work/tools/strip" <<<"$discovered"
grep -Fxq "$work/tools/demangle" <<<"$discovered"

app="$work/fixture with spaces/Debug.app"
objects="$work/fixture with spaces/objects"
printf 'ordinary main image\n' >"$app/APIOSDebugDemo"
printf 'STRING:/v1/actions\nSYMBOL:APIOSDebugRuntime\n' >"$app/APIOSDebugDemo.debug.dylib"
printf 'ordinary framework\n' >"$app/Frameworks/Kit.framework/Kit"
printf 'SYMBOL:DebugActionRegistry\n' >"$objects/runtime object.o"

scan_artifacts positive "$app" "$objects" "$work/positive"

cat >"$work/tools/strip" <<'EOF'
#!/usr/bin/env bash
test "$1" = -S
test "$2" = -o
cp "$4" "$3"
EOF
chmod +x "$work/tools/strip"
saved_objcopy="$OBJCOPY_BIN"
OBJCOPY_BIN=''
STRIP_BIN="$work/tools/strip"
scan_artifacts positive "$app" "$objects" "$work/positive-strip-fallback"
OBJCOPY_BIN="$saved_objcopy"

# A source path embedded only in debug information must disappear after the
# strip-copy step and must not become a Release false positive.
cat >"$work/tools/objcopy" <<'EOF'
#!/usr/bin/env bash
grep -v '^DWARF:' "$2" >"$3"
EOF
chmod +x "$work/tools/objcopy"
printf 'DWARF:/tmp/APIOSDebugRuntime.swift\nSTRING:ordinary\n' >"$objects/path only.o"
printf 'ordinary main image\n' >"$app/APIOSDebugDemo.debug.dylib"
printf 'ordinary object\n' >"$objects/runtime object.o"
scan_artifacts negative "$app" "$objects" "$work/negative-clean"

for leak in \
  'STRING:/v1/screenshot' \
  'STRING:/v1/recording/start' \
  'STRING:NWListener' \
  'SYMBOL:NetworkDebugServer' \
  'SYMBOL:iosDebugAction'; do
  printf '%s\n' "$leak" >"$app/Frameworks/Kit.framework/Kit"
  set +e
  scan_artifacts negative "$app" "$objects" "$work/leak" >/dev/null 2>&1
  status=$?
  set -e
  test "$status" -ne 0
done
printf 'ordinary framework\n' >"$app/Frameworks/Kit.framework/Kit"

# Tool absence/failure is a failed scan, never an empty successful result.
for tool in STRINGS_BIN NM_BIN DEMANGLE_BIN OBJCOPY_BIN; do
  failing="$work/tools/fail-${tool}"
  printf '#!/usr/bin/env bash\nexit 42\n' >"$failing"
  chmod +x "$failing"
  old="${!tool}"
  export "$tool=$failing"
  set +e
  diagnostic="$(scan_artifacts negative "$app" "$objects" "$work/fail-$tool" 2>&1)"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Fq 'producer failed' <<<"$diagnostic"
  export "$tool=$old"
done

echo "PASS: release-scan-fixture-test"
