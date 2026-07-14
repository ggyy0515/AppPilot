import IOSDebugKit
import Testing

@Test func debugTargetReexportsCoreProtocol() {
    #expect(IOSDebugProtocol.version == 1)
}
