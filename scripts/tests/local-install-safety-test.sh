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
    MV_BIN="${MV_BIN:-/bin/mv}" \
    RM_BIN="${RM_BIN:-/bin/rm}" \
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

printf 'legacy-bin\n' >"$prefix/bin/ios-debug"
mkdir -p "$prefix/share/ios-debug/IOSDebugKit" "$codex_home/skills/sx-ios-debug"
printf 'legacy-package\n' >"$prefix/share/ios-debug/IOSDebugKit/version"
printf 'legacy-skill\n' >"$codex_home/skills/sx-ios-debug/version"
export AP_IOS_DEBUG_TEST_FAIL_AFTER_BACKUP=1
if run_installer "$prefix" "$codex_home"; then
  echo 'FAIL: injected post-backup failure was accepted' >&2
  exit 1
fi
unset AP_IOS_DEBUG_TEST_FAIL_AFTER_BACKUP
test "$(cat "$prefix/bin/ap-ios-debug")" = old-binary
test "$(cat "$prefix/share/ap-ios-debug/ap-ios-debug-kit/version")" = old-package
test "$(cat "$codex_home/skills/ap-ios-debug-skill/version")" = old-skill
test "$(cat "$prefix/bin/ios-debug")" = legacy-bin
test "$(cat "$prefix/share/ios-debug/IOSDebugKit/version")" = legacy-package
test "$(cat "$codex_home/skills/sx-ios-debug/version")" = legacy-skill

printf '%s\n' '#!/bin/bash' 'set -eu' \
  'count=0; [[ -f "$MV_COUNT" ]] && count="$(cat "$MV_COUNT")"' \
  'count=$((count + 1)); printf "%s\n" "$count" >"$MV_COUNT"' \
  '/bin/mv "$@"' \
  'if [[ "$count" -eq "$MV_TERM_AFTER" ]]; then kill -TERM "$PPID"; fi' \
  >"$tmp/term-after-mv"
chmod 0755 "$tmp/term-after-mv"

for term_after in 1 2 3 4 5 6 7 8 9; do
  signal_root="$tmp/signal-$term_after"
  signal_prefix="$signal_root/prefix"
  signal_codex="$signal_root/codex"
  mkdir -p "$signal_prefix/bin" \
    "$signal_prefix/share/ap-ios-debug/ap-ios-debug-kit" \
    "$signal_prefix/share/ios-debug/IOSDebugKit" \
    "$signal_codex/skills/ap-ios-debug-skill" \
    "$signal_codex/skills/sx-ios-debug"
  printf 'old-binary-%s\n' "$term_after" >"$signal_prefix/bin/ap-ios-debug"
  printf 'old-package-%s\n' "$term_after" \
    >"$signal_prefix/share/ap-ios-debug/ap-ios-debug-kit/version"
  printf 'old-skill-%s\n' "$term_after" \
    >"$signal_codex/skills/ap-ios-debug-skill/version"
  printf 'legacy-bin-%s\n' "$term_after" >"$signal_prefix/bin/ios-debug"
  printf 'legacy-package-%s\n' "$term_after" \
    >"$signal_prefix/share/ios-debug/IOSDebugKit/version"
  printf 'legacy-skill-%s\n' "$term_after" \
    >"$signal_codex/skills/sx-ios-debug/version"
  export MV_BIN="$tmp/term-after-mv"
  export MV_COUNT="$signal_root/mv-count"
  export MV_TERM_AFTER="$term_after"
  signal_status=0
  run_installer "$signal_prefix" "$signal_codex" || signal_status=$?
  if [[ "$signal_status" -ne 143 ]]; then
    echo "FAIL: TERM after move $term_after returned $signal_status, expected 143" >&2
    exit 1
  fi
  unset MV_BIN MV_COUNT MV_TERM_AFTER
  test "$(cat "$signal_prefix/bin/ap-ios-debug")" = "old-binary-$term_after"
  test "$(cat "$signal_prefix/share/ap-ios-debug/ap-ios-debug-kit/version")" \
    = "old-package-$term_after"
  test "$(cat "$signal_codex/skills/ap-ios-debug-skill/version")" \
    = "old-skill-$term_after"
  test "$(cat "$signal_prefix/bin/ios-debug")" = "legacy-bin-$term_after"
  test "$(cat "$signal_prefix/share/ios-debug/IOSDebugKit/version")" \
    = "legacy-package-$term_after"
  test "$(cat "$signal_codex/skills/sx-ios-debug/version")" \
    = "legacy-skill-$term_after"
  test -z "$(find "$signal_prefix" "$signal_codex" \
    \( -name '*.stage.*' -o -name '*.backup.*' \) -print)"
done

printf '%s\n' '#!/bin/bash' 'set -eu' \
  'for argument in "$@"; do' \
  '  case "$argument" in *.backup.*) echo "injected backup rm failure" >&2; exit 9 ;; esac' \
  'done' \
  'exec /bin/rm "$@"' >"$tmp/failing-backup-rm"
chmod 0755 "$tmp/failing-backup-rm"
cleanup_root="$tmp/post-commit-cleanup"
cleanup_prefix="$cleanup_root/prefix"
cleanup_codex="$cleanup_root/codex"
mkdir -p "$cleanup_prefix/bin" \
  "$cleanup_prefix/share/ap-ios-debug/ap-ios-debug-kit" \
  "$cleanup_prefix/share/ios-debug/IOSDebugKit" \
  "$cleanup_codex/skills/ap-ios-debug-skill" \
  "$cleanup_codex/skills/sx-ios-debug"
printf 'old-binary\n' >"$cleanup_prefix/bin/ap-ios-debug"
printf 'old-package\n' >"$cleanup_prefix/share/ap-ios-debug/ap-ios-debug-kit/version"
printf 'old-skill\n' >"$cleanup_codex/skills/ap-ios-debug-skill/version"
printf 'legacy-bin\n' >"$cleanup_prefix/bin/ios-debug"
printf 'legacy-package\n' >"$cleanup_prefix/share/ios-debug/IOSDebugKit/version"
printf 'legacy-skill\n' >"$cleanup_codex/skills/sx-ios-debug/version"
export RM_BIN="$tmp/failing-backup-rm"
if ! run_installer "$cleanup_prefix" "$cleanup_codex" 2>"$cleanup_root/stderr"; then
  echo 'FAIL: committed install failed when backup cleanup failed' >&2
  exit 1
fi
unset RM_BIN
cmp "$tmp/source/ap-ios-debug" "$cleanup_prefix/bin/ap-ios-debug"
test -f "$cleanup_prefix/share/ap-ios-debug/ap-ios-debug-kit/Templates/APIOSDebugBootstrap.swift"
test -f "$cleanup_codex/skills/ap-ios-debug-skill/SKILL.md"
test ! -e "$cleanup_prefix/bin/ios-debug"
test ! -e "$cleanup_prefix/share/ios-debug/IOSDebugKit"
test ! -e "$cleanup_codex/skills/sx-ios-debug"
test -z "$(find "$cleanup_prefix" "$cleanup_codex" -name '*.stage.*' -print)"
if ! grep -q '^WARNING: unable to remove backup:' "$cleanup_root/stderr"; then
  echo 'FAIL: committed backup cleanup failure was not reported' >&2
  exit 1
fi
test -n "$(find "$cleanup_prefix" "$cleanup_codex" -name '*.backup.*' -print)"

printf 'legacy-bin-sibling\n' >"$prefix/bin/ios-debug-helper"
printf 'legacy-share-sibling\n' >"$prefix/share/ios-debug/unrelated"
printf 'legacy-skill-sibling\n' >"$codex_home/skills/sx-ios-debug-notes"
project="$tmp/Project"
mkdir -p "$project/.ios-debug/artifacts" "$project/.ap-ios-debug/artifacts"
printf 'legacy-user-data\n' >"$project/.ios-debug.toml"
printf 'legacy-artifact\n' >"$project/.ios-debug/artifacts/keep.txt"
printf 'user-data\n' >"$project/.ap-ios-debug.toml"
printf 'artifact\n' >"$project/.ap-ios-debug/artifacts/keep.txt"

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
test ! -e "$prefix/bin/ios-debug"
test ! -e "$prefix/share/ios-debug/IOSDebugKit"
test ! -e "$codex_home/skills/sx-ios-debug"
test -f "$prefix/bin/ios-debug-helper"
test -f "$prefix/share/ios-debug/unrelated"
test -f "$codex_home/skills/sx-ios-debug-notes"
test -f "$project/.ios-debug.toml"
test -f "$project/.ios-debug/artifacts/keep.txt"

printf 'unrelated-bin\n' >"$prefix/bin/unrelated"
printf 'unrelated-share\n' >"$prefix/share/unrelated"
printf 'unrelated-skill\n' >"$codex_home/skills/unrelated"
run_installer "$prefix" "$codex_home" "$tmp/source/skill" uninstall
test ! -e "$prefix/bin/ap-ios-debug"
test ! -e "$prefix/share/ap-ios-debug/ap-ios-debug-kit"
test ! -e "$codex_home/skills/ap-ios-debug-skill"
test -f "$prefix/bin/unrelated"
test -f "$prefix/share/unrelated"
test -f "$codex_home/skills/unrelated"
test -f "$prefix/bin/ios-debug-helper"
test -f "$prefix/share/ios-debug/unrelated"
test -f "$codex_home/skills/sx-ios-debug-notes"
test -f "$project/.ios-debug.toml"
test -f "$project/.ios-debug/artifacts/keep.txt"
test -f "$project/.ap-ios-debug.toml"
test -f "$project/.ap-ios-debug/artifacts/keep.txt"

echo 'PASS: local-install-safety'
