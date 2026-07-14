import SwiftUI
#if DEBUG
import IOSDebugKit
#endif

@main
struct DebugDemoApp: App {
    @StateObject private var model: DebugDemoModel
#if DEBUG
    private let runtime: IOSDebugRuntime
#endif

    init() {
        let model = DebugDemoModel()
        _model = StateObject(wrappedValue: model)
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let port = environment["IOS_DEBUG_PORT"].flatMap(UInt16.init) ?? 9876
        let configuration: IOSDebugRuntime.Configuration
        do {
            configuration = try .init(
                port: port,
                bearerToken: environment["IOS_DEBUG_TOKEN"]
            )
        } catch {
            preconditionFailure("Invalid IOSDebugRuntime configuration: \(error)")
        }
        runtime = IOSDebugRuntime(
            configuration: configuration,
            stateProvider: DemoStateProvider(model: model)
        )
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
#if DEBUG
                .task {
                    do {
                        try await runtime.start()
                    } catch {
                        assertionFailure("IOSDebugRuntime failed to start: \(error)")
                    }
                }
                .onDisappear {
                    Task { await runtime.stop() }
                }
#endif
        }
    }
}
