#if DEBUG && canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)

private struct DebugActionLifecycleModifier: ViewModifier {
    let identifier: String
    let role: DebugActionRole
    let description: String
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () async throws -> Void

    func body(content: Content) -> some View {
        DebugActionLifecycleView(
            content: content,
            identifier: identifier,
            role: role,
            description: description,
            isEnabled: isEnabled,
            perform: perform
        )
        .id("\(identifier)|\(role.rawValue)|\(description)")
    }
}

private struct DebugActionLifecycleView<Content: View>: View {
    let content: Content
    let identifier: String
    let role: DebugActionRole
    let description: String
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () async throws -> Void

    @State private var token: DebugActionToken?

    var body: some View {
        content
            .onAppear {
                do {
                    token = try DebugActionRegistry.shared.register(
                        identifier: identifier,
                        role: role,
                        description: description,
                        isEnabled: isEnabled,
                        perform: perform
                    )
                } catch {
                    assertionFailure("Invalid iosDebugAction registration: \(identifier)")
                    token = nil
                }
            }
            .onDisappear {
                guard let token else { return }
                DebugActionRegistry.shared.unregister(token)
                self.token = nil
            }
    }
}

public extension View {
    func iosDebugAction(
        _ identifier: String,
        role: DebugActionRole,
        description: String,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        perform: @escaping @MainActor () async throws -> Void
    ) -> some View {
        modifier(DebugActionLifecycleModifier(
            identifier: identifier,
            role: role,
            description: description,
            isEnabled: isEnabled,
            perform: perform
        ))
    }
}
#endif
#endif
