import XCTest
@testable import DebugDemo

@MainActor
final class DebugDemoModelTests: XCTestCase {
    func testIncrementAndSettingsProduceStableSnapshot() {
        let model = DebugDemoModel()
        XCTAssertEqual(model.snapshot, .init(screen: "home", counter: 0, lastAction: nil))

        model.increment()
        XCTAssertEqual(model.snapshot.counter, 1)
        XCTAssertEqual(model.snapshot.lastAction, "counter.increment")

        model.showSettings()
        XCTAssertEqual(model.snapshot.screen, "settings")
        XCTAssertEqual(model.snapshot.lastAction, "header.settings")
    }

    func testResetIsDeterministic() {
        let model = DebugDemoModel()
        model.increment()
        model.reset()
        XCTAssertEqual(model.snapshot, .init(screen: "home", counter: 0, lastAction: "counter.reset"))
    }
}
