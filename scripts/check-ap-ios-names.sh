#!/bin/bash
set -euo pipefail

root="${AP_IOS_NAME_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$root"
failures=0
legacy_patterns=(
  'sx-ios-debug'
  '(?<!ap-)ios-debug'
  '(?<!AP)IOSDebug'
  '(?<!AP_)IOS_DEBUG'
  '(?<!\.ap)\.ios-debug'
  '(?<!APIOS)DebugDemo'
)

scan_file() {
  local file="$1"
  local pattern matches scan_rc
  [[ -f "$file" ]] || return 0
  for pattern in "${legacy_patterns[@]}"; do
    scan_rc=0
    matches="$(rg -n -I --pcre2 "$pattern" "$file" 2>/dev/null)" || scan_rc=$?
    if [[ "$scan_rc" -gt 1 ]]; then
      echo "FAIL: name scan error for $file" >&2
      exit "$scan_rc"
    fi
    if [[ -n "$matches" ]]; then
      echo "FAIL: legacy name in $file" >&2
      printf '%s\n' "$matches" >&2
      failures=1
    fi
  done
}

scan_path() {
  local file="$1"
  local pattern
  for pattern in "${legacy_patterns[@]}"; do
    if printf '%s\n' "$file" | rg -q --pcre2 "$pattern"; then
      echo "FAIL: legacy name in tracked path $file" >&2
      failures=1
    fi
  done
}

if [[ "${1:-}" = --scan-only ]]; then
  shift
  [[ "$#" -gt 0 ]] || { echo 'FAIL: --scan-only needs a file' >&2; exit 2; }
  for file in "$@"; do scan_file "$file"; done
  [[ "$failures" -eq 0 ]] || exit 1
  echo 'PASS: ap-ios-name-scan-fixture'
  exit 0
fi

while IFS= read -r -d '' file; do
  scan_path "$file"
  case "$file" in
    docs/superpowers/specs/2026-07-15-ap-ios-debug-system-rename-design.md|\
    docs/superpowers/plans/2026-07-15-ap-ios-debug-system-rename.md|\
    scripts/local-install.sh|\
    scripts/tests/local-install-safety-test.sh|\
    scripts/check-ap-ios-names.sh|\
    scripts/tests/check-ap-ios-names-test.sh) continue ;;
  esac
  scan_file "$file"
done < <(git ls-files -z)

require_file() { [[ -f "$1" ]] || { echo "FAIL: missing $1" >&2; failures=1; }; }
require_text() {
  local text="$1" file="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: missing '$text' in $file" >&2; failures=1; }
}

require_file cli/cmd/ap-ios-debug/main.go
require_file swift/ap-ios-debug-kit/Package.swift
require_file codex/skills/ap-ios-debug-skill/SKILL.md
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme
require_text 'module github.com/yangy003/ap-ios-debug-system' cli/go.mod
require_text 'AP_IOS_DEBUG_BIN := $(BUILD_DIR)/ap-ios-debug' Makefile
require_text 'name: "ap-ios-debug-kit"' swift/ap-ios-debug-kit/Package.swift
require_text '.library(name: "APIOSDebugCore"' swift/ap-ios-debug-kit/Package.swift
require_text '.library(name: "APIOSDebugKit"' swift/ap-ios-debug-kit/Package.swift
require_text 'name: ap-ios-debug-skill' codex/skills/ap-ios-debug-skill/SKILL.md
require_text 'PRODUCT_BUNDLE_IDENTIFIER = com.openai.ap-ios-debug-demo;' \
  Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj
require_text '# AppPilot' README.md

installer=scripts/local-install.sh
if [[ -f "$installer" ]]; then
  require_text 'legacy_binary="$prefix/bin/ios-debug"' "$installer"
  require_text 'legacy_package="$prefix/share/ios-debug/IOSDebugKit"' "$installer"
  require_text 'legacy_skill="$codex_home/skills/sx-ios-debug"' "$installer"
  filtered="$(mktemp /tmp/ap-ios-installer-names.XXXXXX)"
  trap 'rm -f -- "$filtered"' EXIT
  sed \
    -e '\|^legacy_binary="\$prefix/bin/ios-debug"$|d' \
    -e '\|^legacy_package="\$prefix/share/ios-debug/IOSDebugKit"$|d' \
    -e '\|^legacy_skill="\$codex_home/skills/sx-ios-debug"$|d' \
    "$installer" >"$filtered"
  scan_file "$filtered"
fi

[[ "$failures" -eq 0 ]] || exit 1
echo 'PASS: ap-ios-name-contract'
