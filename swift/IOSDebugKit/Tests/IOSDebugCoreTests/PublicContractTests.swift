import Foundation
import IOSDebugCore
import Testing

@Suite struct PublicContractTests {
    @Test func frozenProtocolEnvelopesDecodeAndEncodeWithoutDrift() throws {
        let successFixture = Data(#"{"data":{"ready":true},"meta":{"protocol_version":1,"request_id":"req-fixture"},"ok":true}"#.utf8)
        let failureFixture = Data(
            #"{"error":{"code":"auth_failed","hint":"Retry.","message":"Denied."},"meta":{"protocol_version":1,"request_id":"req-fixture"},"ok":false}"#.utf8)

        let success = try JSONDecoder().decode(JSONValue.self, from: successFixture)
        let failure = try JSONDecoder().decode(JSONValue.self, from: failureFixture)
        #expect(
            success
                == .object([
                    "data": .object(["ready": .bool(true)]),
                    "meta": .object(["protocol_version": .number(1), "request_id": .string("req-fixture")]),
                    "ok": .bool(true),
                ]))
        #expect(
            failure
                == .object([
                    "error": .object(["code": .string("auth_failed"), "hint": .string("Retry."), "message": .string("Denied.")]),
                    "meta": .object(["protocol_version": .number(1), "request_id": .string("req-fixture")]),
                    "ok": .bool(false),
                ]))
        #expect(try ProtocolJSON.success(data: .object(["ready": .bool(true)]), requestID: "req-fixture") == successFixture)
        #expect(
            try ProtocolJSON.failure(
                error: ProtocolError(code: "auth_failed", message: "Denied.", hint: "Retry."),
                requestID: "req-fixture"
            ) == failureFixture)
    }

    @Test func protocolConstantsAndOwnedErrorCodesStayFrozen() {
        #expect(IOSDebugProtocol.version == 1)
        #expect(IOSDebugProtocol.defaultPort == 9_876)
        #expect(IOSDebugProtocol.maximumHeaderBytes == 32 * 1_024)
        #expect(IOSDebugProtocol.maximumRequestBodyBytes == 1 * 1_024 * 1_024)
        #expect(IOSDebugProtocol.maximumStateBytes == 4 * 1_024 * 1_024)
        #expect(IOSDebugProtocol.maximumPNGBytes == 25 * 1_024 * 1_024)
        #expect(IOSDebugProtocol.maximumMP4Bytes == 500 * 1_024 * 1_024)
        #expect(SHA256.hexDigest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let ownedCodes = AppErrorCode.allCases.map(\.rawValue)
        #expect(
            ownedCodes == [
                "config_invalid", "app_not_reachable", "request_timeout", "protocol_mismatch",
                "auth_required", "auth_failed", "action_not_found", "action_disabled", "action_failed",
                "state_encoding_failed", "screenshot_failed", "recording_not_available",
                "recording_invalid_state", "recording_permission_timeout", "artifact_too_large",
            ])
        #expect(ownedCodes.count == 15)
    }

    @Test func everyCorePublicSignatureAndRouteCompiles() async throws {
        let jsonValues: [JSONValue] = [
            .null, .bool(true), .number(1), .string("value"), .array([]), .object([:]),
        ]
        #expect(try JSONValue.encode(jsonValues) == .array(jsonValues))
        _ = try JSONEncoder().encode(jsonValues)

        let methods: [HTTPMethod] = [.get, .head, .post, .delete]
        #expect(methods.map(\.rawValue) == ["GET", "HEAD", "POST", "DELETE"])
        let parseErrors: [HTTPParseError] = [
            .headerTooLarge, .bodyTooLarge, .malformedRequest, .unsupportedMethod,
            .unsupportedTransferEncoding, .invalidPath, .trailingBytes,
        ]
        #expect(parseErrors.count == 7)

        var parser = HTTPRequestParser(
            maximumHeaderBytes: IOSDebugProtocol.maximumHeaderBytes,
            maximumBodyBytes: IOSDebugProtocol.maximumRequestBodyBytes
        )
        let parsedRequest = try parser.append(Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        let request = try #require(parsedRequest)
        #expect(request.method == .get)
        #expect(request.path == "/v1/health")
        #expect(request.headers["host"] == "localhost")
        #expect(request.body.isEmpty)
        #expect(parser.maximumHeaderBytes == IOSDebugProtocol.maximumHeaderBytes)
        #expect(parser.maximumBodyBytes == IOSDebugProtocol.maximumRequestBodyBytes)

        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data())
        _ = HTTPResponse.json(status: 200, body: Data())
        _ = HTTPResponse.binary(status: 200, mime: "image/png", body: Data(), headers: [:])
        #expect(response.serialized(headOnly: true).contains(Data("HTTP/1.1 200 OK".utf8)))
        #expect(response.statusCode == 200 && response.headers.isEmpty && response.body.isEmpty)

        let authenticator = BearerAuthenticator(token: nil)
        #expect(authenticator.authorize(request, isHealth: true) == nil)
        let router = HTTPRouter(authenticator: authenticator)
        let routes: [(HTTPMethod, String)] = [
            (.get, "/v1/health"),
            (.get, "/v1/capabilities"),
            (.get, "/v1/actions"),
            (.post, "/v1/actions/activate"),
            (.get, "/v1/state"),
            (.get, "/v1/screenshot"),
            (.get, "/v1/recording/status"),
            (.post, "/v1/recording/start"),
            (.post, "/v1/recording/stop"),
            (.get, "/v1/recordings/{id}"),
            (.delete, "/v1/recordings/{id}"),
        ]
        for (method, pattern) in routes {
            await router.register(method, pattern: pattern) { request, parameters, requestID in
                _ = request.method
                _ = parameters.values
                _ = parameters["id"]
                return .json(status: 200, body: try ProtocolJSON.success(data: .string(requestID), requestID: requestID))
            }
        }
        #expect(await router.response(to: request).statusCode == 200)

        let zero = RecordingInstant(milliseconds: 0)
        let oneSecond = RecordingInstant.seconds(1)
        #expect(zero < oneSecond)
        #expect(zero.milliseconds == 0)
        let metadata = RecordingMetadata(
            id: "recording-1", byteCount: 1, durationMilliseconds: 1_000,
            sha256: String(repeating: "0", count: 64), createdAt: oneSecond
        )
        let status = RecordingStatus(
            phase: .ready, elapsedMilliseconds: 1_000, recording: metadata, failureCode: nil
        )
        #expect(status.phase == .ready)
        #expect(status.elapsedMilliseconds == 1_000)
        #expect(status.recording == metadata)
        #expect(status.failureCode == nil)
        #expect(metadata.id == "recording-1")
        #expect(metadata.byteCount == 1)
        #expect(metadata.durationMilliseconds == 1_000)
        #expect(metadata.sha256 == String(repeating: "0", count: 64))
        #expect(metadata.createdAt == oneSecond)
        let protocolError = ProtocolError(code: AppErrorCode.authFailed.rawValue, message: "Denied.", hint: "Retry.")
        #expect(protocolError.code == "auth_failed")
        #expect(protocolError.message == "Denied.")
        #expect(protocolError.hint == "Retry.")
        #expect(
            [RecordingPhase.idle, .starting, .recording, .stopping, .ready, .failed].map(\.rawValue) == [
                "idle", "starting", "recording", "stopping", "ready", "failed",
            ])
        let events: [RecordingEvent] = [
            .startRequested(at: zero, maximumDuration: oneSecond), .captureStarted(at: zero),
            .stopRequested(at: zero), .writerFinished(metadata), .failed(code: "failure", at: zero),
            .permissionTimedOut(at: zero), .stopTimedOut(at: zero), .maximumDurationReached(at: zero),
            .downloadedAndDeleted(id: metadata.id), .reset,
        ]
        #expect(events.count == 10)
        var machine = RecordingStateMachine()
        #expect(machine.status.phase == .idle)
        try machine.apply(.startRequested(at: zero, maximumDuration: oneSecond))
        let retention = RecordingRetentionEntry(identifier: metadata.id, phase: .ready, createdAt: zero)
        #expect(retention.identifier == metadata.id && retention.phase == .ready && retention.createdAt == zero)
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: oneSecond, entries: [retention]).isEmpty)
    }
}

#if DEBUG && canImport(UIKit)
import IOSDebugKit
import SwiftUI
import UIKit

@MainActor private final class PublicContractStateProvider: DebugStateProvider {
    func debugState() throws -> JSONValue { .object(["ready": .bool(true)]) }
}

@MainActor private func compileIOSDebugRuntimePublicContract() async throws {
    let configuration = try IOSDebugRuntime.Configuration(
        port: IOSDebugProtocol.defaultPort,
        bearerToken: nil,
        maximumRecordingDuration: .seconds(120)
    )
    _ = (configuration.port, configuration.bearerToken, configuration.maximumRecordingDuration)
    let provider = PublicContractStateProvider()
    let encodableProvider = EncodableDebugStateProvider { ["ready": true] }
    _ = try encodableProvider.debugState()

    let registry = DebugActionRegistry()
    _ = DebugActionRegistry.shared
    let token = try registry.register(
        identifier: "screen.open",
        role: .navigation,
        description: "Open screen",
        isEnabled: { true },
        perform: {}
    )
    let snapshot = registry.snapshot()
    _ = snapshot.generation
    if let descriptor = snapshot.actions.first {
        _ = (
            descriptor.identifier,
            descriptor.role,
            descriptor.description,
            descriptor.isEnabled,
            descriptor.generation
        )
    }
    _ = snapshot.actions
    _ = try await registry.activate(identifier: "screen.open")
    registry.unregister(token)
    _ = [DebugActionRole.navigation, .mutation, .destructive]
    _ = Text("Contract").iosDebugAction(
        "screen.open", role: .navigation, description: "Open screen", isEnabled: { true }, perform: {}
    )

    let runtime = IOSDebugRuntime(configuration: configuration, stateProvider: provider, actionRegistry: registry)
    _ = runtime.actions
    try await runtime.start()
    await runtime.stop()

    let router = HTTPRouter(authenticator: BearerAuthenticator(token: nil))
    let server = try NetworkDebugServer(port: IOSDebugProtocol.defaultPort, router: router)
    try await server.start()
    await server.stop()

    let screenshotCapture = ScreenshotCapture()
    let screenshot = try screenshotCapture.capture()
    _ = (screenshot.pngData, screenshot.method, screenshot.pixelWidth, screenshot.pixelHeight, screenshot.scale, screenshot.sha256)
    _ = [ScreenshotCaptureMethod.drawHierarchy, .layerRender]

    let recordingController = RecordingController()
    _ = await recordingController.isAvailable()
    _ = await recordingController.status()
    try await recordingController.start(maximumDuration: .seconds(120))
    let recording = try await recordingController.stop()
    let file = try await recordingController.file(id: recording.id)
    _ = (file.metadata, file.url, file.mime)
    try await recordingController.delete(id: recording.id)
}
#endif
