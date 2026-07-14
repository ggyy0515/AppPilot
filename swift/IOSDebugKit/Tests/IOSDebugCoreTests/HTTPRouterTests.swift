import Foundation
import Testing
@testable import IOSDebugCore

@Suite struct HTTPRouterTests {
    @Test func matchesRecordingIdentifierWithoutAcceptingDirectoryPaths() async throws {
        let router = HTTPRouter(authenticator: .init(token: nil))
        await router.register(.get, pattern: "/v1/recordings/{id}") { _, parameters, requestID in
            .json(status: 200, body: try ProtocolJSON.success(data: .string(parameters["id"]!), requestID: requestID))
        }
        let response = await router.response(to: .init(method: .get, path: "/v1/recordings/rec-1", headers: [:], body: Data()))
        #expect(response.statusCode == 200)
        #expect(response.body.contains(Data("rec-1".utf8)))

        for path in ["/v1/recordings/rec-1/segment", "/v1/recordings/bad%2Fid", "/v1/recordings/"] {
            let rejected = await router.response(to: .init(method: .get, path: path, headers: [:], body: Data()))
            #expect(rejected.statusCode == 404)
            #expect(rejected.body.contains(Data("protocol_mismatch".utf8)))
        }
    }

    @Test func matchesOnlyRegisteredMethodAndPath() async throws {
        let router = HTTPRouter(authenticator: .init(token: nil))
        await router.register(.get, pattern: "/v1/state") { _, _, requestID in
            .json(status: 200, body: try ProtocolJSON.success(data: .null, requestID: requestID))
        }
        let missing = await router.response(to: request(.get, "/v1/missing"))
        let wrongMethod = await router.response(to: request(.post, "/v1/state"))
        #expect(missing.statusCode == 404)
        #expect(wrongMethod.statusCode == 405)
        #expect(missing.body.contains(Data("protocol_mismatch".utf8)))
        #expect(wrongMethod.body.contains(Data("protocol_mismatch".utf8)))
    }

    @Test func acceptsOnlyBoundedSafeIdentifierComponents() async {
        let router = HTTPRouter(authenticator: .init(token: nil))
        await router.register(.delete, pattern: "/v1/recordings/{id}") { _, parameters, _ in
            .init(statusCode: 200, headers: [:], body: Data(parameters["id"]!.utf8))
        }
        for id in ["a", "A_9.ok-value", String(repeating: "x", count: 128)] {
            #expect(await router.response(to: request(.delete, "/v1/recordings/\(id)")).statusCode == 200)
        }
        for id in [String(repeating: "x", count: 129), "has space", "slash%2Fvalue", "braces{}"] {
            #expect(await router.response(to: request(.delete, "/v1/recordings/\(id)")).statusCode == 404)
        }
    }

    @Test func authenticatesEveryRequestExceptExactGetHealth() async {
        let authenticator = BearerAuthenticator(token: "correct-secret")
        #expect(authenticator.authorize(request(.get, "/v1/health"), isHealth: true) == nil)

        let missing = authenticator.authorize(request(.get, "/v1/state"), isHealth: false)
        let wrong = authenticator.authorize(request(.get, "/v1/state", headers: ["authorization": "Bearer supplied-secret"]), isHealth: false)
        let malformed = authenticator.authorize(request(.get, "/v1/state", headers: ["authorization": "bearer correct-secret"]), isHealth: false)
        let correct = authenticator.authorize(request(.get, "/v1/state", headers: ["authorization": "Bearer correct-secret"]), isHealth: false)
        #expect(missing == .init(code: "auth_required", message: "Authentication is required.", hint: "Set IOS_DEBUG_TOKEN to the App's configured token."))
        #expect(wrong == .init(code: "auth_failed", message: "Authentication failed.", hint: "Verify IOS_DEBUG_TOKEN and retry without printing the token."))
        #expect(malformed?.code == "auth_failed")
        #expect(correct == nil)
    }

    @Test func routerAuthenticationFailuresNeverEchoSecrets() async {
        let router = HTTPRouter(authenticator: .init(token: "configured-secret"))
        await router.register(.get, pattern: "/v1/state") { _, _, _ in .init(statusCode: 200, headers: [:], body: Data()) }
        for (headers, expectedStatus) in [
            ([String: String](), 401),
            (["authorization": "Bearer supplied-secret"], 403),
        ] {
            let response = await router.response(to: request(.get, "/v1/state", headers: headers))
            #expect(response.statusCode == expectedStatus)
            #expect(!response.body.contains(Data("configured-secret".utf8)))
            #expect(!response.body.contains(Data("supplied-secret".utf8)))
        }
    }

    @Test func routerMapsMissingAndRejectedBearerTokensToDistinctHTTPStatuses() async {
        let router = HTTPRouter(authenticator: .init(token: "configured-secret"))
        await router.register(.get, pattern: "/v1/state") { _, _, _ in
            .init(statusCode: 200, headers: [:], body: Data())
        }
        await router.register(.head, pattern: "/v1/state") { _, _, _ in
            .init(statusCode: 200, headers: [:], body: Data())
        }

        for method in [HTTPMethod.get, .head] {
            let missing = await router.response(to: request(method, "/v1/state"))
            let rejected = await router.response(to: request(
                method,
                "/v1/state",
                headers: ["authorization": "Bearer supplied-secret"]
            ))
            let missingWire = String(decoding: missing.serialized(headOnly: method == .head), as: UTF8.self)
            let rejectedWire = String(decoding: rejected.serialized(headOnly: method == .head), as: UTF8.self)

            #expect(missing.statusCode == 401)
            #expect(missing.body.contains(Data(#""code":"auth_required""#.utf8)))
            #expect(missingWire.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
            #expect(rejected.statusCode == 403)
            #expect(rejected.body.contains(Data(#""code":"auth_failed""#.utf8)))
            #expect(rejectedWire.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            for secret in ["configured-secret", "supplied-secret"] {
                #expect(!missing.body.contains(Data(secret.utf8)))
                #expect(!rejected.body.contains(Data(secret.utf8)))
                #expect(!missingWire.contains(secret))
                #expect(!rejectedWire.contains(secret))
            }
        }
    }

    @Test func routerAllowsOnlyExactGetHealthWithoutAuthentication() async {
        let router = HTTPRouter(authenticator: .init(token: "configured-secret"))
        await router.register(.get, pattern: "/v1/health") { _, _, _ in
            .init(statusCode: 200, headers: [:], body: Data("healthy".utf8))
        }
        await router.register(.post, pattern: "/v1/health") { _, _, _ in
            .init(statusCode: 200, headers: [:], body: Data())
        }
        await router.register(.get, pattern: "/v1/health-check") { _, _, _ in
            .init(statusCode: 200, headers: [:], body: Data())
        }

        #expect(await router.response(to: request(.get, "/v1/health")).statusCode == 200)
        #expect(await router.response(to: request(.post, "/v1/health")).statusCode == 401)
        #expect(await router.response(to: request(.get, "/v1/health-check")).statusCode == 401)
    }

    @Test func serializesOneResponseWithSortedHeadersAndHeadLength() {
        let response = HTTPResponse.json(status: 200, body: Data("hello".utf8))
        let get = String(decoding: response.serialized(headOnly: false), as: UTF8.self)
        let head = String(decoding: response.serialized(headOnly: true), as: UTF8.self)
        #expect(get == "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\nContent-Type: application/json; charset=utf-8\r\n\r\nhello")
        #expect(head == "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\nContent-Type: application/json; charset=utf-8\r\n\r\n")
    }

    @Test func serializationReplacesFramingHeadersCaseInsensitively() {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "content-length": "999",
                "cOnNeCtIoN": "keep-alive",
                "X-Value": "kept",
            ],
            body: Data("hello".utf8)
        )
        let serialized = String(decoding: response.serialized(headOnly: false), as: UTF8.self)
        let headerLines = serialized.components(separatedBy: "\r\n").dropFirst().prefix { !$0.isEmpty }

        #expect(headerLines.filter { $0.lowercased().hasPrefix("content-length:") } == ["Content-Length: 5"])
        #expect(headerLines.filter { $0.lowercased().hasPrefix("connection:") } == ["Connection: close"])
        #expect(headerLines.contains("X-Value: kept"))
    }

    @Test func binaryResponsePreservesMetadataAndSetsMimeType() {
        let response = HTTPResponse.binary(
            mime: "image/png", body: Data([0, 1, 2]),
            headers: ["Content-Type": "wrong/type", "X-IOS-Debug-Pixel-Width": "1179"]
        )
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "wrong/type")
        #expect(response.headers["X-IOS-Debug-Pixel-Width"] == "1179")
        #expect(response.body == Data([0, 1, 2]))
    }

}

private func request(_ method: HTTPMethod, _ path: String, headers: [String: String] = [:]) -> HTTPRequest {
    .init(method: method, path: path, headers: headers, body: Data())
}
