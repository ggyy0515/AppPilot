#if DEBUG && canImport(UIKit)
import Foundation
import APIOSDebugCore

@MainActor public protocol DebugStateProvider: AnyObject {
    func debugState() throws -> JSONValue
}

@MainActor public final class EncodableDebugStateProvider<Value: Encodable>: DebugStateProvider {
    private let snapshot: @MainActor () throws -> Value

    public init(snapshot: @escaping @MainActor () throws -> Value) {
        self.snapshot = snapshot
    }

    public func debugState() throws -> JSONValue {
        try JSONValue.encode(snapshot())
    }
}

@MainActor enum StateSnapshotEncoder {
    static func encode(provider: any DebugStateProvider) throws -> (value: JSONValue, data: Data) {
        do {
            let value = try provider.debugState()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= APIOSDebugProtocol.maximumStateBytes else {
                throw StateFailure.tooLarge
            }
            return (value, data)
        } catch {
            throw ProtocolError(
                code: AppErrorCode.stateEncodingFailed.rawValue,
                message: "App state could not be encoded.",
                hint: "Verify the DebugStateProvider returns finite, JSON-encodable values under 4 MiB."
            )
        }
    }

    private enum StateFailure: Error {
        case tooLarge
    }
}
#endif
