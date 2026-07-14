#!/bin/bash
set -euo pipefail

prefix="${PREFIX:?PREFIX is required}"
codex_home="${CODEX_HOME:?CODEX_HOME is required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/ios-debug-installed.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
cd /tmp

export PATH="$prefix/bin:$PATH"
test "$(command -v ios-debug)" = "$prefix/bin/ios-debug"
ios-debug --help >"$tmp/help.txt"
grep -q '^  ios-debug \[command\]$' "$tmp/help.txt"
doctor_status=0
ios-debug --json doctor >"$tmp/doctor.json" || doctor_status=$?
[[ "$doctor_status" -ge 0 && "$doctor_status" -le 6 && "$doctor_status" -ne 1 ]]
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
ios-debug --json app scaffold --into "$tmp/Project" >"$tmp/scaffold.json"
/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$tmp/scaffold.json"
cmp "$prefix/share/ios-debug/IOSDebugKit/Templates/IOSDebugBootstrap.swift" \
  "$tmp/Project/DebugTools/IOSDebugBootstrap.swift"
diff -qr "$prefix/share/ios-debug/IOSDebugKit" \
  "$tmp/Project/DebugTools/IOSDebugKit" >/dev/null
cmp "$root/codex/skills/sx-ios-debug/agents/openai.yaml" \
  "$codex_home/skills/sx-ios-debug/agents/openai.yaml"
SKILL_PATH="$codex_home/skills/sx-ios-debug" "$root/scripts/validate-skill.sh"
SKILL_PATH="$codex_home/skills/sx-ios-debug/SKILL.md" "$root/scripts/validate-skill.sh"
echo "PASS: install-smoke cwd=/tmp"
