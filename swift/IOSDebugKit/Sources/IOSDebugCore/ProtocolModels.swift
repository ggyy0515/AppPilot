import Foundation

public enum IOSDebugProtocol {
    public static let version = 1
    public static let defaultPort: UInt16 = 9876
    public static let maximumHeaderBytes = 32 * 1024
    public static let maximumRequestBodyBytes = 1 * 1024 * 1024
    public static let maximumStateBytes = 4 * 1024 * 1024
    public static let maximumPNGBytes = 25 * 1024 * 1024
    public static let maximumMP4Bytes = 500 * 1024 * 1024
}

public struct ProtocolError: Error, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let hint: String
    public init(code: String, message: String, hint: String) {
        self.code = code; self.message = message; self.hint = hint
    }
}

public enum ProtocolJSON {
    public static func success(data: JSONValue, requestID: String) throws -> Data {
        try encode(.object([
            "ok": .bool(true), "data": data,
            "meta": .object(["protocol_version": .number(1), "request_id": .string(requestID)]),
        ]))
    }

    public static func failure(error: ProtocolError, requestID: String) throws -> Data {
        try encode(.object([
            "ok": .bool(false),
            "error": .object(["code": .string(error.code), "message": .string(error.message), "hint": .string(error.hint)]),
            "meta": .object(["protocol_version": .number(1), "request_id": .string(requestID)]),
        ]))
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
