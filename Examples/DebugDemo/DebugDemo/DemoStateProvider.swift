#if DEBUG
import IOSDebugKit

@MainActor
final class DemoStateProvider: DebugStateProvider {
    private let model: DebugDemoModel

    init(model: DebugDemoModel) {
        self.model = model
    }

    func snapshot() -> DebugDemoSnapshot {
        model.snapshot
    }

    func debugState() throws -> JSONValue {
        try JSONValue.encode(snapshot())
    }
}
#endif
