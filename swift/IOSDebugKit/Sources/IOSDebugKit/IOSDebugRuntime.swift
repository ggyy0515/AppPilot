#if DEBUG && canImport(UIKit)
import Foundation
import IOSDebugCore
import UIKit

@MainActor public final class IOSDebugRuntime {
    public struct Configuration: Sendable {
        public let port: UInt16
        public let bearerToken: String?
        public let maximumRecordingDuration: Duration

        public init(
            port: UInt16 = 9876,
            bearerToken: String? = nil,
            maximumRecordingDuration: Duration = .seconds(120)
        ) throws {
            guard port > 0 else {
                throw ProtocolError(
                    code: AppErrorCode.configInvalid.rawValue,
                    message: "Debug port is invalid.",
                    hint: "Use a port from 1 through 65535; the default is 9876."
                )
            }
            if let bearerToken, bearerToken.isEmpty {
                throw ProtocolError(
                    code: AppErrorCode.configInvalid.rawValue,
                    message: "Bearer token is empty.",
                    hint: "Unset IOS_DEBUG_TOKEN or provide a nonempty value."
                )
            }
            guard maximumRecordingDuration > .zero, maximumRecordingDuration <= .seconds(600) else {
                throw ProtocolError(
                    code: AppErrorCode.configInvalid.rawValue,
                    message: "Recording duration is outside the supported range.",
                    hint: "Choose a maximum duration from 1 through 600 seconds."
                )
            }
            self.port = port
            self.bearerToken = bearerToken
            self.maximumRecordingDuration = maximumRecordingDuration
        }
    }

    struct ScreenshotSource: Sendable {
        let capture: @MainActor @Sendable () throws -> CapturedScreenshot
    }

    struct RecordingArtifact: Sendable {
        let metadata: RecordingMetadata
        let data: Data
        let mime: String
    }

    struct RecordingSource: Sendable {
        let isAvailable: @Sendable () async -> Bool
        let status: @Sendable () async -> RecordingStatus
        let start: @Sendable (Duration) async throws -> Void
        let stop: @Sendable () async throws -> RecordingMetadata
        let file: @Sendable (String) async throws -> RecordingArtifact
        let delete: @Sendable (String) async throws -> Void
        let cleanup: @Sendable () async throws -> Void
    }

    struct ServerSource: Sendable {
        let start: @Sendable () async throws -> Void
        let stop: @Sendable () async -> Void
    }

    struct Limits: Sendable {
        let requestBodyBytes: Int
        let pngBytes: Int
        let mp4Bytes: Int

        static let production = Limits(
            requestBodyBytes: IOSDebugProtocol.maximumRequestBodyBytes,
            pngBytes: IOSDebugProtocol.maximumPNGBytes,
            mp4Bytes: IOSDebugProtocol.maximumMP4Bytes
        )
    }

    private enum Lifecycle {
        case stopped
        case starting(UInt64, Task<ServerSource, Error>)
        case running(UInt64, ServerSource)
        case stopping(UInt64, Task<Void, Never>)
    }

    public let actions: DebugActionRegistry

    private let configuration: Configuration
    private let stateProvider: any DebugStateProvider
    private let router: HTTPRouter
    private let screenshot: ScreenshotSource
    private let recording: RecordingSource
    private let serverFactory: @MainActor @Sendable (UInt16, HTTPRouter) throws -> ServerSource
    private let routeRegistration: Task<Void, Never>
    private var lifecycle = Lifecycle.stopped
    private var nextLifecycleGeneration: UInt64 = 0

    public convenience init(
        configuration: Configuration,
        stateProvider: any DebugStateProvider,
        actionRegistry: DebugActionRegistry = .shared
    ) {
        let screenshotCapture = ScreenshotCapture()
        let recordingController = RecordingController()
        self.init(
            configuration: configuration,
            stateProvider: stateProvider,
            actionRegistry: actionRegistry,
            screenshotFactory: {
                ScreenshotSource(capture: { try screenshotCapture.capture() })
            },
            recordingFactory: {
                RecordingSource(
                    isAvailable: { await recordingController.isAvailable() },
                    status: { await recordingController.status() },
                    start: { try await recordingController.start(maximumDuration: $0) },
                    stop: { try await recordingController.stop() },
                    file: { id in
                        let file = try await recordingController.file(id: id)
                        let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                        return RecordingArtifact(metadata: file.metadata, data: data, mime: file.mime)
                    },
                    delete: { try await recordingController.delete(id: $0) },
                    cleanup: { try await recordingController.cleanup() }
                )
            },
            serverFactory: { port, router in
                let server = try NetworkDebugServer(port: port, router: router)
                return ServerSource(
                    start: { try await server.start() },
                    stop: { await server.stop() }
                )
            }
        )
    }

    init(
        configuration: Configuration,
        stateProvider: any DebugStateProvider,
        actionRegistry: DebugActionRegistry = .shared,
        screenshotFactory: @MainActor @Sendable () -> ScreenshotSource,
        recordingFactory: @MainActor @Sendable () -> RecordingSource,
        serverFactory: @escaping @MainActor @Sendable (UInt16, HTTPRouter) throws -> ServerSource,
        limits: Limits = .production
    ) {
        self.configuration = configuration
        self.stateProvider = stateProvider
        self.actions = actionRegistry
        screenshot = screenshotFactory()
        recording = recordingFactory()
        self.serverFactory = serverFactory

        let router = HTTPRouter(authenticator: .init(token: configuration.bearerToken))
        self.router = router
        let context = RouteContext(
            configuration: configuration,
            actionSnapshot: { actionRegistry.snapshot() },
            activate: { try await actionRegistry.activate(identifier: $0) },
            stateSnapshot: { try StateSnapshotEncoder.encode(provider: stateProvider).value },
            screenshot: screenshot,
            recording: recording,
            limits: limits
        )
        routeRegistration = Task {
            await RouteRegistrar.register(on: router, context: context)
        }
    }

    public func start() async throws {
        while true {
            switch lifecycle {
            case .stopped:
                nextLifecycleGeneration &+= 1
                let generation = nextLifecycleGeneration
                let task = makeStartTask()
                lifecycle = .starting(generation, task)
                try await finishStart(generation: generation, task: task)
                return
            case let .starting(generation, task):
                try await finishStart(generation: generation, task: task)
                return
            case .running:
                return
            case let .stopping(generation, task):
                await task.value
                finishStop(generation: generation)
            }
        }
    }

    public func stop() async {
        switch lifecycle {
        case .stopped:
            return
        case let .starting(generation, startTask):
            let task = Task { @MainActor [recording] in
                do {
                    let server = try await startTask.value
                    await Self.shutDown(server: server, recording: recording)
                } catch {
                    // Startup owns rollback when it fails.
                }
            }
            lifecycle = .stopping(generation, task)
            await task.value
            finishStop(generation: generation)
        case let .running(generation, server):
            let task = Task { @MainActor [recording] in
                await Self.shutDown(server: server, recording: recording)
            }
            lifecycle = .stopping(generation, task)
            await task.value
            finishStop(generation: generation)
        case let .stopping(generation, task):
            await task.value
            finishStop(generation: generation)
        }
    }

    private func makeStartTask() -> Task<ServerSource, Error> {
        Task { @MainActor [configuration, recording, routeRegistration, router, serverFactory] in
            await routeRegistration.value
            try await recording.cleanup()
            let server = try serverFactory(configuration.port, router)
            do {
                try await server.start()
                return server
            } catch {
                await server.stop()
                throw error
            }
        }
    }

    private func finishStart(generation: UInt64, task: Task<ServerSource, Error>) async throws {
        do {
            let server = try await task.value
            if case let .starting(currentGeneration, _) = lifecycle, currentGeneration == generation {
                lifecycle = .running(generation, server)
            }
        } catch {
            if case let .starting(currentGeneration, _) = lifecycle, currentGeneration == generation {
                lifecycle = .stopped
            }
            throw error
        }
    }

    private func finishStop(generation: UInt64) {
        if case let .stopping(currentGeneration, _) = lifecycle, currentGeneration == generation {
            lifecycle = .stopped
        }
    }

    private static func shutDown(server: ServerSource, recording: RecordingSource) async {
        await server.stop()
        let status = await recording.status()
        if status.phase == .recording {
            _ = try? await recording.stop()
        }
    }

    func waitForRouteRegistrationForTesting() async {
        await routeRegistration.value
    }

    func responseForTesting(_ request: HTTPRequest) async -> HTTPResponse {
        await routeRegistration.value
        return await router.response(to: request)
    }
}

private struct RouteContext: Sendable {
    let configuration: IOSDebugRuntime.Configuration
    let actionSnapshot: @MainActor @Sendable () -> DebugActionSnapshot
    let activate: @MainActor @Sendable (String) async throws -> UInt64
    let stateSnapshot: @MainActor @Sendable () throws -> JSONValue
    let screenshot: IOSDebugRuntime.ScreenshotSource
    let recording: IOSDebugRuntime.RecordingSource
    let limits: IOSDebugRuntime.Limits
}

private enum RouteRegistrar {
    static func register(on router: HTTPRouter, context: RouteContext) async {
        await registerGET(on: router, pattern: "/v1/health") { _, _, requestID in
            success(.object([
                "service": .string("ios-debug"),
                "app_bundle_identifier": .string(Bundle.main.bundleIdentifier ?? ""),
                "app_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
                "protocol_version": .number(Double(IOSDebugProtocol.version)),
                "auth_required": .bool(context.configuration.bearerToken != nil),
            ]), requestID: requestID)
        }

        await registerGET(on: router, pattern: "/v1/capabilities") { _, _, requestID in
            let available = await context.recording.isAvailable()
            return success(.object([
                "protocol_version": .number(Double(IOSDebugProtocol.version)),
                "actions": .bool(true),
                "state": .bool(true),
                "screenshot": .bool(true),
                "recording": .bool(available),
                "limits": .object([
                    "header_bytes": .number(Double(IOSDebugProtocol.maximumHeaderBytes)),
                    "request_body_bytes": .number(Double(IOSDebugProtocol.maximumRequestBodyBytes)),
                    "state_bytes": .number(Double(IOSDebugProtocol.maximumStateBytes)),
                    "png_bytes": .number(Double(IOSDebugProtocol.maximumPNGBytes)),
                    "mp4_bytes": .number(Double(IOSDebugProtocol.maximumMP4Bytes)),
                    "recording_default_seconds": .number(Double(seconds(context.configuration.maximumRecordingDuration))),
                    "recording_maximum_seconds": .number(600),
                ]),
            ]), requestID: requestID)
        }

        await registerGET(on: router, pattern: "/v1/actions") { _, _, requestID in
            do {
                let snapshot = await context.actionSnapshot()
                return try success(JSONValue.encode(snapshot), requestID: requestID)
            } catch {
                return failure(.init(code: AppErrorCode.actionFailed.rawValue, message: "Actions could not be listed.", hint: "Retry after the App finishes updating Debug actions."), status: 500, requestID: requestID)
            }
        }

        await router.register(.post, pattern: "/v1/actions/activate") { request, _, requestID in
            guard request.headers["content-type"]?.lowercased() == "application/json" else {
                return failure(.init(code: AppErrorCode.protocolMismatch.rawValue, message: "The request Content-Type is invalid.", hint: "Send application/json with exactly one identifier field."), status: 400, requestID: requestID)
            }
            guard request.body.count <= context.limits.requestBodyBytes else {
                return tooLarge(requestID: requestID)
            }
            let body: ActivateBody
            do { body = try JSONDecoder().decode(ActivateBody.self, from: request.body) }
            catch {
                return failure(.init(code: AppErrorCode.protocolMismatch.rawValue, message: "The action request is malformed.", hint: "Send application/json with exactly one identifier field."), status: 400, requestID: requestID)
            }
            do {
                let generation = try await context.activate(body.identifier)
                return success(.object([
                    "identifier": .string(body.identifier),
                    "generation": .number(Double(generation)),
                    "activated": .bool(true),
                ]), requestID: requestID)
            } catch let error as ProtocolError {
                return failure(error, status: status(for: error, operation: .action), requestID: requestID)
            } catch {
                return failure(.init(code: AppErrorCode.actionFailed.rawValue, message: "Action failed.", hint: "Inspect the App state and Debug logs, then retry."), status: 500, requestID: requestID)
            }
        }

        await registerGET(on: router, pattern: "/v1/state") { _, _, requestID in
            do { return success(try await context.stateSnapshot(), requestID: requestID) }
            catch let error as ProtocolError { return failure(error, status: 500, requestID: requestID) }
            catch { return failure(.init(code: AppErrorCode.stateEncodingFailed.rawValue, message: "App state could not be encoded.", hint: "Verify the DebugStateProvider returns finite, JSON-encodable values under 4 MiB."), status: 500, requestID: requestID) }
        }

        await registerGET(on: router, pattern: "/v1/screenshot") { _, _, requestID in
            do {
                let screenshot = try await context.screenshot.capture()
                guard screenshot.pngData.count <= context.limits.pngBytes else { return tooLarge(requestID: requestID) }
                return binary(
                    mime: "image/png",
                    body: screenshot.pngData,
                    requestID: requestID,
                    sha256: screenshot.sha256,
                    additionalHeaders: [
                        "X-IOS-Debug-Capture-Method": screenshot.method.rawValue,
                        "X-IOS-Debug-Pixel-Width": String(screenshot.pixelWidth),
                        "X-IOS-Debug-Pixel-Height": String(screenshot.pixelHeight),
                        "X-IOS-Debug-Scale": String(screenshot.scale),
                    ]
                )
            } catch let error as ProtocolError { return failure(error, status: 500, requestID: requestID) }
            catch { return failure(.init(code: AppErrorCode.screenshotFailed.rawValue, message: "The foreground App window could not be captured.", hint: "Keep the App foregrounded and avoid protected or unsupported rendering surfaces."), status: 500, requestID: requestID) }
        }

        await registerGET(on: router, pattern: "/v1/recording/status") { _, _, requestID in
            success(recordingStatus(await context.recording.status()), requestID: requestID)
        }

        await router.register(.post, pattern: "/v1/recording/start") { _, _, requestID in
            do {
                try await context.recording.start(context.configuration.maximumRecordingDuration)
                return success(recordingStatus(await context.recording.status()), requestID: requestID)
            } catch let error as ProtocolError {
                return failure(error, status: status(for: error, operation: .recordingOperation), requestID: requestID)
            } catch {
                return failure(recordingInternalFailure, status: 500, requestID: requestID)
            }
        }

        await router.register(.post, pattern: "/v1/recording/stop") { _, _, requestID in
            do {
                let metadata = try await context.recording.stop()
                return success(.object([
                    "recording_id": .string(metadata.id),
                    "byte_count": .number(Double(metadata.byteCount)),
                    "duration_ms": .number(Double(metadata.durationMilliseconds)),
                    "sha256": .string(metadata.sha256),
                    "mime": .string("video/mp4"),
                ]), requestID: requestID)
            } catch let error as ProtocolError {
                return failure(error, status: status(for: error, operation: .recordingOperation), requestID: requestID)
            } catch {
                return failure(recordingInternalFailure, status: 500, requestID: requestID)
            }
        }

        await registerGET(on: router, pattern: "/v1/recordings/{id}") { _, parameters, requestID in
            guard let id = parameters["id"] else { return missingRecording(requestID: requestID) }
            do {
                let artifact = try await context.recording.file(id)
                guard artifact.data.count <= context.limits.mp4Bytes else { return tooLarge(requestID: requestID) }
                return binary(mime: artifact.mime, body: artifact.data, requestID: requestID, sha256: artifact.metadata.sha256)
            } catch let error as ProtocolError {
                return failure(error, status: status(for: error, operation: .recordingResource), requestID: requestID)
            } catch {
                return failure(recordingInternalFailure, status: 500, requestID: requestID)
            }
        }

        await router.register(.delete, pattern: "/v1/recordings/{id}") { _, parameters, requestID in
            guard let id = parameters["id"] else { return missingRecording(requestID: requestID) }
            do {
                try await context.recording.delete(id)
                return success(.object(["recording_id": .string(id), "deleted": .bool(true)]), requestID: requestID)
            } catch let error as ProtocolError {
                return failure(error, status: status(for: error, operation: .recordingResource), requestID: requestID)
            } catch {
                return failure(recordingInternalFailure, status: 500, requestID: requestID)
            }
        }
    }

    private static func registerGET(
        on router: HTTPRouter,
        pattern: String,
        handler: @escaping HTTPRouter.Handler
    ) async {
        await router.register(.get, pattern: pattern, handler: handler)
        await router.register(.head, pattern: pattern, handler: handler)
    }

    private static func success(_ data: JSONValue, requestID: String) -> HTTPResponse {
        let body = (try? ProtocolJSON.success(data: data, requestID: requestID)) ?? Data()
        return responseWithMetadata(.json(status: 200, body: body), requestID: requestID)
    }

    private static func failure(_ error: ProtocolError, status: Int, requestID: String) -> HTTPResponse {
        let body = (try? ProtocolJSON.failure(error: error, requestID: requestID)) ?? Data()
        return responseWithMetadata(.json(status: status, body: body), requestID: requestID)
    }

    private static func binary(
        mime: String,
        body: Data,
        requestID: String,
        sha256: String,
        additionalHeaders: [String: String] = [:]
    ) -> HTTPResponse {
        var headers = additionalHeaders
        headers["Content-Length"] = String(body.count)
        headers["X-IOS-Debug-Protocol-Version"] = String(IOSDebugProtocol.version)
        headers["X-IOS-Debug-Request-ID"] = requestID
        headers["X-IOS-Debug-SHA256"] = sha256
        return .binary(mime: mime, body: body, headers: headers)
    }

    private static func responseWithMetadata(_ response: HTTPResponse, requestID: String) -> HTTPResponse {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["X-IOS-Debug-Protocol-Version"] = String(IOSDebugProtocol.version)
        headers["X-IOS-Debug-Request-ID"] = requestID
        return .init(statusCode: response.statusCode, headers: headers, body: response.body)
    }

    private static func recordingStatus(_ status: RecordingStatus) -> JSONValue {
        .object([
            "state": .string(status.phase.rawValue),
            "elapsed_ms": .number(Double(status.elapsedMilliseconds)),
            "recording_id": status.recording.map { .string($0.id) } ?? .null,
        ])
    }

    private static func tooLarge(requestID: String) -> HTTPResponse {
        failure(.init(code: AppErrorCode.artifactTooLarge.rawValue, message: "The requested artifact exceeds the supported size limit.", hint: "Reduce the payload or capture duration and retry."), status: 413, requestID: requestID)
    }

    private static func missingRecording(requestID: String) -> HTTPResponse {
        failure(.init(code: AppErrorCode.recordingNotAvailable.rawValue, message: "The requested recording is not available.", hint: "Query recording status and use the returned recording identifier."), status: 404, requestID: requestID)
    }

    private static let recordingInternalFailure = ProtocolError(
        code: AppErrorCode.recordingNotAvailable.rawValue,
        message: "The recording operation failed.",
        hint: "Keep the App running, inspect Debug logs, and retry with a new recording."
    )

    private enum ErrorOperation { case action, recordingOperation, recordingResource }

    private static func status(for error: ProtocolError, operation: ErrorOperation) -> Int {
        switch AppErrorCode(rawValue: error.code) {
        case .artifactTooLarge: return 413
        case .actionNotFound: return 404
        case .actionDisabled, .recordingInvalidState: return 409
        case .recordingPermissionTimeout, .requestTimeout: return 504
        case .recordingNotAvailable: return operation == .recordingResource ? 404 : 503
        default: return 500
        }
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }
}

private struct ActivateBody: Decodable {
    let identifier: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["identifier"],
              let key = DynamicCodingKey(stringValue: "identifier")
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected only identifier")) }
        identifier = try container.decode(String.self, forKey: key)
        guard !identifier.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Identifier is empty")
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
#endif
