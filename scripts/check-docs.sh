#!/bin/bash
set -euo pipefail

default_root="$(cd "$(dirname "$0")/.." && pwd)"
root="${AP_IOS_DOC_ROOT:-$default_root}"
root="$(cd "$root" && pwd -P)"
grep_bin="${GREP_BIN:-/usr/bin/grep}"
find_bin="${FIND_BIN:-/usr/bin/find}"
files=(README.md AGENTS.md .gitignore docs/integration.md docs/protocol.md docs/troubleshooting.md)
legacy_scan_files=("$root/README.md" "$root/AGENTS.md")
find_output=''

cleanup() {
    if [[ -n "$find_output" ]]; then
        rm -f -- "$find_output"
    fi
}
trap cleanup EXIT

require_fixed() {
    local pattern="$1"
    local file="$2"
    local status

    if "$grep_bin" -Fq -- "$pattern" "$file"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        echo "FAIL: missing '$pattern' in ${file#"$root/"}" >&2
    else
        echo "FAIL: grep failed while checking ${file#"$root/"} (status $status)" >&2
    fi
    exit 1
}

require_exact_line() {
    local pattern="$1"
    local file="$2"
    local status

    if "$grep_bin" -Fxq -- "$pattern" "$file"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        echo "FAIL: missing '$pattern' in ${file#"$root/"}" >&2
    else
        echo "FAIL: grep failed while checking ${file#"$root/"} (status $status)" >&2
    fi
    exit 1
}

require_exact_count() {
    local pattern="$1"
    local file="$2"
    local count

    if ! count="$(/usr/bin/awk -v pattern="$pattern" \
        '$0 == pattern { count++ } END { print count + 0 }' "$file")"; then
        echo "FAIL: unable to count exact lines in ${file#"$root/"}" >&2
        exit 1
    fi
    if [[ "$count" -ne 1 ]]; then
        echo "FAIL: expected exactly one '$pattern' in ${file#"$root/"}" >&2
        exit 1
    fi
}

semantic_anchor_line() {
    local id="$1"
    local file="$2"
    local summary
    local count
    local line

    if ! summary="$(
        /usr/bin/ruby - "$id" "$file" <<'RUBY'
target_id = ARGV.fetch(0)
source = File.read(ARGV.fetch(1))
visible = String.new
fence_character = nil
fence_length = 0

source.each_line do |source_line|
  if fence_character
    closing = Regexp.new("\\A {0,3}" + Regexp.escape(fence_character) +
                         "{#{fence_length},}[ \\t]*(?:\\r?\\n)?\\z")
    if source_line.match?(closing)
      fence_character = nil
      fence_length = 0
    end
    visible << (source_line.end_with?("\n") ? "\n" : "")
    next
  end

  opening = source_line.match(/\A {0,3}(\x60{3,}|~{3,})/)
  if opening
    fence_character = opening[1][0]
    fence_length = opening[1].length
    visible << (source_line.end_with?("\n") ? "\n" : "")
  else
    visible << source_line
  end
end

visible.gsub!(/<!--.*?-->/m) { |comment| "\n" * comment.count("\n") }

anchor_open = /<a(?=[\s>\/])/i
index = 0
count = 0
line = 0

while (tag_start = visible.index(anchor_open, index))
  cursor = tag_start + 2
  quote = nil
  tag_end = nil
  while cursor < visible.length
    character = visible[cursor]
    if quote
      quote = nil if character == quote
    elsif character == '"' || character == "'"
      quote = character
    elsif character == ">"
      tag_end = cursor
      break
    end
    cursor += 1
  end
  break unless tag_end

  attributes = visible[(tag_start + 2)...tag_end]
  position = 0
  while position < attributes.length
    position += 1 while position < attributes.length &&
      (attributes[position].match?(/\s/) || attributes[position] == "/")
    break if position >= attributes.length

    name_start = position
    position += 1 while position < attributes.length &&
      !attributes[position].match?(/[\s=\/>]/)
    name = attributes[name_start...position]
    if name.empty?
      position += 1
      next
    end

    position += 1 while position < attributes.length && attributes[position].match?(/\s/)
    value = nil
    if position < attributes.length && attributes[position] == "="
      position += 1
      position += 1 while position < attributes.length && attributes[position].match?(/\s/)
      if position < attributes.length && ['"', "'"].include?(attributes[position])
        value_quote = attributes[position]
        position += 1
        value_start = position
        position += 1 while position < attributes.length && attributes[position] != value_quote
        value = attributes[value_start...position]
        position += 1 if position < attributes.length
      else
        value_start = position
        position += 1 while position < attributes.length && !attributes[position].match?(/\s/)
        value = attributes[value_start...position]
      end
    end

    if name.downcase == "id" && value == target_id
      count += 1
      line = visible[0...tag_start].count("\n") + 1
    end
  end
  index = tag_end + 1
end

puts "#{count}:#{line}"
RUBY
    )"; then
        echo "FAIL: unable to inspect semantic anchors in ${file#"$root/"}" >&2
        exit 1
    fi
    count="${summary%%:*}"
    line="${summary#*:}"
    if [[ "$count" -ne 1 ]]; then
        echo "FAIL: expected exactly one semantic anchor id '$id' in ${file#"$root/"}" >&2
        exit 1
    fi
    printf '%s\n' "$line"
}

exact_line_number() {
    local pattern="$1"
    local file="$2"

    /usr/bin/awk -v pattern="$pattern" '$0 == pattern { print NR; exit }' "$file"
}

require_anchor_heading_adjacency() {
    local label="$1"
    local anchor_line="$2"
    local heading_line="$3"
    local file="$4"
    local gap=$((heading_line - anchor_line))

    if [[ "$gap" -eq 1 ]]; then
        return 0
    fi
    if [[ "$gap" -eq 2 ]] && [[ -z "$(/usr/bin/awk -v line="$((anchor_line + 1))" 'NR == line { print; exit }' "$file")" ]]; then
        return 0
    fi
    echo "FAIL: README $label anchor must immediately precede its heading with at most one blank line" >&2
    exit 1
}

require_exact_line_in_section() {
    local required="$1"
    local section="$2"
    local file="$3"
    local status=0

    if /usr/bin/awk -v required="$required" -v section="$section" '
        $0 == section { inside = 1; next }
        inside && /^## / { exit }
        inside && $0 == required { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$file"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        echo "FAIL: canonical name line must appear in AGENTS.md section '$section': $required" >&2
    else
        echo "FAIL: awk failed while checking AGENTS.md canonical names (status $status)" >&2
    fi
    exit 1
}

reject_fixed() {
    local pattern="$1"
    local file="$2"
    local status

    if "$grep_bin" -Fq -- "$pattern" "$file"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        return 1
    fi
    echo "FAIL: grep failed while checking forbidden content in ${file#"$root/"} (status $status)" >&2
    exit 2
}

reject_extended() {
    local pattern="$1"
    shift
    local status

    if "$grep_bin" -REq -- "$pattern" "$@"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        return 1
    fi
    echo "FAIL: grep failed while checking forbidden documentation content (status $status)" >&2
    exit 2
}

if [[ ! -x "$grep_bin" ]]; then
    echo "FAIL: missing executable grep: $grep_bin" >&2
    exit 1
fi
if [[ ! -x "$find_bin" ]]; then
    echo "FAIL: missing executable find: $find_bin" >&2
    exit 1
fi
find_output="$(mktemp "${TMPDIR:-/tmp}/ap-ios-docs-find.XXXXXX")"
find_status=0
"$find_bin" "$root/docs" -type f -name '*.md' -print0 >"$find_output" || find_status=$?
if [[ "$find_status" -ne 0 ]]; then
    echo "FAIL: find failed while enumerating Markdown docs (status $find_status)" >&2
    exit 1
fi
while IFS= read -r -d '' file; do
    legacy_scan_files+=("$file")
done <"$find_output"

for file in "${files[@]}"; do
    if [[ ! -s "$root/$file" ]]; then
        echo "FAIL: missing or empty $file" >&2
        exit 1
    fi
done

navigation='[English](#readme-english) | [中文](#readme-中文)'
require_fixed '[English](#readme-english)' "$root/README.md"
require_fixed '[中文](#readme-中文)' "$root/README.md"
require_exact_count "$navigation" "$root/README.md"
if [[ "$(/usr/bin/awk 'NR == 3 { print; exit }' "$root/README.md")" != "$navigation" ]]; then
    echo 'FAIL: README navigation must be exact line 3' >&2
    exit 1
fi
require_exact_count '## English' "$root/README.md"
require_exact_count '## 中文' "$root/README.md"
english_anchor_line="$(semantic_anchor_line 'readme-english' "$root/README.md")"
chinese_anchor_line="$(semantic_anchor_line 'readme-中文' "$root/README.md")"
english_heading_line="$(exact_line_number '## English' "$root/README.md")"
chinese_heading_line="$(exact_line_number '## 中文' "$root/README.md")"
english_anchor_literal='<a id="readme-english"></a>'
chinese_anchor_literal='<a id="readme-中文"></a>'
if [[ "$(/usr/bin/awk -v line="$english_anchor_line" 'NR == line { print; exit }' "$root/README.md")" != "$english_anchor_literal" ]]; then
    echo "FAIL: expected exactly one '$english_anchor_literal' in README.md" >&2
    exit 1
fi
if [[ "$(/usr/bin/awk -v line="$chinese_anchor_line" 'NR == line { print; exit }' "$root/README.md")" != "$chinese_anchor_literal" ]]; then
    echo "FAIL: expected exactly one '$chinese_anchor_literal' in README.md" >&2
    exit 1
fi
if [[ "$english_anchor_line" -ne 5 ]]; then
    echo 'FAIL: README English anchor must be exact line 5' >&2
    exit 1
fi
require_anchor_heading_adjacency 'English' "$english_anchor_line" "$english_heading_line" "$root/README.md"
require_anchor_heading_adjacency 'Chinese' "$chinese_anchor_line" "$chinese_heading_line" "$root/README.md"

for heading in '### Install' '### Quick start' '### Safety boundary' '### Verification'; do
    require_exact_line "$heading" "$root/README.md"
done
for heading in '### 安装' '### 快速开始' '### 安全边界' '### 验证'; do
    require_exact_line "$heading" "$root/README.md"
done
for required_text in \
    'Agent-assisted development loop' \
    '当前限制'; do
    require_fixed "$required_text" "$root/README.md"
done

for required_text in \
    '# AGENTS.md' \
    'make clean && make verify' \
    'AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1'; do
    require_fixed "$required_text" "$root/AGENTS.md"
done
require_exact_count '## Canonical names' "$root/AGENTS.md"
for canonical_name in \
    '- Product: AppPilot' \
    '- CLI: `ap-ios-debug`' \
    '- Codex skill: `ap-ios-debug-skill`' \
    '- Swift package directory and package name: `ap-ios-debug-kit`' \
    '- Swift modules and branded entry types use `APIOS*`; generic supporting public types keep role names.' \
    '- Demo filesystem names and schemes: `ap-ios-debug-demo*`' \
    '- Configuration and artifacts: `.ap-ios-debug.toml` and `.ap-ios-debug/`' \
    '- Environment variables: `AP_IOS_DEBUG_*`' \
    '- Go module: `github.com/ggyy0515/AppPilot`'; do
    require_exact_line_in_section "$canonical_name" '## Canonical names' "$root/AGENTS.md"
done
destructive_policy='- Agents MUST obtain explicit user approval immediately before activating an action whose current role is `destructive`; this is an agent policy, not a CLI-enforced authorization check.'
destructive_status=0
if "$grep_bin" -Fxq -- "$destructive_policy" "$root/AGENTS.md"; then
    :
else
    destructive_status=$?
    if [[ "$destructive_status" -eq 1 ]]; then
        echo 'FAIL: missing exact destructive approval policy in AGENTS.md' >&2
    else
        echo "FAIL: grep failed while checking destructive approval policy in AGENTS.md (status $destructive_status)" >&2
    fi
    exit 1
fi
protocol_invariant='- Protocol routes, JSON envelopes, error codes, and the `X-IOS-Debug-Protocol-Version`, `X-IOS-Debug-Request-ID`, and `X-IOS-Debug-SHA256` headers are frozen unless the protocol version is intentionally changed with compatibility tests and documentation.'
protocol_status=0
if "$grep_bin" -Fxq -- "$protocol_invariant" "$root/AGENTS.md"; then
    :
else
    protocol_status=$?
    if [[ "$protocol_status" -eq 1 ]]; then
        echo 'FAIL: missing exact protocol invariant in AGENTS.md' >&2
    else
        echo "FAIL: grep failed while checking exact protocol invariant in AGENTS.md (status $protocol_status)" >&2
    fi
    exit 1
fi
for protocol_header in \
    'X-IOS-Debug-Protocol-Version' \
    'X-IOS-Debug-Request-ID' \
    'X-IOS-Debug-SHA256'; do
    require_fixed "$protocol_header" "$root/AGENTS.md"
done

name_checker="$default_root/scripts/check-ap-ios-names.sh"
if [[ ! -x "$name_checker" ]]; then
    echo "FAIL: missing executable canonical name checker: $name_checker" >&2
    exit 1
fi
if ! "$name_checker" --scan-only "${legacy_scan_files[@]}" >/dev/null; then
    echo 'FAIL: legacy canonical name scan failed' >&2
    exit 1
fi

require_fixed '# AppPilot' "$root/README.md"
require_fixed '# AppPilot' "$root/docs/integration.md"
require_fixed '# AppPilot' "$root/docs/protocol.md"
require_fixed '# AppPilot' "$root/docs/troubleshooting.md"
require_fixed 'command -v ap-ios-debug' "$root/README.md"
require_fixed 'ap-ios-debug --json doctor' "$root/README.md"
require_fixed '.ap-ios-debug/artifacts' "$root/README.md"
require_fixed 'APIOSDebugKit' "$root/README.md"
require_fixed 'APIOSDebugBootstrap' "$root/docs/integration.md"
for heading in '## Add the local package' '## Start and stop the runtime' '## Register actions' '## Provide state' '## Scaffold'; do
    require_fixed "$heading" "$root/docs/integration.md"
done
require_fixed 'package product dependencies are target-scoped, not configuration-scoped' "$root/docs/integration.md"
require_fixed 'dedicated Debug app target' "$root/docs/integration.md"
require_fixed 'duplicate the production App target' "$root/docs/integration.md"
require_fixed 'Keep Profile and Archive on the production target' "$root/docs/integration.md"
require_fixed 'Do not schedule start and stop together' "$root/docs/integration.md"
require_fixed 'only protocol version, `auth_required: true`, and `reachable: true`' "$root/docs/protocol.md"
for route in /v1/health /v1/capabilities /v1/actions /v1/state /v1/screenshot /v1/recording/status /v1/recording/start /v1/recording/stop '/v1/recordings/{id}'; do
    require_fixed "$route" "$root/docs/protocol.md"
done
for code in config_invalid tool_missing no_device multiple_devices device_untrusted device_locked app_not_reachable transport_failure request_timeout protocol_mismatch auth_required auth_failed action_not_found action_disabled action_failed action_requires_confirmation state_encoding_failed screenshot_failed recording_not_available recording_invalid_state recording_permission_timeout artifact_too_large artifact_checksum_mismatch io_failure; do
    require_fixed "$code" "$root/docs/troubleshooting.md"
done
for command in 'make install-local' 'make uninstall-local' 'make verify' 'make device-smoke'; do
    require_fixed "$command" "$root/README.md"
done
for link in '[App integration](docs/integration.md)' '[protocol v1](docs/protocol.md)' '[troubleshooting](docs/troubleshooting.md)'; do
    require_fixed "$link" "$root/README.md"
done
for file in docs/integration.md docs/protocol.md docs/troubleshooting.md; do
    require_fixed '(../README.md)' "$root/$file"
done
require_fixed '(protocol.md)' "$root/docs/integration.md"
require_fixed '(troubleshooting.md)' "$root/docs/integration.md"
require_fixed '(integration.md)' "$root/docs/protocol.md"
require_fixed '(troubleshooting.md)' "$root/docs/protocol.md"
require_fixed '(integration.md)' "$root/docs/troubleshooting.md"
require_fixed '(protocol.md)' "$root/docs/troubleshooting.md"
for route in \
    'GET /v1/health' 'GET /v1/capabilities' 'GET /v1/actions' \
    'POST /v1/actions/activate' 'GET /v1/state' 'GET /v1/screenshot' \
    'GET /v1/recording/status' 'POST /v1/recording/start' \
    'POST /v1/recording/stop' 'GET /v1/recordings/{id}' \
    'DELETE /v1/recordings/{id}'; do
    require_fixed "$route" "$root/docs/protocol.md"
done
if reject_extended 'ap-ios-debug .*request (post|put|patch|delete)' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose a raw write request" >&2
    exit 1
fi
if reject_extended 'ap-ios-debug .*--token|^[[:space:]]*token[[:space:]]*=' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose an unsupported token source" >&2
    exit 1
fi
if reject_extended 'product only to (the )?.*Debug configuration' "$root/docs/integration.md"; then
    echo "FAIL: docs prescribe unsupported configuration-scoped package linking" >&2
    exit 1
fi
echo "PASS: docs-check"
