---
name: sx-ios-debug
description: Use when diagnosing or operating an explicitly integrated iOS Debug build through the stable ios-debug JSON CLI over paired USB or loopback TCP.
---

# sx-ios-debug

Use this skill only for an App whose developer has integrated `IOSDebugKit`. It is a Debug-build diagnostic surface, not general UI automation.

## Required order

1. Confirm installation with `command -v ios-debug`.
2. Run `ios-debug --json doctor` and resolve every failing prerequisite before operating the App.
3. Run `ios-debug --json devices list`; if a name must be resolved, run `ios-debug --json devices resolve --name '<exact name>'`. Never guess when more than one device is available.
4. Run `ios-debug --json app probe --device "$DEVICE_ID"`.
5. Run `ios-debug --json actions list --device "$DEVICE_ID"` before every action sequence. Prefer `ios-debug --json state get --device "$DEVICE_ID"` or a screenshot for read-only evidence.
6. Select identifiers and roles only from the current actions response. Never invent or reuse a stale identifier. For a mutation, refresh the action list, run `actions activate <identifier> --dry-run`, then activate only when the user's task requires it. A current `destructive` role requires explicit user approval immediately before activation.
7. Use recording only when recording adds diagnostic value. Start it as late as possible, stop it promptly, and make a best-effort stop if a later step fails. Verify that the returned local path exists; verify checksum or mode metadata when returned; report that a sensitive artifact was created.
8. If a high-level command is absent, only use `ios-debug --json request get /v1/capabilities --device "$DEVICE_ID"`. Never construct a raw write request.

Keep JSON stdout machine-readable and treat stderr as diagnostics. Use `set -euo pipefail` in multi-command shell flows; do not let `tee` or another pipeline command mask an `ios-debug` failure. Never print `IOS_DEBUG_TOKEN`, Authorization headers, pairing data, or unrelated App payloads. Do not describe a simulator check as a real-device check.

#### Copyable example 1 — inspect and activate a mutation

```bash
set -euo pipefail
DEVICE_ID='00008110-EXAMPLE'
ios-debug --json app probe --device "$DEVICE_ID"
ios-debug --json actions list --device "$DEVICE_ID"
# Copy the exact enabled identifier and role from the current JSON response.
ACTION_ID='<identifier-from-current-actions-response>'
DRY_RUN_JSON="$(mktemp)"
trap 'rm -f "$DRY_RUN_JSON"' EXIT
ios-debug --json actions activate "$ACTION_ID" --device "$DEVICE_ID" --dry-run >"$DRY_RUN_JSON"
ROLE="$(plutil -extract data.action.role raw -o - "$DRY_RUN_JSON")"
if [[ "$ROLE" == "destructive" ]]; then
  echo 'STOP: obtain explicit user approval, then refresh and dry-run again.' >&2
  exit 2
fi
rm -f "$DRY_RUN_JSON"
trap - EXIT
# Destructive actions are intentionally not activated by this block.
ios-debug --json actions activate "$ACTION_ID" --device "$DEVICE_ID"
ios-debug --json state get --device "$DEVICE_ID"
```

#### Copyable example 2 — capture read-only evidence

```bash
set -euo pipefail
DEVICE_ID='00008110-EXAMPLE'
mkdir -p .ios-debug/artifacts
ios-debug --json state get --device "$DEVICE_ID"
ios-debug --json screenshot capture --device "$DEVICE_ID" --out .ios-debug/artifacts/current.png
test -s .ios-debug/artifacts/current.png
```

#### Copyable example 3 — short diagnostic recording

```bash
set -euo pipefail
DEVICE_ID='00008110-EXAMPLE'
OUT='.ios-debug/artifacts/diagnostic.mp4'
mkdir -p "$(dirname "$OUT")"
recording_started=false
stop_recording() {
  if "$recording_started"; then
    ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT" || true
  fi
}
trap stop_recording EXIT
ios-debug --json recording status --device "$DEVICE_ID"
ios-debug --json recording start --device "$DEVICE_ID"
recording_started=true
# Perform only the short sequence for which video adds diagnostic value.
ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT"
recording_started=false
trap - EXIT
test -s "$OUT"
```

## Failure handling

- `no_device` or `multiple_devices`: list devices and request an exact choice.
- `device_untrusted` or `device_locked`: ask the user to trust or unlock the device; do not retry indefinitely.
- `app_not_reachable`: ask for a launched Debug build with the process running.
- `request_timeout`: mention that a breakpoint can pause the App and ask the user to resume it.
- `protocol_mismatch`: stop and report the CLI/App version mismatch.
- `auth_required` or `auth_failed`: ask the user to set or correct `IOS_DEBUG_TOKEN` without showing its value.
- `action_not_found`: list actions again and use the newly returned generation.
- `action_disabled`: report that the current App state disables it.
- `action_failed`: inspect App state and Debug logs without exposing the closure's internal error text.
- `recording_invalid_state`: query recording status before another recording command.

Report the command that failed, its stable error code, completed evidence, and any cleanup result. Stop rather than improvising an undocumented write path.
