#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
input="${SKILL_PATH:-$root/codex/skills/sx-ios-debug}"
grep_bin="${GREP_BIN:-/usr/bin/grep}"
ruby_bin="${RUBY_BIN:-/usr/bin/ruby}"
if [[ -d "$input" ]]; then
  skill="$input/SKILL.md"
  metadata="$input/agents/openai.yaml"
else
  skill="$input"
  metadata="$(dirname "$skill")/agents/openai.yaml"
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_match() {
  local label="$1"
  shift
  local exit_code
  if "$grep_bin" "$@"; then
    return
  else
    exit_code=$?
  fi
  if [[ "$exit_code" -eq 1 ]]; then
    fail "$label"
  fi
  fail "grep failed ($exit_code): $label"
}

reject_match() {
  local label="$1"
  shift
  local exit_code
  if "$grep_bin" "$@"; then
    fail "$label"
  else
    exit_code=$?
  fi
  if [[ "$exit_code" -ne 1 ]]; then
    fail "grep failed ($exit_code): $label"
  fi
}

set_first_line() {
  local text="$1"
  local variable="$2"
  local result
  local exit_code
  if result="$("$grep_bin" -nFm 1 -- "$text" "$skill")"; then
    printf -v "$variable" '%s' "${result%%:*}"
    return
  else
    exit_code=$?
  fi
  if [[ "$exit_code" -eq 1 ]]; then
    fail "cannot locate ordered text: $text"
  fi
  fail "grep failed ($exit_code): cannot locate ordered text: $text"
}

set_match_count() {
  local pattern="$1"
  local variable="$2"
  local result
  local exit_code
  if result="$("$grep_bin" -c -- "$pattern" "$skill")"; then
    printf -v "$variable" '%s' "$result"
    return
  else
    exit_code=$?
  fi
  if [[ "$exit_code" -eq 1 ]]; then
    printf -v "$variable" '0'
    return
  fi
  fail "grep failed ($exit_code): count pattern: $pattern"
}

[[ -x "$grep_bin" ]] || fail "missing executable grep: $grep_bin"
[[ -x "$ruby_bin" ]] || fail "missing executable Ruby YAML parser: $ruby_bin"
[[ -f "$skill" ]] || fail "missing $skill"
[[ -f "$metadata" ]] || fail "missing $metadata"
require_match 'invalid skill name' -Fxq 'name: sx-ios-debug' "$skill"
require_match 'description must define its trigger' -Fq 'description: Use when ' "$skill"

required=(
  'command -v ios-debug'
  'ios-debug --json doctor'
  'ios-debug --json devices list'
  'ios-debug --json app probe'
  'ios-debug --json actions list'
  'ios-debug --json state get'
  'ios-debug --json screenshot capture'
  'ios-debug --json recording status'
  'ios-debug --json recording start'
  'ios-debug --json recording stop'
  'ios-debug --json request get /v1/capabilities'
)
for required_text in "${required[@]}"; do
  require_match "missing required text: $required_text" -Fq "$required_text" "$skill"
done

set_first_line 'command -v ios-debug' installation_line
set_first_line 'ios-debug --json doctor' doctor_line
set_first_line 'ios-debug --json devices list' devices_line
set_first_line 'ios-debug --json app probe' probe_line
set_first_line 'ios-debug --json actions list' actions_line
[[ "$installation_line" -lt "$doctor_line" ]] || fail 'installation check must precede doctor'
[[ "$doctor_line" -lt "$devices_line" ]] || fail 'doctor must precede device discovery'
[[ "$probe_line" -lt "$actions_line" ]] || fail 'app probe must precede action discovery'

require_match 'missing destructive-action approval rule' -Fq 'explicit user approval' "$skill"
require_match 'missing destructive-action mechanical stop' -Fq 'if [[ "$ROLE" == "destructive" ]]; then' "$skill"
require_match 'copyable example may activate destructive actions' -Fq 'Destructive actions are intentionally not activated by this block.' "$skill"
require_match 'missing recording-value rule' -Fq 'only when recording adds diagnostic value' "$skill"
require_match 'missing current-action selection rule' -Fq 'Never invent or reuse a stale identifier' "$skill"
require_match 'missing pipeline failure rule' -Fq 'set -euo pipefail' "$skill"
require_match 'missing recording cleanup rule' -Fq 'best-effort stop' "$skill"
require_match 'missing artifact verification rule' -Fq 'returned local path exists' "$skill"
reject_match 'skill contains a raw write request' -Eqi 'ios-debug .*request (post|put|patch|delete)' "$skill"
set_match_count '^#### Copyable example ' example_count
[[ "$example_count" -eq 3 ]] || fail 'skill must contain exactly three copyable examples'

if ! "$ruby_bin" -e '
  require "yaml"
  root = YAML.safe_load(File.read(ARGV.fetch(0)))
  interface = root.is_a?(Hash) ? root["interface"] : nil
  abort "missing interface" unless interface.is_a?(Hash)
  display = interface["display_name"]
  short = interface["short_description"]
  prompt = interface["default_prompt"]
  abort "invalid display_name" unless display == "sx iOS Debug"
  abort "invalid short_description" unless short.is_a?(String) && (25..64).cover?(short.length)
  abort "invalid default_prompt" unless prompt.is_a?(String) && prompt.include?("$sx-ios-debug")
' "$metadata" >/dev/null 2>&1; then
  fail "invalid skill metadata YAML: $metadata"
fi

reject_match 'skill contains unfinished placeholder text' -Eqi '(TODO|PLACEHOLDER|\[TODO)' "$skill" "$metadata"

echo 'PASS: skill-validation'
