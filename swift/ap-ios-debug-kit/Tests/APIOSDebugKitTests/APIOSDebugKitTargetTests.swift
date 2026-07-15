import APIOSDebugKit
import Testing

@Test func debugTargetReexportsCoreProtocol() {
    #expect(APIOSDebugProtocol.version == 1)
}
