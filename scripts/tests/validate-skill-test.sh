#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
validator="$root/scripts/validate-skill.sh"
source_skill="$root/codex/skills/sx-ios-debug"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_expect_failure() {
  local label="$1"
  shift
  local output="$tmp/$label.out"
  if "$@" >"$output" 2>&1; then
    echo "FAIL: $label unexpectedly passed" >&2
    exit 1
  fi
  if grep -Fq 'PASS: skill-validation' "$output"; then
    echo "FAIL: $label printed PASS" >&2
    exit 1
  fi
}

SKILL_PATH="$source_skill" "$validator" >/dev/null
SKILL_PATH="$source_skill/SKILL.md" "$validator" >/dev/null

grep -Fq 'Destructive actions are intentionally not activated by this block.' \
  "$source_skill/SKILL.md"
grep -Fq 'if [[ "$ROLE" == "destructive" ]]; then' "$source_skill/SKILL.md"

awk '
  /^#### Copyable example 1 / { example = 1; next }
  example && /^```bash$/ { block = 1; next }
  block && /^```$/ { exit }
  block { print }
' "$source_skill/SKILL.md" >"$tmp/example-1.sh"
chmod +x "$tmp/example-1.sh"
mkdir "$tmp/fake-bin"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'case " $* " in' \
    '  *" actions activate "*" --dry-run "*)' \
    "    printf '%s\\n' '{\"data\":{\"action\":{\"role\":\"destructive\"}}}'" \
    '    ;;' \
    '  *" actions activate "*)' \
    '    : >"$ACTIVATION_MARKER"' \
    "    printf '%s\\n' '{\"ok\":true}'" \
    '    ;;' \
    '  *)' \
    "    printf '%s\\n' '{\"ok\":true}'" \
    '    ;;' \
    'esac'
} >"$tmp/fake-bin/ios-debug"
chmod +x "$tmp/fake-bin/ios-debug"
set +e
PATH="$tmp/fake-bin:$PATH" ACTIVATION_MARKER="$tmp/activated" \
  "$tmp/example-1.sh" >"$tmp/example-1.out" 2>"$tmp/example-1.err"
example_status=$?
set -e
[[ "$example_status" -eq 2 ]]
[[ ! -e "$tmp/activated" ]]
grep -Fq 'STOP: obtain explicit user approval' "$tmp/example-1.err"

cp -R "$source_skill" "$tmp/invalid-yaml"
printf 'broken: [\n' >>"$tmp/invalid-yaml/agents/openai.yaml"
run_expect_failure invalid_yaml env SKILL_PATH="$tmp/invalid-yaml" "$validator"

make_failing_grep() {
  local path="$1"
  local rejected="$2"
  local required_first="${3:-}"
  {
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
    printf 'rejected=%q\n' "$rejected"
    printf 'required_first=%q\n' "$required_first"
    printf '%s\n' \
      'if [[ -z "$required_first" || "${1:-}" == "$required_first" ]]; then' \
      '  for argument in "$@"; do' \
      '    if [[ "$argument" == "$rejected" ]]; then exit 2; fi' \
      '  done' \
      'fi' \
      'exec /usr/bin/grep "$@"'
  } >"$path"
  chmod +x "$path"
}

make_failing_grep "$tmp/grep-raw-error" 'ios-debug .*request (post|put|patch|delete)'
run_expect_failure grep_raw_error env GREP_BIN="$tmp/grep-raw-error" SKILL_PATH="$source_skill" "$validator"
grep -Fq 'grep failed (2)' "$tmp/grep_raw_error.out"

make_failing_grep "$tmp/grep-placeholder-error" '(TODO|PLACEHOLDER|\[TODO)'
run_expect_failure grep_placeholder_error env GREP_BIN="$tmp/grep-placeholder-error" SKILL_PATH="$source_skill" "$validator"
grep -Fq 'grep failed (2)' "$tmp/grep_placeholder_error.out"

make_failing_grep "$tmp/grep-line-error" 'command -v ios-debug' '-nFm'
run_expect_failure grep_line_error env GREP_BIN="$tmp/grep-line-error" SKILL_PATH="$source_skill" "$validator"
grep -Fq 'grep failed (2)' "$tmp/grep_line_error.out"

make_failing_grep "$tmp/grep-count-error" '^#### Copyable example ' '-c'
run_expect_failure grep_count_error env GREP_BIN="$tmp/grep-count-error" SKILL_PATH="$source_skill" "$validator"
grep -Fq 'grep failed (2)' "$tmp/grep_count_error.out"

echo 'PASS: validate-skill fixtures'
