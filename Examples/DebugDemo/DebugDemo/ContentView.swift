import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DebugDemoModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Count: \(model.counter)").font(.largeTitle)
                Button("Increment", action: model.increment)
                Button("Reset", role: .destructive, action: model.reset)
            }
            .padding()
            .navigationTitle("Debug Demo")
            .toolbar {
                Button("Settings", action: model.showSettings)
            }
            .sheet(isPresented: Binding(
                get: { model.screen == "settings" },
                set: { if !$0 { model.dismissSettings() } }
            )) {
                NavigationStack {
                    Text("Settings")
                        .navigationTitle("Settings")
                        .toolbar { Button("Done", action: model.dismissSettings) }
                }
            }
        }
    }
}
