# ios-debug

`ios-debug` is a Debug-only iOS diagnostics loop: a Swift package exposes registered App actions, state, screenshot, and ReplayKit recording; one Go binary reaches it over paired USB; `sx-ios-debug` teaches Codex the safe sequence.

## Install

```bash
make verify
make install-local
```

The install owns `~/.local/bin/ios-debug`, `~/.local/share/ios-debug/IOSDebugKit`, and `~/.codex/skills/sx-ios-debug`. Add `~/.local/bin` to `PATH` if `command -v ios-debug` is empty. Remove only these installed copies with `make uninstall-local`.

## Quick start

```bash
ios-debug app scaffold --into "$PWD" --dry-run
ios-debug app scaffold --into "$PWD"
ios-debug --json doctor
ios-debug --json devices list
ios-debug --json app probe --device "$DEVICE_ID"
ios-debug --json actions list --device "$DEVICE_ID"
ios-debug --json state get --device "$DEVICE_ID"
```

Follow [App integration](docs/integration.md), [protocol v1](docs/protocol.md), and [troubleshooting](docs/troubleshooting.md).

## Safety boundary

Release contains no server. The listener is loopback-only, USB uses the paired Mac boundary, raw writes and arbitrary selectors/coordinates/scripts are unavailable, destructive actions require explicit approval, and screenshots/recordings are sensitive mode-0600 artifacts. `IOS_DEBUG_TOKEN` is the only token source.

## Verification

`make verify` runs Go/Swift tests, both App configurations, scaffold, simulator E2E, Release scans, docs, skill, and isolated install smoke. `make device-smoke` prints `SKIP` unless explicitly enabled; a simulator pass is never a device pass.
