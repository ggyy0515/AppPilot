# Protocol v1

The opted-in Debug App serves HTTP/1.1 on device loopback. USB forwarding crosses the paired-Mac trust boundary. Each connection carries exactly one request and one response with `Connection: close`; chunked bodies, compression, connection upgrades, directory paths, queries, and fragments are unsupported.

## Envelopes

Successful JSON responses have one data value and request metadata:

```json
{
  "ok": true,
  "data": {},
  "meta": { "protocol_version": 1, "request_id": "example-request-id" }
}
```

Failures contain a stable code, a safe message, and an actionable hint:

```json
{
  "ok": false,
  "error": {
    "code": "protocol_mismatch",
    "message": "The request is incompatible.",
    "hint": "Use protocol version 1."
  },
  "meta": { "protocol_version": 1, "request_id": "example-request-id" }
}
```

Binary responses provide exact `Content-Length`, `X-IOS-Debug-Protocol-Version`, `X-IOS-Debug-Request-ID`, and `X-IOS-Debug-SHA256` headers. Screenshot responses also report capture method, pixel width, pixel height, and scale.

## Routes

These are the complete eleven canonical method/path pairs. GET resources also accept corresponding HEAD requests with no response body.

| Method and path | Response | Purpose |
| --- | --- | --- |
| `GET /v1/health` | JSON | Service, App, protocol, and authentication status. |
| `GET /v1/capabilities` | JSON | Available capabilities and negotiated limits. |
| `GET /v1/actions` | JSON | Current action descriptors and registration generation. |
| `POST /v1/actions/activate` | JSON | Activate one exact, currently registered identifier. |
| `GET /v1/state` | JSON | Complete App-owned state snapshot. |
| `GET /v1/screenshot` | PNG | Current foreground App window. |
| `GET /v1/recording/status` | JSON | ReplayKit state and elapsed time. |
| `POST /v1/recording/start` | JSON | Start video-only ReplayKit capture. |
| `POST /v1/recording/stop` | JSON | Finalize and return recording metadata. |
| `GET /v1/recordings/{id}` | MP4 | Retryable download of one completed recording. |
| `DELETE /v1/recordings/{id}` | JSON | Delete the verified device-side temporary recording. |

The CLI's high-level action and recording commands alone use the fixed write routes. `request get` and `request head` accept only GET/HEAD-safe, concrete `/v1/` paths and cannot expose POST, PUT, PATCH, or DELETE.

## Authentication

`IOS_DEBUG_TOKEN` is the only token source. When a token is configured, anonymous `GET /v1/health` returns only protocol version, `auth_required: true`, and `reachable: true`; it does not disclose service or App identity. Every other route requires the matching Bearer token. Without a token, health may also identify the service, bundle, and App version because the paired USB host is the trust boundary. Tokens are never accepted from a command flag or TOML and must not appear in logs or artifact metadata.

## Limits and timing

| Boundary | Limit |
| --- | ---: |
| HTTP headers | 32 KiB |
| Request body | 1 MiB |
| State JSON | 4 MiB |
| Screenshot PNG | 25 MiB |
| Recording MP4 | 500 MiB |
| Default recording duration | 120 seconds |
| Maximum configured recording duration | 600 seconds |
| Recording start/permission wait | 60 seconds |
| Recording stop/finalization wait | 90 seconds |

Completed recordings are retained for 30 minutes and at most three ready recordings. A verified CLI download is deleted from the device; failed downloads remain available for retry.

## CLI exit codes

| Exit | Meaning |
| ---: | --- |
| `0` | Success. |
| `2` | Configuration, command input, or required local developer tool. |
| `3` | Device selection, trust, or lock state. |
| `4` | USB/TCP transport, reachability, or timeout. |
| `5` | Protocol, authentication, or App operation. |
| `6` | Local I/O, artifact size, or checksum validation. |

See [App integration](integration.md), [troubleshooting](troubleshooting.md), and the [README](../README.md).
