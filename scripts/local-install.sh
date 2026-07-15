#!/bin/bash
set -euo pipefail

action="${1:-}"
prefix_input="${PREFIX:-}"
codex_home_input="${CODEX_HOME:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_safe_root() {
  local label="$1"
  local input="$2"
  local resolved
  [[ -n "$input" ]] || fail "$label must not be empty"
  [[ "$input" = /* ]] || fail "$label must be an absolute path"
  mkdir -p -- "$input"
  resolved="$(cd -P -- "$input" && pwd)"
  [[ "$resolved" != / ]] || fail "$label must not resolve to /"
  printf '%s\n' "$resolved"
}

reject_symlink() {
  local path="$1"
  [[ ! -L "$path" ]] || fail "refusing symlink path: $path"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

reject_child_symlinks() {
  local root="$1"
  shift
  local child="$root"
  local component
  for component in "$@"; do
    child="$child/$component"
    reject_symlink "$child"
  done
}

remove_stage_dir() {
  local path="$1"
  [[ -n "$path" && "$path" != / && ! -L "$path" ]] || return 0
  "$rm_bin" -rf -- "$path"
}

remove_stage_file() {
  local path="$1"
  [[ -n "$path" && "$path" != / && ! -L "$path" ]] || return 0
  "$rm_bin" -f -- "$path"
}

remove_staged_generated_entry() {
  local path="$1"
  [[ -n "$path" && "$path" != / ]] || return 0
  if [[ -L "$path" ]]; then
    "$rm_bin" -f -- "$path"
  elif [[ -e "$path" ]]; then
    "$rm_bin" -rf -- "$path"
  fi
}

[[ "$action" = install || "$action" = uninstall ]] || \
  fail "usage: local-install.sh install|uninstall"

prefix="$(require_safe_root PREFIX "$prefix_input")"
codex_home="$(require_safe_root CODEX_HOME "$codex_home_input")"
reject_child_symlinks "$prefix" bin
reject_child_symlinks "$prefix" share ap-ios-debug
reject_child_symlinks "$codex_home" skills

bin_parent="$prefix/bin"
share_root="$prefix/share/ap-ios-debug"
skills_root="$codex_home/skills"
binary_install="$bin_parent/ap-ios-debug"
package_install="$share_root/ap-ios-debug-kit"
skill_install="$skills_root/ap-ios-debug-skill"
legacy_binary="$prefix/bin/ios-debug"
legacy_package="$prefix/share/ios-debug/IOSDebugKit"
legacy_skill="$codex_home/skills/sx-ios-debug"
reject_symlink "$(dirname "$legacy_package")"
reject_symlink "$binary_install"
reject_symlink "$package_install"
reject_symlink "$skill_install"
reject_symlink "$legacy_binary"
reject_symlink "$legacy_package"
reject_symlink "$legacy_skill"

if [[ "$action" = uninstall ]]; then
  [[ ! -e "$binary_install" || -f "$binary_install" ]] || \
    fail "installed binary path is not a file: $binary_install"
  [[ ! -e "$package_install" || -d "$package_install" ]] || \
    fail "installed package path is not a directory: $package_install"
  [[ ! -e "$skill_install" || -d "$skill_install" ]] || \
    fail "installed skill path is not a directory: $skill_install"
  rm -f -- "$binary_install"
  rm -rf -- "$package_install" "$skill_install"
  exit 0
fi

binary_source="${AP_IOS_DEBUG_BIN:-}"
package_source="${PACKAGE_SOURCE:-}"
skill_source="${SKILL_SOURCE:-}"
ditto_bin="${DITTO_BIN:-/usr/bin/ditto}"
mv_bin="${MV_BIN:-/bin/mv}"
rm_bin="${RM_BIN:-/bin/rm}"
[[ -f "$binary_source" && -x "$binary_source" ]] || \
  fail "missing executable AP_IOS_DEBUG_BIN: $binary_source"
[[ -x "$ditto_bin" ]] || fail "missing executable DITTO_BIN: $ditto_bin"
[[ -x "$mv_bin" ]] || fail "missing executable MV_BIN: $mv_bin"
[[ -x "$rm_bin" ]] || fail "missing executable RM_BIN: $rm_bin"
[[ -d "$package_source" ]] || fail "missing PACKAGE_SOURCE: $package_source"
[[ -f "$package_source/Package.swift" || -f "$package_source/Templates/APIOSDebugBootstrap.swift" ]] || \
  fail "PACKAGE_SOURCE is not APIOSDebugKit: $package_source"
[[ -d "$skill_source" ]] || fail "missing SKILL_SOURCE: $skill_source"
[[ -f "$skill_source/SKILL.md" ]] || fail "missing skill SKILL.md"
[[ -f "$skill_source/agents/openai.yaml" ]] || fail "missing skill agents/openai.yaml"

mkdir -p -- "$bin_parent" "$share_root" "$skills_root"
reject_symlink "$binary_install"
reject_symlink "$package_install"
reject_symlink "$skill_install"
reject_symlink "$legacy_binary"
reject_symlink "$legacy_package"
reject_symlink "$legacy_skill"
[[ ! -e "$binary_install" || -f "$binary_install" ]] || \
  fail "installed binary path is not a file: $binary_install"
[[ ! -e "$package_install" || -d "$package_install" ]] || \
  fail "installed package path is not a directory: $package_install"
[[ ! -e "$skill_install" || -d "$skill_install" ]] || \
  fail "installed skill path is not a directory: $skill_install"
[[ ! -e "$legacy_binary" || -f "$legacy_binary" ]] || \
  fail "legacy binary path is not a file: $legacy_binary"
[[ ! -e "$legacy_package" || -d "$legacy_package" ]] || \
  fail "legacy package path is not a directory: $legacy_package"
[[ ! -e "$legacy_skill" || -d "$legacy_skill" ]] || \
  fail "legacy skill path is not a directory: $legacy_skill"

binary_stage="$(mktemp "$bin_parent/.ap-ios-debug.bin.stage.XXXXXX")"
package_stage="$(mktemp -d "$share_root/.ap-ios-debug-kit.stage.XXXXXX")"
skill_stage="$(mktemp -d "$skills_root/.ap-ios-debug-skill.stage.XXXXXX")"
binary_backup=""
package_backup=""
skill_backup=""
legacy_binary_backup=""
legacy_package_backup=""
legacy_skill_backup=""
binary_backup_intent=0
package_backup_intent=0
skill_backup_intent=0
legacy_binary_backup_intent=0
legacy_package_backup_intent=0
legacy_skill_backup_intent=0
binary_place_intent=0
package_place_intent=0
skill_place_intent=0
committed=0

restore_backup() {
  local backup="$1"
  local destination="$2"
  if path_exists "$backup" && ! path_exists "$destination"; then
    "$mv_bin" -- "$backup" "$destination"
  fi
}

remove_committed_backup_file() {
  local label="$1"
  local path="$2"
  if ! remove_stage_file "$path"; then
    echo "WARNING: unable to remove backup: $label ($path)" >&2
  fi
}

remove_committed_backup_dir() {
  local label="$1"
  local path="$2"
  if ! remove_stage_dir "$path"; then
    echo "WARNING: unable to remove backup: $label ($path)" >&2
  fi
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$committed" -eq 0 ]]; then
    if [[ "$skill_place_intent" -eq 1 ]] && path_exists "$skill_install"; then remove_stage_dir "$skill_install"; fi
    if [[ "$package_place_intent" -eq 1 ]] && path_exists "$package_install"; then remove_stage_dir "$package_install"; fi
    if [[ "$binary_place_intent" -eq 1 ]] && path_exists "$binary_install"; then remove_stage_file "$binary_install"; fi
    if [[ "$skill_backup_intent" -eq 1 ]]; then restore_backup "$skill_backup" "$skill_install"; fi
    if [[ "$package_backup_intent" -eq 1 ]]; then restore_backup "$package_backup" "$package_install"; fi
    if [[ "$binary_backup_intent" -eq 1 ]]; then restore_backup "$binary_backup" "$binary_install"; fi
    if [[ "$legacy_skill_backup_intent" -eq 1 ]]; then restore_backup "$legacy_skill_backup" "$legacy_skill"; fi
    if [[ "$legacy_package_backup_intent" -eq 1 ]]; then restore_backup "$legacy_package_backup" "$legacy_package"; fi
    if [[ "$legacy_binary_backup_intent" -eq 1 ]]; then restore_backup "$legacy_binary_backup" "$legacy_binary"; fi
  fi
  remove_stage_file "$binary_stage"
  remove_stage_dir "$package_stage"
  remove_stage_dir "$skill_stage"
  if [[ "$committed" -eq 1 ]]; then
    remove_committed_backup_file "installed binary" "$binary_backup"
    remove_committed_backup_dir "installed package" "$package_backup"
    remove_committed_backup_dir "installed skill" "$skill_backup"
    remove_committed_backup_file "legacy binary" "$legacy_binary_backup"
    remove_committed_backup_dir "legacy package" "$legacy_package_backup"
    remove_committed_backup_dir "legacy skill" "$legacy_skill_backup"
  else
    if [[ "$binary_backup_intent" -eq 0 ]]; then remove_stage_file "$binary_backup"; fi
    if [[ "$package_backup_intent" -eq 0 ]]; then remove_stage_dir "$package_backup"; fi
    if [[ "$skill_backup_intent" -eq 0 ]]; then remove_stage_dir "$skill_backup"; fi
    if [[ "$legacy_binary_backup_intent" -eq 0 ]]; then remove_stage_file "$legacy_binary_backup"; fi
    if [[ "$legacy_package_backup_intent" -eq 0 ]]; then remove_stage_dir "$legacy_package_backup"; fi
    if [[ "$legacy_skill_backup_intent" -eq 0 ]]; then remove_stage_dir "$legacy_skill_backup"; fi
  fi
  exit "$status"
}

on_signal() {
  local signal="$1"
  exit $((128 + signal))
}

trap cleanup EXIT
trap 'on_signal 1' HUP
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

install -m 0755 "$binary_source" "$binary_stage"
"$ditto_bin" "$package_source" "$package_stage"
remove_staged_generated_entry "$package_stage/.build"
remove_staged_generated_entry "$package_stage/.swiftpm"
"$ditto_bin" "$skill_source" "$skill_stage"
[[ -x "$binary_stage" ]] || fail "staged binary is not executable"
[[ -f "$package_stage/Package.swift" || -f "$package_stage/Templates/APIOSDebugBootstrap.swift" ]] || \
  fail "staged package is incomplete"
[[ -f "$skill_stage/SKILL.md" && -f "$skill_stage/agents/openai.yaml" ]] || \
  fail "staged skill is incomplete"

if [[ -e "$binary_install" ]]; then
  binary_backup="$(mktemp "$bin_parent/.ap-ios-debug.bin.backup.XXXXXX")"
  rm -f -- "$binary_backup"
  binary_backup_intent=1
  "$mv_bin" -- "$binary_install" "$binary_backup"
fi
if [[ -e "$package_install" ]]; then
  package_backup="$(mktemp -d "$share_root/.ap-ios-debug-kit.backup.XXXXXX")"
  rmdir "$package_backup"
  package_backup_intent=1
  "$mv_bin" -- "$package_install" "$package_backup"
fi
if [[ -e "$skill_install" ]]; then
  skill_backup="$(mktemp -d "$skills_root/.ap-ios-debug-skill.backup.XXXXXX")"
  rmdir "$skill_backup"
  skill_backup_intent=1
  "$mv_bin" -- "$skill_install" "$skill_backup"
fi
if [[ -e "$legacy_binary" ]]; then
  legacy_binary_backup="$(mktemp "$bin_parent/.ap-ios-debug.legacy-bin.backup.XXXXXX")"
  rm -f -- "$legacy_binary_backup"
  legacy_binary_backup_intent=1
  "$mv_bin" -- "$legacy_binary" "$legacy_binary_backup"
fi
if [[ -e "$legacy_package" ]]; then
  legacy_package_backup="$(mktemp -d "$share_root/.ap-ios-debug-kit.legacy-package.backup.XXXXXX")"
  rmdir "$legacy_package_backup"
  legacy_package_backup_intent=1
  "$mv_bin" -- "$legacy_package" "$legacy_package_backup"
fi
if [[ -e "$legacy_skill" ]]; then
  legacy_skill_backup="$(mktemp -d "$skills_root/.ap-ios-debug-skill.legacy-skill.backup.XXXXXX")"
  rmdir "$legacy_skill_backup"
  legacy_skill_backup_intent=1
  "$mv_bin" -- "$legacy_skill" "$legacy_skill_backup"
fi

if [[ "${AP_IOS_DEBUG_TEST_FAIL_AFTER_BACKUP:-0}" = 1 ]]; then
  fail "injected failure after backup"
fi

binary_place_intent=1
"$mv_bin" -- "$binary_stage" "$binary_install"
package_place_intent=1
"$mv_bin" -- "$package_stage" "$package_install"
skill_place_intent=1
"$mv_bin" -- "$skill_stage" "$skill_install"
committed=1
