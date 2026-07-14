#!/usr/bin/env bash
set -euo pipefail

verify_release_symbols() {
  local symbols_file="$1"
  if awk '
    /\.o:$/ { next }
    /IOSDebugRuntime|DebugActionRegistry|ScreenshotCapture|RecordingController|iosDebugAction/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$symbols_file"; then
    echo "Release symbol leaked from IOSDebugKit." >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

scripts/tests/verify-swift-release-symbol-scan-test.sh

work="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-swift-release.XXXXXX")"
debug_derived="$work/DebugDerivedData"
release_derived="$work/ReleaseDerivedData"
trap 'rm -rf "$work"' EXIT

swift test --package-path swift/IOSDebugKit

(
  cd swift/IOSDebugKit
  xcodebuild -scheme IOSDebugKit -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$debug_derived" CODE_SIGNING_ALLOWED=NO build
  xcodebuild -scheme IOSDebugKit -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath "$release_derived" CODE_SIGNING_ALLOWED=NO build
)

debug_object_count="$(find "$debug_derived/Build/Intermediates.noindex" -type f -name '*.o' | wc -l | tr -d '[:space:]')"
if [[ "$debug_object_count" == "0" ]]; then
  echo "No Debug object files were produced." >&2
  exit 1
fi

release_object_count="$(find "$release_derived/Build/Intermediates.noindex" -type f -name '*.o' | wc -l | tr -d '[:space:]')"
if [[ "$release_object_count" == "0" ]]; then
  echo "No Release object files were produced." >&2
  exit 1
fi

# Remove DWARF source paths so source file names cannot masquerade as runtime strings.
find "$release_derived/Build/Intermediates.noindex" -type f -name '*.o' -exec strip -S {} +

find "$debug_derived/Build/Intermediates.noindex" -type f -name '*.o' -print0 | sort -z | xargs -0 strings > "$work/debug.strings"
find "$release_derived/Build/Intermediates.noindex" -type f -name '*.o' -print0 | sort -z | xargs -0 strings > "$work/release.strings"
find "$release_derived/Build/Intermediates.noindex" -type f -name '*.o' -print0 | sort -z | xargs -0 nm > "$work/release.symbols"

markers=(
  "/v1/actions"
  "/v1/screenshot"
  "/v1/recording"
  "IOSDebugRuntime"
  "DebugActionRegistry"
  "NWListener"
)

for marker in "${markers[@]}"; do
  if ! grep -Fq -- "$marker" "$work/debug.strings"; then
    echo "Missing Debug marker: $marker" >&2
    exit 1
  fi
  if grep -Fq -- "$marker" "$work/release.strings"; then
    echo "Release marker leaked: $marker" >&2
    exit 1
  fi
done

verify_release_symbols "$work/release.symbols"

echo "Swift Debug/Release verification passed."
