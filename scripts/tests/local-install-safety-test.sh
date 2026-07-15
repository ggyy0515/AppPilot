#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
installer="$root/scripts/local-install.sh"
tmp="$(mktemp -d /tmp/ap-ios-debug-install-safety.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/source/package/Templates" "$tmp/source/skill/agents"
mkdir -p "$tmp/outside-build" "$tmp/outside-swiftpm"
printf '#!/bin/sh\necho test-binary\n' >"$tmp/source/ap-ios-debug"
chmod 0755 "$tmp/source/ap-ios-debug"
printf 'bootstrap\n' >"$tmp/source/package/Templates/APIOSDebugBootstrap.swift"
printf 'build-sentinel\n' >"$tmp/outside-build/keep.txt"
printf 'swiftpm-sentinel\n' >"$tmp/outside-swiftpm/keep.txt"
ln -s "$tmp/outside-build" "$tmp/source/package/.build"
ln -s "$tmp/outside-swiftpm" "$tmp/source/package/.swiftpm"
printf '%s\n' '---' 'name: ap-ios-debug-skill' 'description: Use when testing.' >"$tmp/source/skill/SKILL.md"
printf '%s\n' 'interface:' '  display_name: "sx iOS Debug"' >"$tmp/source/skill/agents/openai.yaml"

run_installer() {
  PREFIX="$1" CODEX_HOME="$2" \
    AP_IOS_DEBUG_BIN="$tmp/source/ap-ios-debug" \
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
mkdir -p "$prefix/share/ap-ios-debug" "$outside"
printf 'outside\n' >"$outside/keep.txt"
ln -s "$outside" "$prefix/share/ap-ios-debug/ap-ios-debug-kit"
if run_installer "$prefix" "$codex_home"; then
  echo 'FAIL: symlink package target was accepted' >&2
  exit 1
fi
test "$(cat "$outside/keep.txt")" = outside
rm "$prefix/share/ap-ios-debug/ap-ios-debug-kit"

mkdir -p "$prefix/bin" "$prefix/share/ap-ios-debug/ap-ios-debug-kit" \
  "$codex_home/skills/ap-ios-debug-skill"
printf 'old-binary\n' >"$prefix/bin/ap-ios-debug"
printf 'old-package\n' >"$prefix/share/ap-ios-debug/ap-ios-debug-kit/version"
printf 'old-skill\n' >"$codex_home/skills/ap-ios-debug-skill/version"
if run_installer "$prefix" "$codex_home" "$tmp/source/missing-skill"; then
  echo 'FAIL: missing skill source was accepted' >&2
  exit 1
fi
test "$(cat "$prefix/bin/ap-ios-debug")" = old-binary
test "$(cat "$prefix/share/ap-ios-debug/ap-ios-debug-kit/version")" = old-package
test "$(cat "$codex_home/skills/ap-ios-debug-skill/version")" = old-skill

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
test "$(cat "$prefix/bin/ap-ios-debug")" = old-binary
test "$(cat "$prefix/share/ap-ios-debug/ap-ios-debug-kit/version")" = old-package
test "$(cat "$codex_home/skills/ap-ios-debug-skill/version")" = old-skill

run_installer "$prefix" "$codex_home"
cmp "$tmp/source/ap-ios-debug" "$prefix/bin/ap-ios-debug"
cmp "$tmp/source/package/Templates/APIOSDebugBootstrap.swift" \
  "$prefix/share/ap-ios-debug/ap-ios-debug-kit/Templates/APIOSDebugBootstrap.swift"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.build"
test ! -L "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.build"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.swiftpm"
test ! -L "$prefix/share/ap-ios-debug/ap-ios-debug-kit/.swiftpm"
test "$(cat "$tmp/outside-build/keep.txt")" = build-sentinel
test "$(cat "$tmp/outside-swiftpm/keep.txt")" = swiftpm-sentinel
cmp "$tmp/source/skill/SKILL.md" "$codex_home/skills/ap-ios-debug-skill/SKILL.md"
cmp "$tmp/source/skill/agents/openai.yaml" \
  "$codex_home/skills/ap-ios-debug-skill/agents/openai.yaml"

printf 'unrelated-bin\n' >"$prefix/bin/unrelated"
printf 'unrelated-share\n' >"$prefix/share/unrelated"
printf 'unrelated-skill\n' >"$codex_home/skills/unrelated"
project="$tmp/Project"
mkdir -p "$project/.ap-ios-debug/artifacts"
printf 'user-data\n' >"$project/.ap-ios-debug.toml"
printf 'artifact\n' >"$project/.ap-ios-debug/artifacts/keep.txt"
run_installer "$prefix" "$codex_home" "$tmp/source/skill" uninstall
test ! -e "$prefix/bin/ap-ios-debug"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit"
test ! -e "$codex_home/skills/ap-ios-debug-skill"
test -f "$prefix/bin/unrelated"
test -f "$prefix/share/unrelated"
test -f "$codex_home/skills/unrelated"
test -f "$project/.ap-ios-debug.toml"
test -f "$project/.ap-ios-debug/artifacts/keep.txt"

echo 'PASS: local-install-safety'
