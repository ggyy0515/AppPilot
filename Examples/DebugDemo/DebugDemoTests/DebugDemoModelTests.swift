import XCTest
@testable import DebugDemo
#if DEBUG
import IOSDebugKit
#endif

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

#if DEBUG
    func testDemoStateProviderEncodesStableKeys() throws {
        let model = DebugDemoModel()
        model.increment()
        let provider = DemoStateProvider(model: model)
        let data = try JSONEncoder().encode(provider.snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["screen"] as? String, "home")
        XCTAssertEqual(object["counter"] as? Int, 1)
        XCTAssertEqual(object["last_action"] as? String, "counter.increment")
    }
#endif
}
