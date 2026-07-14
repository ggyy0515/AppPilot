# App integration

This guide integrates the local `IOSDebugKit` package into an iOS App. Every import, stored runtime value, startup call, state provider, and view modifier that references the package must be compiled only under `#if DEBUG`.

## Add the local package

Add `DebugTools/IOSDebugKit` as a local Swift package. Xcode package product dependencies are target-scoped, not configuration-scoped: add the `IOSDebugKit` product only to a dedicated Debug app target. Keep every Release or production target free of this package dependency. The package supports iOS 16 or newer.

For a project that begins with one App target:

1. In the project editor, duplicate the production App target and rename the copy to identify it as Debug-only.
2. Give that target a Debug-only shared scheme whose Run and Test actions use the Debug configuration. Keep Profile and Archive on the production target's Release scheme.
3. Add `IOSDebugKit` and `DebugTools/IOSDebugBootstrap.swift` only to the Debug target. Remove both from production target membership and dependencies.
4. Keep every host reference under `#if DEBUG`. Build the production target in Release and scan its App plus object files before shipping; `make release-scan` demonstrates the required negative check.

The included DebugDemo uses this topology: `DebugDemo` owns the package for Debug operation, while `DebugDemoRelease` is dependency-free and owns Release/Profile/Archive entry points.

## Start and stop the runtime

Own one runtime for the App lifecycle. The listener binds device loopback on port `9876` by default. The optional bearer token comes only from `IOS_DEBUG_TOKEN`. Do not schedule start and stop together; start at Debug App startup and stop only from the owning coordinator's real shutdown or test-teardown callback.

```swift
#if DEBUG
import IOSDebugKit

@MainActor
final class AppDebugState: DebugStateProvider {
    let model: AppModel
    init(model: AppModel) { self.model = model }
    func debugState() throws -> JSONValue { try .encode(model.debugSnapshot) }
}

@MainActor
final class AppDebugRuntimeOwner {
    private let runtime: IOSDebugRuntime

    init(model: AppModel) throws {
        let configuration = try IOSDebugRuntime.Configuration(
            bearerToken: ProcessInfo.processInfo.environment["IOS_DEBUG_TOKEN"]
        )
        runtime = IOSDebugRuntime(
            configuration: configuration,
            stateProvider: AppDebugState(model: model)
        )
    }

    func start() async throws { try await runtime.start() }
    func stop() async { await runtime.stop() }
}
#endif
```

Store one `AppDebugRuntimeOwner` on the Debug App or its lifecycle coordinator so it remains alive. Call `try await debugRuntime.start()` from the Debug startup task. Later, call `await debugRuntime.stop()` only from that owner's actual shutdown or test teardown; do not put both calls in adjacent unstructured `Task` blocks. `start()` is idempotent while running; `stop()` waits for shutdown and best-effort finalizes an active recording.

## Register actions

Expose only narrow, intentional App operations. Identifiers are stable, non-localized, dot-separated contracts such as `header.settings`; do not derive them from display copy. Registrations follow SwiftUI view lifetime through `DebugActionRegistry.shared`, and disappear when the owning view disappears.

```swift
#if DEBUG
content.iosDebugAction(
    "header.settings",
    role: .navigation,
    description: "Present settings."
) { model.showSettings() }
#else
content
#endif
```

Available roles are `navigation`, `mutation`, and `destructive`. Supply `isEnabled` when availability depends on current App state. The client lists and validates the current registration immediately before activation; a destructive action still requires explicit user approval.

## Provide state

`debugState()` runs on the main actor and must return one complete JSON snapshot, not a partial stream. A Codable snapshot can use `JSONValue.encode`, as above, or `EncodableDebugStateProvider(snapshot:)`. Keep the encoded snapshot under 4 MiB; encoding failure returns `state_encoding_failed` without partial JSON.

Include only diagnostic state the App intentionally exposes. Never place bearer tokens, pairing records, or unrelated user payloads in the snapshot.

## Scaffold

Preview first, then apply:

```bash
ios-debug app scaffold --into "$PWD" --dry-run
ios-debug app scaffold --into "$PWD"
```

The command plans or creates exactly these integration outputs:

- `DebugTools/IOSDebugKit/` — a byte-for-byte package copy.
- `DebugTools/IOSDebugBootstrap.swift` — the canonical Debug-only runtime owner.
- `.ios-debug.toml` — the project-local port and output-directory configuration.

Dry-run reports `create`, `unchanged`, and `conflict` without writing. Apply is idempotent when bytes already match. If any destination differs, it reports all conflicts and changes nothing; there is no force overwrite and it never edits the Xcode project.

Complete these four Xcode steps:

1. Select **File > Add Package Dependencies…**.
2. Click **Add Local…** and choose `<PROJECT_ROOT>/DebugTools/IOSDebugKit`.
3. Add the `IOSDebugKit` product only to a dedicated Debug app target; ensure every Release or production target has no dependency on this package.
4. Add `<PROJECT_ROOT>/DebugTools/IOSDebugBootstrap.swift` only to the Debug target and call `try await IOSDebugBootstrap.start()` from Debug startup code.

Call `await IOSDebugBootstrap.stop()` later, only at the owning shutdown boundary.

Return to the [README](../README.md), or consult [protocol v1](protocol.md) and [troubleshooting](troubleshooting.md).
