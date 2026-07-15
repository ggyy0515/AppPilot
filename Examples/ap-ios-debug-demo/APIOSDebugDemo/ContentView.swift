import SwiftUI
#if DEBUG
import APIOSDebugKit
#endif

struct ContentView: View {
    @ObservedObject var model: APIOSDebugDemoModel

    var body: some View {
        NavigationStack {
            counterControls
                .padding()
                .navigationTitle("Debug Demo")
                .toolbar { Button("Settings", action: model.showSettings) }
                .sheet(isPresented: settingsPresented) { settingsView }
        }
#if DEBUG
        .iosDebugAction(
            "header.settings",
            role: .navigation,
            description: "Present the settings screen."
        ) { model.showSettings() }
#endif
    }

    private var counterControls: some View {
        VStack(spacing: 24) {
            Text("Count: \(model.counter)").font(.largeTitle)
            Button("Increment", action: model.increment)
            Button("Reset", role: .destructive, action: model.reset)
        }
#if DEBUG
        .iosDebugAction(
            "counter.increment",
            role: .mutation,
            description: "Increment the demo counter by one."
        ) { model.increment() }
        .iosDebugAction(
            "counter.reset",
            role: .destructive,
            description: "Reset the counter and return home."
        ) { model.reset() }
#endif
    }

    private var settingsView: some View {
        NavigationStack {
            Text("Settings")
                .navigationTitle("Settings")
                .toolbar { Button("Done", action: model.dismissSettings) }
        }
#if DEBUG
        .iosDebugAction(
            "settings.dismiss",
            role: .navigation,
            description: "Dismiss the settings screen."
        ) { model.dismissSettings() }
#endif
    }

    private var settingsPresented: Binding<Bool> {
        Binding(
            get: { model.screen == "settings" },
            set: { if !$0 { model.dismissSettings() } }
        )
    }
}
