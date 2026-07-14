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

public enum AppErrorCode: String, CaseIterable, Codable, Sendable {
    case configInvalid = "config_invalid"
    case appNotReachable = "app_not_reachable"
    case requestTimeout = "request_timeout"
    case protocolMismatch = "protocol_mismatch"
    case authRequired = "auth_required"
    case authFailed = "auth_failed"
    case actionNotFound = "action_not_found"
    case actionDisabled = "action_disabled"
    case actionFailed = "action_failed"
    case stateEncodingFailed = "state_encoding_failed"
    case screenshotFailed = "screenshot_failed"
    case recordingNotAvailable = "recording_not_available"
    case recordingInvalidState = "recording_invalid_state"
    case recordingPermissionTimeout = "recording_permission_timeout"
    case artifactTooLarge = "artifact_too_large"
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
