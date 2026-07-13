import Testing
import IOSDebugKit

@Test func debugTargetReexportsCoreProtocol() {
    #expect(IOSDebugProtocol.version == 1)
}
