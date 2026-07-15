# AppPilot

AppPilot is a Debug-only iOS diagnostics loop. Its `ap-ios-debug` CLI operates an explicitly integrated App through `APIOSDebugKit`, while `ap-ios-debug-skill` teaches Codex the safe sequence.

## Install

```bash
make verify
make install-local
```

The install owns `~/.local/bin/ap-ios-debug`, `~/.local/share/ap-ios-debug/ap-ios-debug-kit`, and `~/.codex/skills/ap-ios-debug-skill`. Add `~/.local/bin` to `PATH` if `command -v ap-ios-debug` is empty. Remove only these installed copies with `make uninstall-local`.

## Quick start

```bash
ap-ios-debug app scaffold --into "$PWD" --dry-run
ap-ios-debug app scaffold --into "$PWD"
ap-ios-debug --json doctor
ap-ios-debug --json devices list
ap-ios-debug --json app probe --device "$DEVICE_ID"
ap-ios-debug --json actions list --device "$DEVICE_ID"
ap-ios-debug --json state get --device "$DEVICE_ID"
```

Follow [App integration](docs/integration.md), [protocol v1](docs/protocol.md), and [troubleshooting](docs/troubleshooting.md).

## Safety boundary

Release contains no server. The listener is loopback-only, USB uses the paired Mac boundary, raw writes and arbitrary selectors/coordinates/scripts are unavailable, destructive actions require explicit approval, and screenshots/recordings are sensitive mode-0600 artifacts. `AP_IOS_DEBUG_TOKEN` is the only token source.

By default, AppPilot stores captures below `.ap-ios-debug/artifacts`; treat that directory as sensitive diagnostic evidence.

## Verification

`make verify` runs Go/Swift tests, both App configurations, scaffold, simulator E2E, Release scans, docs, skill, and isolated install smoke. `make device-smoke` prints `SKIP` unless explicitly enabled; a simulator pass is never a device pass.
