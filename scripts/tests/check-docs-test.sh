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
    'if [[ "${1:-}" == "-Fq" ]]; then exit 2; fi' \
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

echo 'PASS: check-docs fixtures'
