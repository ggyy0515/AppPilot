#!/bin/bash
set -euo pipefail

root="${AP_IOS_NAME_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$root"
root="$(pwd -P)"
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
    scripts/check-ap-ios-names.sh|\
    scripts/tests/check-ap-ios-names-test.sh) continue ;;
  esac
  scan_file "$file"
done < <(git ls-files -z)

require_file() { [[ -f "$1" ]] || { echo "FAIL: missing $1" >&2; failures=1; }; }
fail_metadata() { echo "FAIL: invalid $1 metadata" >&2; failures=1; }

require_file cli/cmd/ap-ios-debug/main.go
require_file swift/ap-ios-debug-kit/Package.swift
require_file codex/skills/ap-ios-debug-skill/SKILL.md
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme
require_file Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme

go_module=""
if ! go_module="$(cd cli && GOWORK=off go list -m -f '{{.Path}}' 2>/dev/null)" || \
  [[ "$go_module" != github.com/yangy003/ap-ios-debug-system ]]; then
  fail_metadata 'Go module'
fi

swift_metadata=""
if ! swift_metadata="$(swift package dump-package --package-path swift/ap-ios-debug-kit 2>/dev/null | \
  /usr/bin/ruby -rjson -e 'document = JSON.parse(STDIN.read); puts document.fetch("name"); puts document.fetch("products").map { |product| product.fetch("name") }.sort')" || \
  [[ "$swift_metadata" != $'ap-ios-debug-kit\nAPIOSDebugCore\nAPIOSDebugKit' ]]; then
  fail_metadata 'Swift package'
fi

skill_name=""
if ! skill_name="$(/usr/bin/ruby -e '
  lines = File.readlines(ARGV.fetch(0), chomp: true)
  abort unless lines.first == "---"
  closing = lines[1..].index("---")
  abort unless closing
  names = lines[1, closing].map { |line| line[/\Aname:\s*(.*?)\s*\z/, 1] }.compact
  abort unless names.length == 1
  puts names.first
' codex/skills/ap-ios-debug-skill/SKILL.md 2>/dev/null)" || [[ "$skill_name" != ap-ios-debug-skill ]]; then
  fail_metadata 'skill frontmatter'
fi

bundle_ids=""
if ! bundle_ids="$(/usr/bin/ruby -e '
  values = File.readlines(ARGV.fetch(0)).map { |line| line[/\A\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);\s*\z/, 1] }.compact
  abort if values.empty?
  puts values.uniq.sort
' Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj 2>/dev/null)" || \
  [[ "$bundle_ids" != $'com.openai.ap-ios-debug-demo\ncom.openai.ap-ios-debug-demo.tests' ]]; then
  fail_metadata 'Xcode bundle identifier'
fi

validate_scheme() {
  local file="$1" configuration="$2" blueprint="$3"
  /usr/bin/ruby -rrexml/document -rrexml/xpath -e '
    document = REXML::Document.new(File.read(ARGV.fetch(0)))
    launch = REXML::XPath.first(document, "/Scheme/LaunchAction") or abort
    reference = REXML::XPath.first(launch, ".//BuildableReference") or abort
    abort unless launch.attributes["buildConfiguration"] == ARGV.fetch(1)
    abort unless reference.attributes["BlueprintName"] == ARGV.fetch(2)
    abort unless reference.attributes["ReferencedContainer"] == "container:ap-ios-debug-demo.xcodeproj"
  ' "$file" "$configuration" "$blueprint" 2>/dev/null
}
validate_scheme Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo.xcscheme \
  Debug APIOSDebugDemo || fail_metadata 'Debug scheme'
validate_scheme Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/xcshareddata/xcschemes/ap-ios-debug-demo-release.xcscheme \
  Release APIOSDebugDemoRelease || fail_metadata 'Release scheme'

make_values=""
if ! make_values="$(make --no-print-directory print-ap-ios-debug-bin 2>/dev/null)" || \
  [[ "$make_values" != "$root/build/ap-ios-debug" ]]; then
  fail_metadata 'Make AP_IOS_DEBUG_BIN assignment'
fi

readme_heading=""
if ! readme_heading="$(/usr/bin/ruby -e '
  heading = nil
  File.foreach(ARGV.fetch(0)) do |line|
    match = line.match(/\A(\#{1,6})\s+(.+?)\s*\z/)
    if match
      heading = [match[1], match[2]]
      break
    end
  end
  abort unless heading
  puts "#{heading.fetch(0)} #{heading.fetch(1)}"
' README.md 2>/dev/null)" || [[ "$readme_heading" != '# AppPilot' ]]; then
  fail_metadata 'README heading'
fi

filter_exact_lines() {
  local input="$1" output="$2"
  shift 2
  local line exact allowed
  : >"$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    allowed=0
    for exact in "$@"; do
      if [[ "$line" == "$exact" ]]; then allowed=1; break; fi
    done
    if [[ "$allowed" -eq 0 ]]; then printf '%s\n' "$line" >>"$output"; fi
  done <"$input"
}

require_exact_line_once() {
  local file="$1" expected="$2" count
  count="$(awk -v expected="$expected" '$0 == expected { count++ } END { print count + 0 }' "$file")"
  if [[ "$count" -ne 1 ]]; then
    echo "FAIL: expected exactly one installer cleanup mapping: $expected" >&2
    failures=1
  fi
}

installer=scripts/local-install.sh
require_file "$installer"
filter_dir="$(mktemp -d /tmp/ap-ios-name-filter.XXXXXX)"
trap 'rm -rf -- "$filter_dir"' EXIT
if [[ -f "$installer" ]]; then
  filtered_installer="$filter_dir/local-install.sh"
  require_exact_line_once "$installer" 'legacy_binary="$prefix/bin/ios-debug"'
  require_exact_line_once "$installer" 'legacy_package="$prefix/share/ios-debug/IOSDebugKit"'
  require_exact_line_once "$installer" 'legacy_skill="$codex_home/skills/sx-ios-debug"'
  filter_exact_lines "$installer" "$filtered_installer" \
    'legacy_binary="$prefix/bin/ios-debug"' \
    'legacy_package="$prefix/share/ios-debug/IOSDebugKit"' \
    'legacy_skill="$codex_home/skills/sx-ios-debug"'
  scan_file "$filtered_installer"
fi

[[ "$failures" -eq 0 ]] || exit 1
echo 'PASS: ap-ios-name-contract'
