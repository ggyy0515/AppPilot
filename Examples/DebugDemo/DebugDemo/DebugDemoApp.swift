import SwiftUI

@main
struct DebugDemoApp: App {
    @StateObject private var model = DebugDemoModel()

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}
