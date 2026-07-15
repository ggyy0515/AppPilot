#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$root/scripts/check-docs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$checker" >/dev/null

fake_grep="$tmp/grep-error"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'if [[ "${1:-}" == "-Fq" || "${1:-}" == "-Fxq" ]]; then exit 2; fi' \
    'exec /usr/bin/grep "$@"'
} >"$fake_grep"
chmod +x "$fake_grep"

if GREP_BIN="$fake_grep" "$checker" >"$tmp/output" 2>&1; then
  echo 'FAIL: docs checker ignored injected grep failure' >&2
  exit 1
fi
grep -Fq 'grep failed while checking README.md (status 2)' "$tmp/output"
if grep -Fq 'PASS: docs-check' "$tmp/output"; then
  echo 'FAIL: docs checker printed PASS after grep failure' >&2
  exit 1
fi

fake_find="$tmp/find-error"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' 'exit 2'
} >"$fake_find"
chmod +x "$fake_find"

if FIND_BIN="$fake_find" "$checker" >"$tmp/find-output" 2>&1; then
  echo 'FAIL: docs checker ignored injected find failure' >&2
  exit 1
fi
grep -Fq 'find failed while enumerating Markdown docs (status 2)' "$tmp/find-output"
if grep -Fq 'PASS: docs-check' "$tmp/find-output"; then
  echo 'FAIL: docs checker printed PASS after find failure' >&2
  exit 1
fi

fake_git="$tmp/git-error"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'for argument in "$@"; do' \
    '  if [[ "$argument" == check-ignore ]]; then exit 2; fi' \
    'done' \
    'exec /usr/bin/git "$@"'
} >"$fake_git"
chmod +x "$fake_git"

if GIT_BIN="$fake_git" "$checker" >"$tmp/git-output" 2>&1; then
  echo 'FAIL: docs checker ignored injected git failure' >&2
  exit 1
fi
grep -Fq 'git check-ignore failed while validating PDF ignore semantics (status 2)' "$tmp/git-output"
if grep -Fq 'PASS: docs-check' "$tmp/git-output"; then
  echo 'FAIL: docs checker printed PASS after git failure' >&2
  exit 1
fi

copy_fixture() {
  local destination="$1"
  mkdir -p "$destination"
  cp "$root/README.md" "$destination/README.md"
  cp "$root/AGENTS.md" "$destination/AGENTS.md"
  cp "$root/.gitignore" "$destination/.gitignore"
  cp -R "$root/docs" "$destination/docs"
}

spaced_fixture="$tmp/fixture 路径 with space"
copy_fixture "$spaced_fixture"
AP_IOS_DOC_ROOT="$spaced_fixture" "$checker" >/dev/null

extract_recording_block() {
  local marker="$1"
  local destination="$2"
  /usr/bin/awk -v marker="$marker" '
    $0 == marker { found = 1; next }
    found && !inside && $0 == "```bash" { inside = 1; next }
    inside && $0 == "```" { exit }
    inside { print }
  ' "$root/README.md" >"$destination"
  test -s "$destination"
}

recording_stub_bin="$tmp/recording-stub-bin"
mkdir -p "$recording_stub_bin"
fake_ap="$recording_stub_bin/ap-ios-debug"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'case " $* " in' \
    '  *" recording status "*)' \
    '    count=0' \
    '    if [[ -f "$AP_STUB_STATE" ]]; then IFS= read -r count <"$AP_STUB_STATE"; fi' \
    '    count=$((count + 1))' \
    '    printf "%s\\n" "$count" >"$AP_STUB_STATE"' \
    '    case "$count" in 1) state=idle ;; 2) state=starting ;; 3) state=recording ;; *) state=ready ;; esac' \
    '    printf "%s\\n" "$state" >"$AP_STUB_CURRENT"' \
    '    printf "status:%s\\n" "$state" >>"$AP_STUB_LOG"' \
    '    printf "{\\"data\\":{\\"state\\":\\"%s\\"}}\\n" "$state"' \
    '    ;;' \
    '  *" recording start "*) printf "%s\\n" start >>"$AP_STUB_LOG"; exit 7 ;;' \
    '  *" recording stop "*) printf "%s\\n" stop >>"$AP_STUB_LOG" ;;' \
    '  *) exit 2 ;;' \
    'esac'
} >"$fake_ap"
chmod +x "$fake_ap"

fake_plutil="$recording_stub_bin/plutil"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'IFS= read -r state <"$AP_STUB_CURRENT"' \
    'printf "%s\\n" "$state"'
} >"$fake_plutil"
chmod +x "$fake_plutil"

fake_sleep="$recording_stub_bin/sleep"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' 'printf "sleep:%s\\n" "$1" >>"$AP_STUB_LOG"'
} >"$fake_sleep"
chmod +x "$fake_sleep"

run_recording_cleanup_stub() {
  local label="$1"
  local block="$2"
  local state_file="$tmp/$label-state"
  local current_file="$tmp/$label-current"
  local log_file="$tmp/$label-log"
  local output_file="$tmp/$label-output"
  local artifact_dir="$tmp/$label-artifacts"
  local result=0
  local actual
  local expected=$'status:idle\nstart\nstatus:starting\nsleep:1\nstatus:recording\nstop'

  mkdir -p "$artifact_dir"
  : >"$log_file"
  if PATH="$recording_stub_bin:$PATH" \
      AP_STUB_STATE="$state_file" \
      AP_STUB_CURRENT="$current_file" \
      AP_STUB_LOG="$log_file" \
      DEVICE_ID='stub-device' \
      ARTIFACT_DIR="$artifact_dir" \
      /bin/bash "$block" >"$output_file" 2>&1; then
    result=0
  else
    result=$?
  fi
  if [[ "$result" -ne 7 ]]; then
    echo "FAIL: $label recording cleanup masked start status 7 as $result" >&2
    /usr/bin/sed -n '1,80p' "$output_file" >&2
    exit 1
  fi
  actual="$(<"$log_file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label recording cleanup did not poll starting to recording before stop" >&2
    /usr/bin/sed -n '1,80p' "$log_file" >&2
    exit 1
  fi
}

english_recording_block="$tmp/english-recording-block.sh"
chinese_recording_block="$tmp/chinese-recording-block.sh"
extract_recording_block 'Use a short recording in the same unique run directory only when motion or timing matters:' "$english_recording_block"
extract_recording_block '只有在动画或时序确实需要时，才在同一个唯一运行目录中使用短录屏：' "$chinese_recording_block"
run_recording_cleanup_stub english "$english_recording_block"
run_recording_cleanup_stub chinese "$chinese_recording_block"
echo 'PASS: recording cleanup stubs'

exact_grep="$tmp/grep-exact-error"
{
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'if [[ "${1:-}" == "-Fxq" && "${4:-}" == */.gitignore ]]; then exit 2; fi' \
    'exec /usr/bin/grep "$@"'
} >"$exact_grep"
chmod +x "$exact_grep"

exact_grep_fixture="$tmp/exact-grep-fixture"
copy_fixture "$exact_grep_fixture"
if GREP_BIN="$exact_grep" AP_IOS_DOC_ROOT="$exact_grep_fixture" "$checker" >"$tmp/exact-output" 2>&1; then
  echo 'FAIL: docs checker ignored injected exact-line grep failure' >&2
  exit 1
fi
grep -Fq 'grep failed while checking .gitignore (status 2)' "$tmp/exact-output"
if grep -Fq 'PASS: docs-check' "$tmp/exact-output"; then
  echo 'FAIL: docs checker printed PASS after exact-line grep failure' >&2
  exit 1
fi

expect_contract_failure() {
  local fixture="$1"
  local expected="$2"
  if AP_IOS_DOC_ROOT="$fixture" "$checker" >"$tmp/contract-output" 2>&1; then
    echo "FAIL: docs checker accepted missing contract: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/contract-output"
}

missing_chinese="$tmp/missing-chinese"
copy_fixture "$missing_chinese"
sed -i '' 's/\[中文\](#readme-中文)//' "$missing_chinese/README.md"
expect_contract_failure "$missing_chinese" "missing '[中文](#readme-中文)' in README.md"

missing_agents="$tmp/missing-agents"
copy_fixture "$missing_agents"
rm "$missing_agents/AGENTS.md"
expect_contract_failure "$missing_agents" 'missing or empty AGENTS.md'

missing_ignore="$tmp/missing-ignore"
copy_fixture "$missing_ignore"
sed -i '' \
  's|^/我 vibe coding 了一个 iOS 调试工具，让 Claude Code 自己去操作 App\.pdf$|/我 vibe coding 了一个 iOS 调试工具，让 Claude Code 自己去操作 App.pdf.backup|' \
  "$missing_ignore/.gitignore"
expect_contract_failure "$missing_ignore" "missing '/我 vibe coding 了一个 iOS 调试工具，让 Claude Code 自己去操作 App.pdf' in .gitignore"

duplicate_anchor="$tmp/duplicate-anchor"
copy_fixture "$duplicate_anchor"
printf '%s\n' '<a id="readme-english"></a>' >>"$duplicate_anchor/README.md"
expect_contract_failure "$duplicate_anchor" "expected exactly one semantic anchor id 'readme-english' in README.md"

indented_duplicate_anchor="$tmp/indented-duplicate-anchor"
copy_fixture "$indented_duplicate_anchor"
printf '%s\n' '  <a id = "readme-english"></a>' >>"$indented_duplicate_anchor/README.md"
expect_contract_failure "$indented_duplicate_anchor" "expected exactly one semantic anchor id 'readme-english' in README.md"

data_id_attribute="$tmp/data-id-attribute"
copy_fixture "$data_id_attribute"
printf '%s\n' '<a data-id = "readme-english"></a>' >>"$data_id_attribute/README.md"
AP_IOS_DOC_ROOT="$data_id_attribute" "$checker" >/dev/null

attribute_value_id="$tmp/attribute-value-id"
copy_fixture "$attribute_value_id"
printf '%s\n' '<a title='"'"'literal id="readme-english" text'"'"'></a>' >>"$attribute_value_id/README.md"
AP_IOS_DOC_ROOT="$attribute_value_id" "$checker" >/dev/null

fenced_anchor_example="$tmp/fenced-anchor-example"
copy_fixture "$fenced_anchor_example"
printf '\n%s\n%s\n%s\n' '```html' '<a id="readme-english"></a>' '```' >>"$fenced_anchor_example/README.md"
AP_IOS_DOC_ROOT="$fenced_anchor_example" "$checker" >/dev/null

commented_anchor_example="$tmp/commented-anchor-example"
copy_fixture "$commented_anchor_example"
printf '%s\n' '<!-- <a id="readme-english"></a> -->' >>"$commented_anchor_example/README.md"
AP_IOS_DOC_ROOT="$commented_anchor_example" "$checker" >/dev/null

uppercase_anchor="$tmp/uppercase-anchor"
copy_fixture "$uppercase_anchor"
printf '%s\n' '<A ID="readme-english"></A>' >>"$uppercase_anchor/README.md"
expect_contract_failure "$uppercase_anchor" "expected exactly one semantic anchor id 'readme-english' in README.md"

unquoted_anchor="$tmp/unquoted-anchor"
copy_fixture "$unquoted_anchor"
printf '%s\n' '<a id=readme-english></a>' >>"$unquoted_anchor/README.md"
expect_contract_failure "$unquoted_anchor" "expected exactly one semantic anchor id 'readme-english' in README.md"

multiline_anchor="$tmp/multiline-anchor"
copy_fixture "$multiline_anchor"
printf '%s\n' '<a' '  class="duplicate"' '  id = "readme-english"' '></a>' >>"$multiline_anchor/README.md"
expect_contract_failure "$multiline_anchor" "expected exactly one semantic anchor id 'readme-english' in README.md"

noncanonical_primary_anchor="$tmp/noncanonical-primary-anchor"
copy_fixture "$noncanonical_primary_anchor"
sed -i '' 's/^<a id="readme-english"><\/a>$/<A ID=readme-english><\/A>/' "$noncanonical_primary_anchor/README.md"
expect_contract_failure "$noncanonical_primary_anchor" "expected exactly one '<a id=\"readme-english\"></a>' in README.md"

moved_english_anchor="$tmp/moved-english-anchor"
copy_fixture "$moved_english_anchor"
sed -i '' '5d' "$moved_english_anchor/README.md"
sed -i '' '8i\
<a id="readme-english"></a>
' "$moved_english_anchor/README.md"
expect_contract_failure "$moved_english_anchor" 'README English anchor must be exact line 5'

wrong_english_heading="$tmp/wrong-english-heading"
copy_fixture "$wrong_english_heading"
sed -i '' 's/^## English$/### English/' "$wrong_english_heading/README.md"
expect_contract_failure "$wrong_english_heading" "expected exactly one '## English' in README.md"

misplaced_navigation="$tmp/misplaced-navigation"
copy_fixture "$misplaced_navigation"
sed -i '' '3d' "$misplaced_navigation/README.md"
printf '\n%s\n' '[English](#readme-english) | [中文](#readme-中文)' >>"$misplaced_navigation/README.md"
expect_contract_failure "$misplaced_navigation" 'README navigation must be exact line 3'

expect_pdf_failure() {
  local fixture_name="$1"
  local rule="$2"
  local expected="$3"
  local fixture="$tmp/$fixture_name"
  copy_fixture "$fixture"
  printf '%s\n' "$rule" >>"$fixture/.gitignore"
  expect_contract_failure "$fixture" "$expected"
}

positive_pdf_error='positive PDF ignore rule is forbidden in .gitignore:'
semantic_pdf_error='PDF ignore rule must not ignore non-target PDF:'
expect_pdf_failure broad-pdf-double-star '**.pdf' "$positive_pdf_error"
expect_pdf_failure broad-pdf-trailing-space '*.pdf ' "$positive_pdf_error"
expect_pdf_failure broad-pdf-uppercase '*.PDF' "$positive_pdf_error"
expect_pdf_failure broad-pdf-character-class '*.[pP][dD][fF]' "$semantic_pdf_error"
expect_pdf_failure broad-pdf-nested-name '我 vibe coding 了一个 iOS 调试工具，让 Claude Code 自己去操作 App.pdf' "$positive_pdf_error"
expect_pdf_failure broad-pdf-docs-tree 'docs/**/*.pdf' "$positive_pdf_error"

target_negation="$tmp/target-negation"
copy_fixture "$target_negation"
printf '%s\n' '!/我 vibe coding 了一个 iOS 调试工具，让 Claude Code 自己去操作 App.pdf' >>"$target_negation/.gitignore"
expect_contract_failure "$target_negation" 'exact root PDF target is not ignored by .gitignore:'

unrelated_negation="$tmp/unrelated-negation"
copy_fixture "$unrelated_negation"
printf '%s\n' '!/other.pdf' >>"$unrelated_negation/.gitignore"
AP_IOS_DOC_ROOT="$unrelated_negation" "$checker" >/dev/null

commented_pdf_rule="$tmp/commented-pdf-rule"
copy_fixture "$commented_pdf_rule"
printf '%s\n' '# docs/**/*.pdf' >>"$commented_pdf_rule/.gitignore"
AP_IOS_DOC_ROOT="$commented_pdf_rule" "$checker" >/dev/null

missing_canonical_section="$tmp/missing-canonical-section"
copy_fixture "$missing_canonical_section"
sed -i '' '/^## Canonical names$/,/^## Repository layout$/d' "$missing_canonical_section/AGENTS.md"
expect_contract_failure "$missing_canonical_section" "expected exactly one '## Canonical names' in AGENTS.md"

moved_canonical_name="$tmp/moved-canonical-name"
copy_fixture "$moved_canonical_name"
sed -i '' '/^- Product: AppPilot$/d' "$moved_canonical_name/AGENTS.md"
printf '%s\n' '- Product: AppPilot' >>"$moved_canonical_name/AGENTS.md"
expect_contract_failure "$moved_canonical_name" "canonical name line must appear in AGENTS.md section '## Canonical names': - Product: AppPilot"

missing_destructive_policy="$tmp/missing-destructive-policy"
copy_fixture "$missing_destructive_policy"
sed -i '' '/^- Agents MUST obtain explicit user approval immediately before activating an action whose current role is `destructive`;/d' "$missing_destructive_policy/AGENTS.md"
expect_contract_failure "$missing_destructive_policy" 'missing exact destructive approval policy in AGENTS.md'

missing_request_id="$tmp/missing-request-id"
copy_fixture "$missing_request_id"
sed -i '' 's/X-IOS-Debug-Request-ID/X-IOS-Debug-Request-ID-BROKEN/' "$missing_request_id/AGENTS.md"
expect_contract_failure "$missing_request_id" 'missing exact protocol invariant in AGENTS.md'

missing_sha="$tmp/missing-sha"
copy_fixture "$missing_sha"
sed -i '' 's/X-IOS-Debug-SHA256/X-IOS-Debug-SHA256-BROKEN/' "$missing_sha/AGENTS.md"
expect_contract_failure "$missing_sha" 'missing exact protocol invariant in AGENTS.md'

legacy_name="$tmp/legacy-name"
copy_fixture "$legacy_name"
printf '%s%s\n' 'sx-ios' '-debug' >>"$legacy_name/AGENTS.md"
expect_contract_failure "$legacy_name" 'legacy canonical name scan failed'

echo 'PASS: check-docs fixtures'
