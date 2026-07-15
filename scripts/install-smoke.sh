#!/bin/bash
set -euo pipefail

prefix="${PREFIX:?PREFIX is required}"
codex_home="${CODEX_HOME:?CODEX_HOME is required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/ap-ios-debug-installed.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
cd /tmp

export PATH="$prefix/bin:$PATH"
test "$(command -v ap-ios-debug)" = "$prefix/bin/ap-ios-debug"
! command -v ios-debug >/dev/null 2>&1
ap-ios-debug --help >"$tmp/help.txt"
grep -q '^  ap-ios-debug \[command\]$' "$tmp/help.txt"
test -f "$codex_home/skills/ap-ios-debug-skill/agents/openai.yaml"
test -f "$prefix/share/ap-ios-debug/ap-ios-debug-kit/Package.swift"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.build"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.swiftpm"
doctor_status=0
ap-ios-debug --json doctor >"$tmp/doctor.json" || doctor_status=$?
case "$doctor_status" in
  0|2|3|4|5|6) ;;
  *) exit 1 ;;
esac
/usr/bin/ruby -rjson -e '
  document = JSON.parse(File.read(ARGV.fetch(0)))
  abort "doctor envelope is not successful" unless document["ok"] == true
  data = document["data"]
  abort "doctor data is missing" unless data.is_a?(Hash)
  checks = data["checks"]
  abort "doctor checks are missing" unless checks.is_a?(Array)
  statuses = checks.to_h { |check| [check["name"], check["status"]] }
  %w[template path].each do |name|
    abort "doctor #{name} check did not pass" unless statuses[name] == "pass"
  end
' "$tmp/doctor.json"

mkdir -p "$tmp/Project"
ap-ios-debug --json app scaffold --into "$tmp/Project" >"$tmp/scaffold.json"
/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$tmp/scaffold.json"
cmp "$prefix/share/ap-ios-debug/ap-ios-debug-kit/Templates/APIOSDebugBootstrap.swift" \
  "$tmp/Project/DebugTools/APIOSDebugBootstrap.swift"
diff -qr "$prefix/share/ap-ios-debug/ap-ios-debug-kit" \
  "$tmp/Project/DebugTools/ap-ios-debug-kit" >/dev/null
cmp "$root/codex/skills/ap-ios-debug-skill/agents/openai.yaml" \
  "$codex_home/skills/ap-ios-debug-skill/agents/openai.yaml"
SKILL_PATH="$codex_home/skills/ap-ios-debug-skill" "$root/scripts/validate-skill.sh"
SKILL_PATH="$codex_home/skills/ap-ios-debug-skill/SKILL.md" "$root/scripts/validate-skill.sh"
echo "PASS: install-smoke cwd=/tmp"
