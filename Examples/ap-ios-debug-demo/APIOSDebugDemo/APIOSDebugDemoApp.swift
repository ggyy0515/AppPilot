import SwiftUI
#if DEBUG
import APIOSDebugKit
#endif

@main
struct APIOSDebugDemoApp: App {
    @StateObject private var model: APIOSDebugDemoModel
#if DEBUG
    private let runtime: APIOSDebugRuntime
#endif

    init() {
        let model = APIOSDebugDemoModel()
        _model = StateObject(wrappedValue: model)
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let port = environment["AP_IOS_DEBUG_PORT"].flatMap(UInt16.init) ?? 9876
        let configuration: APIOSDebugRuntime.Configuration
        do {
            configuration = try .init(
                port: port,
                bearerToken: environment["AP_IOS_DEBUG_TOKEN"]
            )
        } catch {
            preconditionFailure("Invalid APIOSDebugRuntime configuration: \(error)")
        }
        runtime = APIOSDebugRuntime(
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
                        assertionFailure("APIOSDebugRuntime failed to start: \(error)")
                    }
                }
                .onDisappear {
                    Task { await runtime.stop() }
                }
#endif
        }
    }
}
