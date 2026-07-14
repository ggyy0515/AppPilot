#if DEBUG && canImport(Network) && canImport(UIKit)
import Darwin
import Foundation
import Network
import Testing
@testable import IOSDebugCore
@testable import IOSDebugKit

@Test func serverParametersRequireTheIPv4LoopbackEndpoint() throws {
    let port: UInt16 = 19_876
    let parameters = try NetworkDebugServer.parameters(port: port)

    #expect(parameters.allowLocalEndpointReuse)
    #expect(
        parameters.requiredLocalEndpoint
            == .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!
            ))
}

@Test func concurrentStartsShareOneListenerStartAndBothResumeAtReady() async throws {
    let listener = ControlledListener()
    let server = NetworkDebugServer(
        router: HTTPRouter(authenticator: .init(token: nil)),
        listener: listener
    )

    let first = Task { try await server.start() }
    try await waitUntil { listener.startCount == 1 }
    let second = Task { try await server.start() }
    try await Task.sleep(for: .milliseconds(20))

    #expect(listener.startCount == 1)
    listener.emit(.ready)
    try await first.value
    try await second.value
    #expect(listener.startCount == 1)
    await server.stop()
}

@Test func stopDuringStartRejectsAllWaitersAndLateReadyCannotReviveServer() async throws {
    let listener = ControlledListener()
    let server = NetworkDebugServer(
        router: HTTPRouter(authenticator: .init(token: nil)),
        listener: listener
    )

    let first = Task { try await server.start() }
    let second = Task { try await server.start() }
    try await waitUntil { listener.startCount == 1 }
    let queuedReady = try #require(listener.currentStateHandler)

    await server.stop()
    await expectStartupFailure(first)
    await expectStartupFailure(second)
    queuedReady(.ready)

    await #expect(throws: ProtocolError.self) {
        try await server.start()
    }
    #expect(listener.startCount == 1)
}

@Test func serverServesOneFragmentedRequestThenCloses() async throws {
    let router = HTTPRouter(authenticator: .init(token: nil))
    await router.register(.get, pattern: "/v1/health") { _, _, requestID in
        .json(
            status: 200,
            body: try ProtocolJSON.success(
                data: .object(["reachable": .bool(true)]),
                requestID: requestID
            )
        )
    }
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    defer { Task { await server.stop() } }

    let result = try await TestHTTPClient(port: port).exchange(fragments: [
        Data("GET /v1/health HTTP/1.1\r\nHost: local".utf8),
        Data("host\r\n\r\n".utf8),
    ])
    let response = String(decoding: result.bytes, as: UTF8.self)

    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("Connection: close\r\n"))
    #expect(response.contains("\"reachable\":true"))
    #expect(result.peerClosed)
}

@Test(arguments: [
    FailureExchange(
        name: "malformed",
        request: Data("GET /v1/health HTTP/1.0\r\n\r\n".utf8),
        expectedStatus: 400,
        expectedCode: "protocol_mismatch"
    ),
    FailureExchange(
        name: "chunked",
        request: Data("POST /v1/action/a/activate HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8),
        expectedStatus: 400,
        expectedCode: "protocol_mismatch"
    ),
    FailureExchange(
        name: "oversized body",
        request: Data("POST /v1/action/a/activate HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8),
        expectedStatus: 413,
        expectedCode: "artifact_too_large"
    ),
])
func serverReturnsOneStableFailure(_ example: FailureExchange) async throws {
    let router = HTTPRouter(authenticator: .init(token: nil))
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    defer { Task { await server.stop() } }

    let result = try await TestHTTPClient(port: port).exchange(fragments: [example.request])
    let (head, body) = try splitResponse(result.bytes)
    let json = try JSONDecoder().decode(JSONValue.self, from: body)

    #expect(head.hasPrefix("HTTP/1.1 \(example.expectedStatus) "))
    #expect(head.contains("Connection: close\r\n"))
    #expect(errorCode(in: json) == example.expectedCode)
    #expect(errorHint(in: json) == "Send one bounded HTTP/1.1 request with Content-Length and Connection: close.")
    #expect(result.peerClosed)
}

@Test func secondRequestBytesProduceAtMostOneResponseBeforeClose() async throws {
    let router = HTTPRouter(authenticator: .init(token: nil))
    await router.register(.get, pattern: "/v1/health") { _, _, requestID in
        .json(
            status: 200,
            body: try ProtocolJSON.success(data: .object(["reachable": .bool(true)]), requestID: requestID)
        )
    }
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    defer { Task { await server.stop() } }
    let pipelined = Data(
        "GET /v1/health HTTP/1.1\r\n\r\nGET /v1/health HTTP/1.1\r\n\r\n".utf8
    )

    let result = try await TestHTTPClient(port: port).exchange(fragments: [pipelined])
    let response = String(decoding: result.bytes, as: UTF8.self)

    #expect(response.components(separatedBy: "HTTP/1.1 ").count - 1 == 1)
    #expect(response.contains("Connection: close\r\n"))
    #expect(result.peerClosed)
}

@Test func stopCancelsAConnectionWithAPartialRequestBeforeRouting() async throws {
    let counter = RouteCounter()
    let router = HTTPRouter(authenticator: .init(token: nil))
    await router.register(.get, pattern: "/v1/health") { _, _, requestID in
        await counter.increment()
        return .json(
            status: 200,
            body: try ProtocolJSON.success(data: .object(["reachable": .bool(true)]), requestID: requestID)
        )
    }
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    let connection = TestOpenConnection(port: port)
    connection.start()
    defer { connection.cancel() }

    try await connection.send(Data("GET /v1/health HTTP/1.1\r\nHost: local".utf8))
    try await waitUntil { await server.activeConnectionCountForTesting == 1 }
    await server.stop()
    try? await connection.send(Data("host\r\n\r\n".utf8))
    try await Task.sleep(for: .milliseconds(50))

    #expect(await server.activeConnectionCountForTesting == 0)
    #expect(await counter.value == 0)
}

@Test func oversizedHeaderReturnsArtifactTooLargeWithoutEchoingInput() async throws {
    let router = HTTPRouter(authenticator: .init(token: nil))
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    defer { Task { await server.stop() } }
    let secret = "do-not-echo-this-marker"
    let request = Data(("GET /v1/health HTTP/1.1\r\nX-Fill: " + String(repeating: "a", count: 33_000) + secret).utf8)

    let result = try await TestHTTPClient(port: port).exchange(fragments: [request])
    let (head, body) = try splitResponse(result.bytes)

    #expect(head.hasPrefix("HTTP/1.1 413 "))
    #expect(String(decoding: body, as: UTF8.self).contains("\"code\":\"artifact_too_large\""))
    #expect(!String(decoding: result.bytes, as: UTF8.self).contains(secret))
    #expect(result.peerClosed)
}

@Test func serverRejectsTheSimulatorNonLoopbackInterface() async throws {
    let router = HTTPRouter(authenticator: .init(token: nil))
    let port = try LoopbackTestPort.reserve()
    let server = try NetworkDebugServer(port: port, router: router)
    try await server.start()
    defer { Task { await server.stop() } }
    var address = try #require(nonLoopbackIPv4Address())
    address.sin_port = in_port_t(port).bigEndian
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    #expect(result != 0)
}

struct FailureExchange: Sendable, CustomTestStringConvertible {
    let name: String
    let request: Data
    let expectedStatus: Int
    let expectedCode: String

    var testDescription: String { name }
}

private enum LoopbackTestPort {
    static func reserve() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: bound.sin_port)
    }
}

private func nonLoopbackIPv4Address() -> sockaddr_in? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first else { return nil }
    defer { freeifaddrs(first) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
        defer { cursor = interface.pointee.ifa_next }
        guard let address = interface.pointee.ifa_addr,
            address.pointee.sa_family == sa_family_t(AF_INET),
            interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
        else { continue }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
    return nil
}

private struct TestHTTPExchange: Sendable {
    let bytes: Data
    let peerClosed: Bool
}

private struct TestHTTPClient: Sendable {
    let port: UInt16

    func exchange(fragments: [Data]) async throws -> TestHTTPExchange {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "ios-debug-tests.client"))
        defer { connection.cancel() }

        for fragment in fragments {
            try await send(fragment, over: connection)
        }

        var bytes = Data()
        while true {
            let receive = try await receive(over: connection)
            if let data = receive.data { bytes.append(data) }
            if receive.complete { return .init(bytes: bytes, peerClosed: true) }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private func receive(over connection: NWConnection) async throws -> (data: Data?, complete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, complete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
            }
        }
    }
}

private final class ControlledListener: NetworkListenerDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
    private var _newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    private var _startCount = 0

    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? {
        get { lock.withLock { _stateUpdateHandler } }
        set { lock.withLock { _stateUpdateHandler = newValue } }
    }

    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { lock.withLock { _newConnectionHandler } }
        set { lock.withLock { _newConnectionHandler = newValue } }
    }

    var startCount: Int { lock.withLock { _startCount } }
    var currentStateHandler: (@Sendable (NWListener.State) -> Void)? {
        lock.withLock { _stateUpdateHandler }
    }

    func start(queue: DispatchQueue) {
        lock.withLock { _startCount += 1 }
    }

    func cancel() {}

    func emit(_ state: NWListener.State) {
        let handler = lock.withLock { _stateUpdateHandler }
        handler?(state)
    }
}

private final class TestOpenConnection: @unchecked Sendable {
    private let connection: NWConnection

    init(port: UInt16) {
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func start() {
        connection.start(queue: DispatchQueue(label: "ios-debug-tests.partial-client"))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    func cancel() { connection.cancel() }
}

private actor RouteCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private func expectStartupFailure(_ task: Task<Void, any Error>) async {
    do {
        try await task.value
        Issue.record("Expected start to fail after stop")
    } catch let error as ProtocolError {
        #expect(error.code == "app_not_reachable")
    } catch {
        Issue.record("Expected ProtocolError, got \(error)")
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func splitResponse(_ response: Data) throws -> (String, Data) {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let range = response.range(of: delimiter) else { throw HTTPParseError.malformedRequest }
    return (
        String(decoding: response[..<range.upperBound], as: UTF8.self),
        response.subdata(in: range.upperBound..<response.endIndex)
    )
}

private func errorCode(in value: JSONValue) -> String? {
    guard case .object(let root) = value,
        case .object(let error) = root["error"],
        case .string(let code) = error["code"]
    else { return nil }
    return code
}

private func errorHint(in value: JSONValue) -> String? {
    guard case .object(let root) = value,
        case .object(let error) = root["error"],
        case .string(let hint) = error["hint"]
    else { return nil }
    return hint
}
#endif
