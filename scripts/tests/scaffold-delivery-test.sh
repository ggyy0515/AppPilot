#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ap-ios-debug-scaffold-delivery-test.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT

fixture="$work/repository with spaces"
mkdir -p "$fixture/scripts" "$fixture/build" "$work/external"
cp "$root/Makefile" "$fixture/Makefile"
test -f "$root/scripts/clean-build.sh" && cp "$root/scripts/clean-build.sh" "$fixture/scripts/clean-build.sh"
printf 'repo\n' >"$fixture/build/sentinel"
printf 'external\n' >"$work/external/sentinel"

make -C "$fixture" SWIFT=true BUILD_DIR="$work/external" clean
test ! -e "$fixture/build"
test -f "$work/external/sentinel"

fake="$work/failing-ap-ios-debug"
cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":false,"error":"captured-json"}\n'
printf 'captured-stderr token=%s\n' "${AP_IOS_DEBUG_TOKEN-unset}" >&2
exit 9
EOF
chmod +x "$fake"
set +e
diagnostic="$(AP_IOS_DEBUG_BIN="$fake" AP_IOS_DEBUG_TOKEN='must-not-leak' "$root/scripts/scaffold-smoke.sh" 2>&1)"
status=$?
set -e
test "$status" -ne 0
grep -Fq 'captured-json' <<<"$diagnostic"
grep -Fq 'captured-stderr token=unset' <<<"$diagnostic"
if grep -Fq 'must-not-leak' <<<"$diagnostic"; then
  echo "scaffold smoke leaked AP_IOS_DEBUG_TOKEN" >&2
  exit 1
fi

echo "PASS: scaffold-delivery-test"
