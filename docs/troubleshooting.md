# AppPilot troubleshooting

The JSON error code is stable; use its next action without exposing tokens, pairing data, or unrelated App payloads.

## Error reference

| Code | What it means | Next action |
| --- | --- | --- |
| `config_invalid` | A flag, environment value, or TOML field is invalid. | Correct the named input; token fields are forbidden in TOML. |
| `tool_missing` | A required Xcode developer tool is unavailable. | Install the command-line tools and select the active Xcode. |
| `no_device` | No available physical iOS device was found. | Connect one, unlock it, then run `devices list`. |
| `multiple_devices` | More than one available device matches. | Run `devices list` and select one exact ID. |
| `device_untrusted` | The selected device is not paired with this Mac. | Accept the pairing trust prompt. |
| `device_locked` | The selected device is locked. | Unlock and keep the device awake. |
| `app_not_reachable` | The Debug listener cannot be reached. | Launch a Debug build and keep it foreground/running. |
| `transport_failure` | The USB or loopback TCP connection failed. | Reconnect USB, verify the exact device ID, and retry. |
| `request_timeout` | The App did not answer before the deadline. | Resume the App if it is stopped at a breakpoint. |
| `protocol_mismatch` | The CLI and App disagree on protocol shape or version. | Align CLI and APIOSDebugKit versions. |
| `auth_required` | The App requires a bearer token. | Set `AP_IOS_DEBUG_TOKEN` in the current shell without displaying it. |
| `auth_failed` | The supplied bearer token was rejected. | Correct `AP_IOS_DEBUG_TOKEN` without printing it. |
| `action_not_found` | The action is no longer registered. | List actions again because the generation changed. |
| `action_disabled` | The current App state disables the action. | Inspect state, wait for it to become enabled, and list actions again. |
| `action_failed` | The registered App closure failed. | Inspect state and Debug logs, correct the closure, then retry. |
| `action_requires_confirmation` | A destructive action lacks approval. | Obtain explicit user approval immediately before activation. |
| `state_encoding_failed` | The App could not produce one complete state value. | Fix the provider to return finite JSON under 4 MiB. |
| `screenshot_failed` | The foreground App window could not be captured. | Foreground a window scene and avoid protected or unsupported surfaces. |
| `recording_not_available` | ReplayKit or the requested recording is unavailable. | Keep the App foregrounded, check status, and start a new capture if needed. |
| `recording_invalid_state` | The recording command conflicts with current state. | Run `recording status`, then use the valid next transition. |
| `recording_permission_timeout` | The system recording prompt was not resolved in time. | Respond to the prompt within 60 seconds and retry. |
| `artifact_too_large` | State or a media artifact exceeded its limit. | Reduce state size or capture duration and retry. |
| `artifact_checksum_mismatch` | Downloaded bytes do not match device metadata. | Preserve the device recording for retry and discard the local temp file. |
| `io_failure` | A local artifact could not be safely persisted. | Choose a writable output with enough free space and retry. |

## No device

```bash
ap-ios-debug --json doctor
ap-ios-debug --json devices list
```

Connect a physical device by USB, accept trust, unlock it, and rerun the list. A simulator result is not evidence of a real-device connection.

## Multiple devices

```bash
ap-ios-debug --json devices list
export DEVICE_ID='<copy one exact UDID from the list>'
ap-ios-debug --json app probe --device "$DEVICE_ID"
```

Do not guess a name or identifier. `devices resolve --name` is available only for a non-empty exact device name.

## Locked or untrusted device

Accept the device's trust prompt, unlock it, and keep it awake. Then verify the same exact device:

```bash
ap-ios-debug --json devices list
ap-ios-debug --json app probe --device "$DEVICE_ID"
```

## Wrong token

Set or correct the token in the current shell without echoing it or placing it in TOML, command flags, logs, or artifacts:

```bash
read -r -s AP_IOS_DEBUG_TOKEN
export AP_IOS_DEBUG_TOKEN
ap-ios-debug --json app probe --device "$DEVICE_ID"
```

## Stopped App

Launch an opted-in Debug build and keep it foregrounded. If Xcode is stopped at a breakpoint, resume execution before retrying:

```bash
ap-ios-debug --json app probe --device "$DEVICE_ID"
ap-ios-debug --json state get --device "$DEVICE_ID"
```

## Recording cleanup

Check status before recording and capture only when it adds diagnostic value:

```bash
ap-ios-debug --json recording status --device "$DEVICE_ID"
ap-ios-debug --json recording stop --device "$DEVICE_ID"
```

Run `recording stop` only when the returned state shows an active recording.

`recording stop` finalizes, downloads to a mode-0600 temporary file, validates MP4 structure and SHA-256, atomically installs the artifact, and only then asks the App to delete its device-side copy. On download or checksum failure, the local temporary file is discarded and the completed device recording is preserved for retry. Do not delete the user's artifact directory.

Return to [protocol v1](protocol.md), [App integration](integration.md), or the [README](../README.md).
