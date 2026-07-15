#if DEBUG && canImport(Network) && canImport(UIKit)
import Foundation
@preconcurrency import Network
import UIKit
import APIOSDebugCore

protocol NetworkListenerDriving: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? { get set }
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

private final class SystemNetworkListener: NetworkListenerDriving, @unchecked Sendable {
    private let listener: NWListener

    init(_ listener: NWListener) {
        self.listener = listener
    }

    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? {
        get { listener.stateUpdateHandler }
        set { listener.stateUpdateHandler = newValue }
    }

    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { listener.newConnectionHandler }
        set { listener.newConnectionHandler = newValue }
    }

    func start(queue: DispatchQueue) { listener.start(queue: queue) }
    func cancel() { listener.cancel() }
}

public actor NetworkDebugServer {
    private enum Lifecycle: Equatable {
        case idle
        case starting(UInt64)
        case ready(UInt64)
        case stopped
    }

    private let router: HTTPRouter
    private let listener: any NetworkListenerDriving
    private let queue = DispatchQueue(label: "ap-ios-debug.server")
    private var lifecycle = Lifecycle.idle
    private var generation: UInt64 = 0
    private var startContinuations: [CheckedContinuation<Void, any Error>] = []
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(port: UInt16, router: HTTPRouter) throws {
        self.router = router
        self.listener = SystemNetworkListener(
            try NWListener(using: Self.parameters(port: port))
        )
    }

    init(router: HTTPRouter, listener: any NetworkListenerDriving) {
        self.router = router
        self.listener = listener
    }

    static func parameters(port: UInt16) throws -> NWParameters {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw startupError
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: endpointPort
        )
        return parameters
    }

    public func start() async throws {
        let shouldStart: Bool
        let activeGeneration: UInt64
        switch lifecycle {
        case .ready:
            return
        case .stopped:
            throw Self.startupError
        case .starting(let existingGeneration):
            shouldStart = false
            activeGeneration = existingGeneration
        case .idle:
            generation &+= 1
            activeGeneration = generation
            lifecycle = .starting(activeGeneration)
            shouldStart = true
            configureListener(for: activeGeneration)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard lifecycle == .starting(activeGeneration) else {
                continuation.resume(throwing: Self.startupError)
                return
            }
            startContinuations.append(continuation)
            if shouldStart {
                listener.start(queue: queue)
            }
        }
    }

    public func stop() async {
        transitionToStopped()
    }

    var activeConnectionCountForTesting: Int { activeConnections.count }

    private func configureListener(for generation: UInt64) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.updateListenerState(state, generation: generation) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection, generation: generation) }
        }
    }

    private func updateListenerState(_ state: NWListener.State, generation: UInt64) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            guard lifecycle == .starting(generation) else { return }
            lifecycle = .ready(generation)
            resumeStartContinuations()
        case .failed:
            guard lifecycle == .starting(generation) || lifecycle == .ready(generation) else { return }
            transitionToStopped()
        case .cancelled:
            guard lifecycle == .starting(generation) || lifecycle == .ready(generation) else { return }
            transitionToStopped(cancelListener: false)
        default:
            break
        }
    }

    private func resumeStartContinuations(throwing error: (any Error)? = nil) {
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    private func transitionToStopped(cancelListener: Bool = true) {
        guard lifecycle != .stopped else { return }
        generation &+= 1
        lifecycle = .stopped
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        if cancelListener { listener.cancel() }
        for task in connectionTasks.values { task.cancel() }
        for connection in activeConnections.values { connection.cancel() }
        connectionTasks.removeAll()
        activeConnections.removeAll()
        resumeStartContinuations(throwing: Self.startupError)
    }

    private func accept(_ connection: NWConnection, generation: UInt64) {
        guard lifecycle == .ready(generation), generation == self.generation else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        activeConnections[identifier] = connection
        connection.start(queue: queue)
        let task = Task { await self.handle(connection, identifier: identifier, generation: generation) }
        connectionTasks[identifier] = task
    }

    private func handle(
        _ connection: NWConnection,
        identifier: ObjectIdentifier,
        generation: UInt64
    ) async {
        defer { finishConnection(identifier, connection: connection) }
        var parser = HTTPRequestParser()

        while true {
            do {
                guard isServing(generation), !Task.isCancelled else { return }
                let receive = try await receive(from: connection)
                guard isServing(generation), !Task.isCancelled else { return }
                guard let data = receive.data, !data.isEmpty else {
                    return
                }
                if let request = try parser.append(data) {
                    guard isServing(generation), !Task.isCancelled else { return }
                    let response = await router.response(to: request)
                    guard isServing(generation), !Task.isCancelled else { return }
                    try await send(response.serialized(headOnly: request.method == .head), over: connection)
                    return
                }
                if receive.complete {
                    return
                }
            } catch let error as HTTPParseError {
                guard isServing(generation), !Task.isCancelled else { return }
                await sendParserFailure(error, over: connection, generation: generation)
                return
            } catch {
                return
            }
        }
    }

    private func isServing(_ generation: UInt64) -> Bool {
        lifecycle == .ready(generation) && generation == self.generation
    }

    private func finishConnection(_ identifier: ObjectIdentifier, connection: NWConnection) {
        connectionTasks[identifier] = nil
        activeConnections[identifier] = nil
        connection.cancel()
    }

    private func sendParserFailure(
        _ parseError: HTTPParseError,
        over connection: NWConnection,
        generation: UInt64
    ) async {
        let oversized = parseError == .headerTooLarge || parseError == .bodyTooLarge
        let error = ProtocolError(
            code: oversized ? AppErrorCode.artifactTooLarge.rawValue : AppErrorCode.protocolMismatch.rawValue,
            message: oversized ? "The HTTP request is too large." : "The HTTP request is malformed or unsupported.",
            hint: "Send one bounded HTTP/1.1 request with Content-Length and Connection: close."
        )
        let requestID = UUID().uuidString.lowercased()
        guard let body = try? ProtocolJSON.failure(error: error, requestID: requestID) else {
            return
        }
        guard isServing(generation), !Task.isCancelled else { return }
        let response = HTTPResponse.json(status: oversized ? 413 : 400, body: body)
        try? await send(response.serialized(headOnly: false), over: connection)
    }

    private func receive(from connection: NWConnection) async throws -> (data: Data?, complete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    private static let startupError = ProtocolError(
        code: AppErrorCode.appNotReachable.rawValue,
        message: "Debug server could not start.",
        hint: "Verify port 9876 is free and launch a Debug build."
    )
}
#endif
