#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
secret='simulator-diagnostic-secret'

# shellcheck source=../secret-scan.sh
source "$root/scripts/secret-scan.sh"
scan_work="$(mktemp -d "${TMPDIR:-/tmp}/ios-debug-secret-scan-test.XXXXXX")"
trap 'rm -rf "$scan_work"' EXIT
mkdir -p "$scan_work/clean" "$scan_work/match"
printf 'ordinary output\n' >"$scan_work/clean/output.txt"
printf 'Authorization: Bearer %s\n' "$secret" >"$scan_work/match/output.txt"

scan_directory_for_secrets "$scan_work/clean" "$scan_work/clean-diagnostic.txt" "$secret"

for scanner_status in 2 127; do
  fake_scanner="$scan_work/grep-$scanner_status"
  printf '#!/usr/bin/env bash\nexit %s\n' "$scanner_status" >"$fake_scanner"
  chmod +x "$fake_scanner"
  set +e
  scanner_output="$(GREP_BIN="$fake_scanner" scan_directory_for_secrets \
    "$scan_work/clean" "$scan_work/scanner-$scanner_status.txt" "$secret" 2>&1)"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Fq "Secret scanner failed with exit $scanner_status" <<<"$scanner_output"
  if grep -Fq 'PASS:' <<<"$scanner_output"; then
    echo "failed secret scanner reported PASS" >&2
    exit 1
  fi
done

set +e
match_output="$(scan_directory_for_secrets \
  "$scan_work/match" "$scan_work/match-diagnostic.txt" "$secret" 2>&1)"
status=$?
set -e
test "$status" -ne 0
grep -Fq '<redacted>' <<<"$match_output"
if grep -Fq "$secret" <<<"$match_output"; then
  echo "secret scanner leaked matched secret" >&2
  exit 1
fi

set +e
diagnostic="$(
  IOS_DEBUG_E2E_SCHEME='IOSDebugMissingScheme' \
  IOS_DEBUG_E2E_TOKEN="$secret" \
  "$root/scripts/simulator-e2e.sh" 2>&1
)"
status=$?
set -e

test "$status" -ne 0
grep -Fq 'FAIL: build DebugDemo' <<<"$diagnostic"
grep -Fq 'IOSDebugMissingScheme' <<<"$diagnostic"
if grep -Fq "$secret" <<<"$diagnostic"; then
  echo "simulator E2E diagnostics leaked IOS_DEBUG_TOKEN" >&2
  exit 1
fi

set +e
diagnostic="$(
  IOS_DEBUG_E2E_PORT=1 \
  IOS_DEBUG_E2E_TOKEN="$secret" \
  "$root/scripts/simulator-e2e.sh" 2>&1
)"
status=$?
set -e

test "$status" -ne 0
grep -Fq 'FAIL: wait for anonymous health probe' <<<"$diagnostic"
grep -Eq '"code":"(app_not_reachable|transport_failure)"' <<<"$diagnostic"
if grep -Fq "$secret" <<<"$diagnostic"; then
  echo "simulator E2E readiness diagnostics leaked IOS_DEBUG_TOKEN" >&2
  exit 1
fi

echo "PASS: simulator-e2e-diagnostics-test"
