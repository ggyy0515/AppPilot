#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import IOSDebugKit

private final class ActionState {
    var isEnabled = false
    var performCount = 0
    var performedOnMainActor = false
}

private struct MarkedActionView: View {
    let identifier: String
    let role: DebugActionRole
    let actionDescription: String
    let state: ActionState

    var body: some View {
        Text(identifier)
            .iosDebugAction(
                identifier,
                role: role,
                description: actionDescription,
                isEnabled: { state.isEnabled },
                perform: {
                    MainActor.preconditionIsolated()
                    state.performCount += 1
                    state.performedOnMainActor = true
                }
            )
    }
}

@MainActor
private final class HostedActionView {
    private let window: UIWindow
    private let controller: UIHostingController<MarkedActionView>

    init(view: MarkedActionView) {
        controller = UIHostingController(rootView: view)
        window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
    }

    func update(_ view: MarkedActionView) {
        controller.rootView = view
    }

    func disappear() {
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    condition: () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(description)")
}

@Suite(.serialized)
struct DebugActionModifierTests {
    @Test @MainActor func contractIdentityChangeInSameHostUsesFreshGeneration() async throws {
        let registry = DebugActionRegistry.shared
        let identifier = "modifier.identity.\(UUID().uuidString)"
        let firstState = ActionState()
        let replacementState = ActionState()
        let host = HostedActionView(
            view: MarkedActionView(
                identifier: identifier,
                role: .navigation,
                actionDescription: "First contract",
                state: firstState
            ))
        await waitUntil("first contract registration") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) != nil
        }
        let firstGeneration = try #require(
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation
        )

        host.update(
            MarkedActionView(
                identifier: identifier,
                role: .destructive,
                actionDescription: "Replacement contract",
                state: replacementState
            ))
        await waitUntil("replacement contract registration") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.description == "Replacement contract"
        }
        let replacementGeneration = try #require(
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation
        )
        #expect(replacementGeneration != firstGeneration)

        // Give the old lifecycle's delayed teardown a chance to run. It must not
        // remove the freshly registered replacement.
        await Task.yield()
        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation == replacementGeneration)

        replacementState.isEnabled = true
        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.isEnabled == true)
        _ = try await registry.activate(identifier: identifier)
        #expect(replacementState.performCount == 1)
        #expect(replacementState.performedOnMainActor)

        host.disappear()
        await waitUntil("replacement contract teardown") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) == nil
        }
    }

    @Test @MainActor func actionLifecycleUsesTokenSpecificTeardown() async throws {
        let registry = DebugActionRegistry.shared
        let identifier = "modifier.lifecycle.\(UUID().uuidString)"
        let firstState = ActionState()
        let secondState = ActionState()
        let first = HostedActionView(
            view: MarkedActionView(
                identifier: identifier,
                role: .navigation,
                actionDescription: "First action",
                state: firstState
            ))
        await waitUntil("first registration") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) != nil
        }
        let firstGeneration = try #require(
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation
        )

        first.update(
            MarkedActionView(
                identifier: identifier,
                role: .navigation,
                actionDescription: "First action",
                state: firstState
            ))
        await Task.yield()
        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation == firstGeneration)

        let replacement = HostedActionView(
            view: MarkedActionView(
                identifier: identifier,
                role: .destructive,
                actionDescription: "Replacement action",
                state: secondState
            ))
        await waitUntil("replacement registration") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.description == "Replacement action"
        }
        let replacementGeneration = try #require(
            registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation
        )

        first.disappear()
        await Task.yield()
        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.generation == replacementGeneration)

        replacement.disappear()
        await waitUntil("replacement teardown") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) == nil
        }
    }

    @Test @MainActor func enabledAndPerformClosuresRemainDynamicAndMainActorIsolated() async throws {
        let registry = DebugActionRegistry.shared
        let identifier = "modifier.dynamic.\(UUID().uuidString)"
        let state = ActionState()
        let host = HostedActionView(
            view: MarkedActionView(
                identifier: identifier,
                role: .mutation,
                actionDescription: "Dynamic action",
                state: state
            ))
        await waitUntil("dynamic registration") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) != nil
        }

        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.isEnabled == false)
        state.isEnabled = true
        #expect(registry.snapshot().actions.first(where: { $0.identifier == identifier })?.isEnabled == true)
        _ = try await registry.activate(identifier: identifier)
        #expect(state.performCount == 1)
        #expect(state.performedOnMainActor)

        host.disappear()
        await waitUntil("dynamic teardown") {
            registry.snapshot().actions.first(where: { $0.identifier == identifier }) == nil
        }
    }
}
#endif
