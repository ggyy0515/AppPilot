#if DEBUG
import APIOSDebugKit

@MainActor
final class DemoStateProvider: DebugStateProvider {
    private let model: APIOSDebugDemoModel

    init(model: APIOSDebugDemoModel) {
        self.model = model
    }

    func snapshot() -> APIOSDebugDemoSnapshot {
        model.snapshot
    }

    func debugState() throws -> JSONValue {
        try JSONValue.encode(snapshot())
    }
}
#endif
