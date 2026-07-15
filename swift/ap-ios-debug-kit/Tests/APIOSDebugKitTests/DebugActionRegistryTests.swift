#if DEBUG && canImport(UIKit)
import Foundation
import Testing
@testable import APIOSDebugKit

@Test @MainActor func registrationSnapshotsAllRolesInIdentifierOrder() throws {
    let registry = DebugActionRegistry()
    _ = try registry.register(identifier: "screen.reload", role: .mutation, description: "Reload") {}
    _ = try registry.register(identifier: "header.settings", role: .navigation, description: "Open settings") {}
    _ = try registry.register(identifier: "account.delete", role: .destructive, description: "Delete account") {}

    let snapshot = registry.snapshot()
    #expect(snapshot.generation == 3)
    #expect(snapshot.actions.map(\.identifier) == ["account.delete", "header.settings", "screen.reload"])
    #expect(snapshot.actions.map(\.role) == [.destructive, .navigation, .mutation])
    #expect(snapshot.actions.map(\.generation) == [3, 2, 1])
}

@Test @MainActor func enabledStateIsEvaluatedAtSnapshotAndAgainAtActivation() async throws {
    let registry = DebugActionRegistry()
    var enabled = false
    var performed = false
    _ = try registry.register(
        identifier: "screen.refresh",
        role: .mutation,
        description: "Refresh",
        isEnabled: { enabled },
        perform: { performed = true }
    )

    #expect(registry.snapshot().actions.first?.isEnabled == false)
    enabled = true
    #expect(registry.snapshot().actions.first?.isEnabled == true)
    enabled = false

    await #expect(throws: ProtocolError.self) {
        try await registry.activate(identifier: "screen.refresh")
    }
    #expect(performed == false)
}

@Test @MainActor func activationRunsCurrentClosureAndReturnsRegistrationGeneration() async throws {
    let registry = DebugActionRegistry()
    var performed = false
    _ = try registry.register(identifier: "screen.refresh", role: .mutation, description: "Refresh") {
        performed = true
    }

    let generation = try await registry.activate(identifier: "screen.refresh")
    #expect(generation == 1)
    #expect(performed)
}

@Test @MainActor func staleTokenCannotRemoveReplacement() async throws {
    let registry = DebugActionRegistry()
    let first = try registry.register(identifier: "header.settings", role: .navigation, description: "Open settings") {}
    let second = try registry.register(identifier: "header.settings", role: .navigation, description: "Open new settings") {}
    registry.unregister(first)
    #expect(registry.snapshot().actions.map(\.description) == ["Open new settings"])
    registry.unregister(second)
    #expect(registry.snapshot().actions.isEmpty)
    #expect(registry.snapshot().generation == 3)
}

@Test @MainActor func missingAndDisabledActionsUseExactCodesAndGenerationHints() async throws {
    let registry = DebugActionRegistry()
    _ = try registry.register(
        identifier: "screen.refresh",
        role: .mutation,
        description: "Refresh",
        isEnabled: { false },
        perform: {}
    )

    do {
        _ = try await registry.activate(identifier: "missing.action")
        Issue.record("Expected missing action to throw")
    } catch let error as ProtocolError {
        #expect(error.code == "action_not_found")
        #expect(error.hint == "Run actions list and retry; latest registration generation is 1.")
    }

    do {
        _ = try await registry.activate(identifier: "screen.refresh")
        Issue.record("Expected disabled action to throw")
    } catch let error as ProtocolError {
        #expect(error.code == "action_disabled")
        #expect(error.hint == "Wait for the App state to enable the action, then list actions again; latest registration generation is 1.")
    }
}

@Test @MainActor func actionFailureDoesNotExposeUnderlyingErrorText() async throws {
    struct SecretFailure: Error, CustomStringConvertible {
        let description = "private failure details"
    }
    let registry = DebugActionRegistry()
    _ = try registry.register(identifier: "screen.refresh", role: .mutation, description: "Refresh") {
        throw SecretFailure()
    }

    do {
        _ = try await registry.activate(identifier: "screen.refresh")
        Issue.record("Expected action closure to throw")
    } catch let error as ProtocolError {
        #expect(error.code == "action_failed")
        #expect(!error.message.contains("private failure details"))
        #expect(!error.hint.contains("private failure details"))
    }
}

@Test @MainActor func invalidIdentifierIsRejected() {
    let registry = DebugActionRegistry()
    #expect(throws: ProtocolError.self) {
        try registry.register(identifier: "settings", role: .navigation, description: "Settings") {}
    }
}
#endif
