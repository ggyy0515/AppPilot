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
  rm -rf -- "$path"
}

remove_stage_file() {
  local path="$1"
  [[ -n "$path" && "$path" != / && ! -L "$path" ]] || return 0
  rm -f -- "$path"
}

[[ "$action" = install || "$action" = uninstall ]] || \
  fail "usage: local-install.sh install|uninstall"

prefix="$(require_safe_root PREFIX "$prefix_input")"
codex_home="$(require_safe_root CODEX_HOME "$codex_home_input")"
reject_child_symlinks "$prefix" bin
reject_child_symlinks "$prefix" share ios-debug
reject_child_symlinks "$codex_home" skills

bin_parent="$prefix/bin"
share_root="$prefix/share/ios-debug"
skills_root="$codex_home/skills"
binary_install="$bin_parent/ios-debug"
package_install="$share_root/IOSDebugKit"
skill_install="$skills_root/sx-ios-debug"
reject_symlink "$binary_install"
reject_symlink "$package_install"
reject_symlink "$skill_install"

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

binary_source="${IOS_DEBUG_BIN:-}"
package_source="${PACKAGE_SOURCE:-}"
skill_source="${SKILL_SOURCE:-}"
ditto_bin="${DITTO_BIN:-/usr/bin/ditto}"
[[ -f "$binary_source" && -x "$binary_source" ]] || \
  fail "missing executable IOS_DEBUG_BIN: $binary_source"
[[ -x "$ditto_bin" ]] || fail "missing executable DITTO_BIN: $ditto_bin"
[[ -d "$package_source" ]] || fail "missing PACKAGE_SOURCE: $package_source"
[[ -f "$package_source/Package.swift" || -f "$package_source/Templates/IOSDebugBootstrap.swift" ]] || \
  fail "PACKAGE_SOURCE is not IOSDebugKit: $package_source"
[[ -d "$skill_source" ]] || fail "missing SKILL_SOURCE: $skill_source"
[[ -f "$skill_source/SKILL.md" ]] || fail "missing skill SKILL.md"
[[ -f "$skill_source/agents/openai.yaml" ]] || fail "missing skill agents/openai.yaml"

mkdir -p -- "$bin_parent" "$share_root" "$skills_root"
reject_symlink "$binary_install"
reject_symlink "$package_install"
reject_symlink "$skill_install"
[[ ! -e "$binary_install" || -f "$binary_install" ]] || \
  fail "installed binary path is not a file: $binary_install"
[[ ! -e "$package_install" || -d "$package_install" ]] || \
  fail "installed package path is not a directory: $package_install"
[[ ! -e "$skill_install" || -d "$skill_install" ]] || \
  fail "installed skill path is not a directory: $skill_install"

binary_stage="$(mktemp "$bin_parent/.ios-debug.bin.stage.XXXXXX")"
package_stage="$(mktemp -d "$share_root/.IOSDebugKit.stage.XXXXXX")"
skill_stage="$(mktemp -d "$skills_root/.sx-ios-debug.stage.XXXXXX")"
binary_backup=""
package_backup=""
skill_backup=""
binary_saved=0
package_saved=0
skill_saved=0
binary_placed=0
package_placed=0
skill_placed=0
committed=0

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$committed" -eq 0 ]]; then
    if [[ "$skill_placed" -eq 1 ]]; then remove_stage_dir "$skill_install"; fi
    if [[ "$package_placed" -eq 1 ]]; then remove_stage_dir "$package_install"; fi
    if [[ "$binary_placed" -eq 1 ]]; then remove_stage_file "$binary_install"; fi
    if [[ "$skill_saved" -eq 1 && ! -e "$skill_install" ]]; then mv -- "$skill_backup" "$skill_install"; skill_saved=0; fi
    if [[ "$package_saved" -eq 1 && ! -e "$package_install" ]]; then mv -- "$package_backup" "$package_install"; package_saved=0; fi
    if [[ "$binary_saved" -eq 1 && ! -e "$binary_install" ]]; then mv -- "$binary_backup" "$binary_install"; binary_saved=0; fi
  fi
  remove_stage_file "$binary_stage"
  remove_stage_dir "$package_stage"
  remove_stage_dir "$skill_stage"
  if [[ "$binary_saved" -eq 1 ]]; then remove_stage_file "$binary_backup"; fi
  if [[ "$package_saved" -eq 1 ]]; then remove_stage_dir "$package_backup"; fi
  if [[ "$skill_saved" -eq 1 ]]; then remove_stage_dir "$skill_backup"; fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

install -m 0755 "$binary_source" "$binary_stage"
"$ditto_bin" "$package_source" "$package_stage"
remove_stage_dir "$package_stage/.build"
remove_stage_dir "$package_stage/.swiftpm"
"$ditto_bin" "$skill_source" "$skill_stage"
[[ -f "$skill_stage/SKILL.md" && -f "$skill_stage/agents/openai.yaml" ]] || \
  fail "staged skill is incomplete"

if [[ -e "$binary_install" ]]; then
  binary_backup="$(mktemp "$bin_parent/.ios-debug.bin.backup.XXXXXX")"
  rm -f -- "$binary_backup"
  mv -- "$binary_install" "$binary_backup"
  binary_saved=1
fi
if [[ -e "$package_install" ]]; then
  package_backup="$(mktemp -d "$share_root/.IOSDebugKit.backup.XXXXXX")"
  rmdir "$package_backup"
  mv -- "$package_install" "$package_backup"
  package_saved=1
fi
if [[ -e "$skill_install" ]]; then
  skill_backup="$(mktemp -d "$skills_root/.sx-ios-debug.backup.XXXXXX")"
  rmdir "$skill_backup"
  mv -- "$skill_install" "$skill_backup"
  skill_saved=1
fi

mv -- "$binary_stage" "$binary_install"
binary_stage=""
binary_placed=1
mv -- "$package_stage" "$package_install"
package_stage=""
package_placed=1
mv -- "$skill_stage" "$skill_install"
skill_stage=""
skill_placed=1
committed=1
