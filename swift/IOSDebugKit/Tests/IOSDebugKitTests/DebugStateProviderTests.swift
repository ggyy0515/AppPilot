#if DEBUG && canImport(UIKit)
import Foundation
import Testing
@testable import IOSDebugKit
import IOSDebugCore

private let expectedStateFailure = ProtocolError(
    code: "state_encoding_failed",
    message: "App state could not be encoded.",
    hint: "Verify the DebugStateProvider returns finite, JSON-encodable values under 4 MiB."
)

@Test @MainActor func encodesCodableSnapshot() throws {
    struct State: Codable { let count: Int }
    let provider = EncodableDebugStateProvider { State(count: 7) }

    let result = try StateSnapshotEncoder.encode(provider: provider)

    #expect(result.value == .object(["count": .number(7)]))
    #expect(result.data == Data("{\"count\":7}".utf8))
    #expect(result.data.count < IOSDebugProtocol.maximumStateBytes)
}

@Test @MainActor func providerFailureBecomesStableProtocolError() {
    final class ThrowingProvider: DebugStateProvider {
        private enum Sentinel: Error { case privateFailure }
        func debugState() throws -> JSONValue { throw Sentinel.privateFailure }
    }

    expectStableFailure(from: ThrowingProvider())
}

@Test @MainActor func nonFiniteJSONBecomesStableProtocolError() {
    final class InfiniteProvider: DebugStateProvider {
        func debugState() -> JSONValue { .number(.infinity) }
    }

    expectStableFailure(from: InfiniteProvider())
}

@Test @MainActor func oversizedJSONBecomesStableProtocolErrorWithoutPartialResult() {
    final class OversizedProvider: DebugStateProvider {
        func debugState() -> JSONValue {
            .string(String(repeating: "x", count: IOSDebugProtocol.maximumStateBytes))
        }
    }

    expectStableFailure(from: OversizedProvider())
}

@MainActor private func expectStableFailure(from provider: any DebugStateProvider) {
    do {
        _ = try StateSnapshotEncoder.encode(provider: provider)
        Issue.record("Expected state encoding to fail without returning a partial result")
    } catch let error as ProtocolError {
        #expect(error == expectedStateFailure)
    } catch {
        Issue.record("Expected ProtocolError, got \(type(of: error))")
    }
}
#endif
