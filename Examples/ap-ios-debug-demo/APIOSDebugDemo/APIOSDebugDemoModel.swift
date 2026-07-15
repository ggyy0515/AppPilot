import Foundation

struct APIOSDebugDemoSnapshot: Codable, Equatable, Sendable {
    let screen: String
    let counter: Int
    let lastAction: String?

    enum CodingKeys: String, CodingKey {
        case screen
        case counter
        case lastAction = "last_action"
    }
}

@MainActor
final class APIOSDebugDemoModel: ObservableObject {
    @Published private(set) var counter = 0
    @Published private(set) var screen = "home"
    @Published private(set) var lastAction: String?

    var snapshot: APIOSDebugDemoSnapshot {
        .init(screen: screen, counter: counter, lastAction: lastAction)
    }

    func increment() {
        counter += 1
        lastAction = "counter.increment"
    }

    func reset() {
        counter = 0
        screen = "home"
        lastAction = "counter.reset"
    }

    func showSettings() {
        screen = "settings"
        lastAction = "header.settings"
    }

    func dismissSettings() {
        screen = "home"
        lastAction = "settings.dismiss"
    }
}
