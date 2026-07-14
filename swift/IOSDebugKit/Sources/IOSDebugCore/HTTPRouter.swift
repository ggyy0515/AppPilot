import Foundation

public struct HTTPRouteParameters: Sendable {
    public let values: [String: String]

    public subscript(_ key: String) -> String? { values[key] }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        precondition(Self.reasons[statusCode] != nil, "Unsupported HTTP status code")
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json(status: Int, body: Data) -> Self {
        .init(statusCode: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    public static func binary(status: Int = 200, mime: String, body: Data, headers: [String: String]) -> Self {
        .init(statusCode: status, headers: headers.merging(["Content-Type": mime]) { current, _ in current }, body: body)
    }

    public func serialized(headOnly: Bool) -> Data {
        var responseHeaders = headers.filter {
            let name = $0.key.lowercased()
            return name != "content-length" && name != "connection"
        }
        responseHeaders["Content-Length"] = String(body.count)
        responseHeaders["Connection"] = "close"
        let reason = Self.reasons[statusCode]!
        var bytes = Data("HTTP/1.1 \(statusCode) \(reason)\r\n".utf8)
        for key in responseHeaders.keys.sorted() {
            bytes.append(Data("\(key): \(responseHeaders[key]!)\r\n".utf8))
        }
        bytes.append(Data("\r\n".utf8))
        if !headOnly { bytes.append(body) }
        return bytes
    }

    private static let reasons = [
        200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large",
        500: "Internal Server Error", 503: "Service Unavailable", 504: "Gateway Timeout",
    ]
}

public struct BearerAuthenticator: Sendable {
    private let token: Data?

    public init(token: String?) {
        self.token = token.map { Data($0.utf8) }
    }

    public func authorize(_ request: HTTPRequest, isHealth: Bool) -> ProtocolError? {
        guard !isHealth, let token else { return nil }
        guard let value = request.headers["authorization"] else {
            return .init(code: AppErrorCode.authRequired.rawValue, message: "Authentication is required.", hint: "Set IOS_DEBUG_TOKEN to the App's configured token.")
        }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix), constantTimeEqual(Data(value.dropFirst(prefix.count).utf8), token) else {
            return .init(code: AppErrorCode.authFailed.rawValue, message: "Authentication failed.", hint: "Verify IOS_DEBUG_TOKEN and retry without printing the token.")
        }
        return nil
    }
}

public actor HTTPRouter {
    public typealias Handler = @Sendable (HTTPRequest, HTTPRouteParameters, String) async throws -> HTTPResponse

    private struct Route: Sendable {
        let method: HTTPMethod
        let components: [String]
        let handler: Handler
    }

    private let authenticator: BearerAuthenticator
    private var routes: [Route] = []

    public init(authenticator: BearerAuthenticator) {
        self.authenticator = authenticator
    }

    public func register(_ method: HTTPMethod, pattern: String, handler: @escaping Handler) {
        routes.append(.init(method: method, components: Self.components(of: pattern), handler: handler))
    }

    public func response(to request: HTTPRequest) async -> HTTPResponse {
        let requestID = UUID().uuidString.lowercased()
        let isHealth = request.method == .get && request.path == "/v1/health"
        if let error = authenticator.authorize(request, isHealth: isHealth) {
            let status = error.code == AppErrorCode.authRequired.rawValue ? 401 : 403
            return failure(status: status, error: error, requestID: requestID)
        }

        let pathComponents = Self.components(of: request.path)
        var pathMatched = false
        for route in routes {
            guard let parameters = Self.match(route.components, to: pathComponents) else { continue }
            pathMatched = true
            guard route.method == request.method else { continue }
            do {
                return try await route.handler(request, parameters, requestID)
            } catch {
                return failure(
                    status: 500,
                    error: .init(code: AppErrorCode.protocolMismatch.rawValue, message: "The request could not be completed.", hint: "Retry the request and verify the App and CLI protocol versions match."),
                    requestID: requestID
                )
            }
        }

        return failure(
            status: pathMatched ? 405 : 404,
            error: .init(code: AppErrorCode.protocolMismatch.rawValue, message: pathMatched ? "The HTTP method is not supported for this path." : "The requested path is not available.", hint: "Verify the App and CLI protocol versions match."),
            requestID: requestID
        )
    }

    private func failure(status: Int, error: ProtocolError, requestID: String) -> HTTPResponse {
        let body = (try? ProtocolJSON.failure(error: error, requestID: requestID)) ?? Data()
        return .json(status: status, body: body)
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
    }

    private static func match(_ pattern: [String], to path: [String]) -> HTTPRouteParameters? {
        guard pattern.count == path.count else { return nil }
        var values: [String: String] = [:]
        for (expected, actual) in zip(pattern, path) {
            if expected == "{id}" {
                guard isValidIdentifier(actual) else { return nil }
                values["id"] = actual
            } else if expected != actual {
                return nil
            }
        }
        return .init(values: values)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
            ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}

private func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    var difference = UInt(left.count ^ right.count)
    let count = max(left.count, right.count)
    for index in 0..<count {
        let leftByte = index < left.count ? left[index] : 0
        let rightByte = index < right.count ? right[index] : 0
        difference |= UInt(leftByte ^ rightByte)
    }
    return difference == 0
}
