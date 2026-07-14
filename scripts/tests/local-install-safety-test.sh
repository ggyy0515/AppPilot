#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
installer="$root/scripts/local-install.sh"
tmp="$(mktemp -d /tmp/ios-debug-install-safety.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/source/package/Templates" "$tmp/source/skill/agents"
printf '#!/bin/sh\necho test-binary\n' >"$tmp/source/ios-debug"
chmod 0755 "$tmp/source/ios-debug"
printf 'bootstrap\n' >"$tmp/source/package/Templates/IOSDebugBootstrap.swift"
printf '%s\n' '---' 'name: sx-ios-debug' 'description: Use when testing.' >"$tmp/source/skill/SKILL.md"
printf '%s\n' 'interface:' '  display_name: "sx iOS Debug"' >"$tmp/source/skill/agents/openai.yaml"

run_installer() {
  PREFIX="$1" CODEX_HOME="$2" \
    IOS_DEBUG_BIN="$tmp/source/ios-debug" \
    PACKAGE_SOURCE="$tmp/source/package" \
    SKILL_SOURCE="${3:-$tmp/source/skill}" \
    DITTO_BIN="${DITTO_BIN:-/usr/bin/ditto}" \
    "$installer" "${4:-install}"
}

if run_installer / "$tmp/codex"; then
  echo 'FAIL: root PREFIX was accepted' >&2
  exit 1
fi
if run_installer "$tmp/prefix" /; then
  echo 'FAIL: root CODEX_HOME was accepted' >&2
  exit 1
fi

prefix="$tmp/prefix"
codex_home="$tmp/codex"
outside="$tmp/outside-package"
mkdir -p "$prefix/share/ios-debug" "$outside"
printf 'outside\n' >"$outside/keep.txt"
ln -s "$outside" "$prefix/share/ios-debug/IOSDebugKit"
if run_installer "$prefix" "$codex_home"; then
  echo 'FAIL: symlink package target was accepted' >&2
  exit 1
fi
test "$(cat "$outside/keep.txt")" = outside
rm "$prefix/share/ios-debug/IOSDebugKit"

mkdir -p "$prefix/bin" "$prefix/share/ios-debug/IOSDebugKit" \
  "$codex_home/skills/sx-ios-debug"
printf 'old-binary\n' >"$prefix/bin/ios-debug"
printf 'old-package\n' >"$prefix/share/ios-debug/IOSDebugKit/version"
printf 'old-skill\n' >"$codex_home/skills/sx-ios-debug/version"
if run_installer "$prefix" "$codex_home" "$tmp/source/missing-skill"; then
  echo 'FAIL: missing skill source was accepted' >&2
  exit 1
fi
test "$(cat "$prefix/bin/ios-debug")" = old-binary
test "$(cat "$prefix/share/ios-debug/IOSDebugKit/version")" = old-package
test "$(cat "$codex_home/skills/sx-ios-debug/version")" = old-skill

printf '%s\n' '#!/bin/bash' \
  'count=0; [[ -f "$DITTO_COUNT" ]] && count="$(cat "$DITTO_COUNT")"' \
  'count=$((count + 1)); printf "%s\n" "$count" >"$DITTO_COUNT"' \
  '[[ "$count" -lt 2 ]] || exit 9' \
  'exec /usr/bin/ditto "$@"' >"$tmp/failing-ditto"
chmod 0755 "$tmp/failing-ditto"
export DITTO_COUNT="$tmp/ditto-count"
DITTO_BIN="$tmp/failing-ditto"
if run_installer "$prefix" "$codex_home"; then
  echo 'FAIL: skill copy failure was accepted' >&2
  exit 1
fi
unset DITTO_BIN DITTO_COUNT
test "$(cat "$prefix/bin/ios-debug")" = old-binary
test "$(cat "$prefix/share/ios-debug/IOSDebugKit/version")" = old-package
test "$(cat "$codex_home/skills/sx-ios-debug/version")" = old-skill

run_installer "$prefix" "$codex_home"
cmp "$tmp/source/ios-debug" "$prefix/bin/ios-debug"
cmp "$tmp/source/package/Templates/IOSDebugBootstrap.swift" \
  "$prefix/share/ios-debug/IOSDebugKit/Templates/IOSDebugBootstrap.swift"
cmp "$tmp/source/skill/SKILL.md" "$codex_home/skills/sx-ios-debug/SKILL.md"
cmp "$tmp/source/skill/agents/openai.yaml" \
  "$codex_home/skills/sx-ios-debug/agents/openai.yaml"

printf 'unrelated-bin\n' >"$prefix/bin/unrelated"
printf 'unrelated-share\n' >"$prefix/share/unrelated"
printf 'unrelated-skill\n' >"$codex_home/skills/unrelated"
project="$tmp/Project"
mkdir -p "$project/.ios-debug/artifacts"
printf 'user-data\n' >"$project/.ios-debug.toml"
printf 'artifact\n' >"$project/.ios-debug/artifacts/keep.txt"
run_installer "$prefix" "$codex_home" "$tmp/source/skill" uninstall
test ! -e "$prefix/bin/ios-debug"
test ! -e "$prefix/share/ios-debug/IOSDebugKit"
test ! -e "$codex_home/skills/sx-ios-debug"
test -f "$prefix/bin/unrelated"
test -f "$prefix/share/unrelated"
test -f "$codex_home/skills/unrelated"
test -f "$project/.ios-debug.toml"
test -f "$project/.ios-debug/artifacts/keep.txt"

echo 'PASS: local-install-safety'
