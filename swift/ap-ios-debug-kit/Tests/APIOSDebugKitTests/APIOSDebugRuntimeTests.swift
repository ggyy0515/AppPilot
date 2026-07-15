#if DEBUG && canImport(UIKit)
import Foundation
@testable import APIOSDebugCore
import Testing
@testable import APIOSDebugKit

@MainActor
private final class RuntimeStateProvider: DebugStateProvider {
    var result: Result<JSONValue, Error> = .success(.object(["screen": .string("home")]))
    var callCount = 0
    func debugState() throws -> JSONValue {
        callCount += 1
        return try result.get()
    }
}

private struct RuntimeTestFailure: Error {}

private enum RuntimeInjectedError: Error, Sendable {
    case protocolError(ProtocolError)
    case internalFailure

    func raise() throws {
        switch self {
        case .protocolError(let error): throw error
        case .internalFailure: throw RuntimeTestFailure()
        }
    }
}

@MainActor
private final class RuntimeEnabledFlag {
    var value = false
}

@MainActor
private final class RuntimeCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor RuntimeEventLog {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor RuntimeGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func wait() async {
        entryCount += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class RuntimeScreenshotFake {
    var result: Result<CapturedScreenshot, Error>
    var callCount = 0

    init(_ screenshot: CapturedScreenshot) { result = .success(screenshot) }
    func capture() throws -> CapturedScreenshot {
        callCount += 1
        return try result.get()
    }
}

private actor RuntimeRecordingFake {
    var available = true
    var current = RecordingStatus(phase: .idle, elapsedMilliseconds: 0, recording: nil, failureCode: nil)
    var startError: RuntimeInjectedError?
    var stopError: RuntimeInjectedError?
    var fileError: RuntimeInjectedError?
    var deleteError: RuntimeInjectedError?
    var fileData = Data("mp4-data".utf8)
    var cleanupCount = 0
    var startCount = 0
    var stopCount = 0
    var fileIDs: [String] = []
    var deleteIDs: [String] = []
    var availableCount = 0
    var statusCount = 0
    let eventLog: RuntimeEventLog?
    let cleanupGate: RuntimeGate?

    init(eventLog: RuntimeEventLog? = nil, cleanupGate: RuntimeGate? = nil) {
        self.eventLog = eventLog
        self.cleanupGate = cleanupGate
    }

    func source() -> APIOSDebugRuntime.RecordingSource {
        .init(
            isAvailable: { await self.readAvailability() },
            status: { await self.readStatus() },
            start: { _ in
                if let error = await self.startError { try error.raise() }
                await self.didStart()
            },
            stop: {
                if let error = await self.stopError { try error.raise() }
                return await self.didStop()
            },
            file: { id in
                if let error = await self.fileError { try error.raise() }
                return await self.didRead(id: id)
            },
            delete: { id in
                if let error = await self.deleteError { try error.raise() }
                await self.didDelete(id: id)
            },
            cleanup: { await self.performCleanup() }
        )
    }

    private func didStart() { startCount += 1 }
    private func didStop() async -> RecordingMetadata {
        stopCount += 1
        await eventLog?.append("recording.stop")
        return Self.metadata
    }
    private func didRead(id: String) -> APIOSDebugRuntime.RecordingArtifact {
        fileIDs.append(id)
        return .init(metadata: Self.metadata, data: fileData, mime: "video/mp4")
    }
    private func didDelete(id: String) { deleteIDs.append(id) }
    private func didCleanup() async {
        cleanupCount += 1
        await eventLog?.append("recording.cleanup")
    }
    private func performCleanup() async {
        await cleanupGate?.wait()
        await didCleanup()
    }
    private func readAvailability() -> Bool {
        availableCount += 1
        return available
    }
    private func readStatus() -> RecordingStatus {
        statusCount += 1
        return current
    }

    static let metadata = RecordingMetadata(
        id: "recording-1",
        byteCount: 8,
        durationMilliseconds: 1_234,
        sha256: SHA256.hexDigest(Data("mp4-data".utf8)),
        createdAt: .init(milliseconds: 1_234)
    )
}

private actor RuntimeServerFake {
    var isRunning = false
    var startAttemptCount = 0
    var startCount = 0
    var stopCount = 0
    var startError: ProtocolError?
    let eventLog: RuntimeEventLog?
    let startGate: RuntimeGate?
    let stopGate: RuntimeGate?
    init(eventLog: RuntimeEventLog? = nil, startGate: RuntimeGate? = nil, stopGate: RuntimeGate? = nil) {
        self.eventLog = eventLog
        self.startGate = startGate
        self.stopGate = stopGate
    }
    func source() -> APIOSDebugRuntime.ServerSource {
        .init(
            start: { try await self.performStart() },
            stop: { await self.performStop() }
        )
    }
    private func performStart() async throws {
        startAttemptCount += 1
        await startGate?.wait()
        if let startError { throw startError }
        startCount += 1
        isRunning = true
        await eventLog?.append("server.start")
    }
    private func performStop() async {
        await stopGate?.wait()
        stopCount += 1
        isRunning = false
        await eventLog?.append("server.stop")
    }
}

private struct RuntimeHarness {
    let runtime: APIOSDebugRuntime
    let state: RuntimeStateProvider
    let screenshot: RuntimeScreenshotFake
    let activationCount: RuntimeCounter
    let recording: RuntimeRecordingFake
    let server: RuntimeServerFake
    let eventLog: RuntimeEventLog
}

@MainActor
private func makeRuntime(
    token: String? = "secret",
    maximumRequestBodyBytes: Int = APIOSDebugProtocol.maximumRequestBodyBytes,
    maximumPNGBytes: Int = APIOSDebugProtocol.maximumPNGBytes,
    maximumMP4Bytes: Int = APIOSDebugProtocol.maximumMP4Bytes,
    cleanupGate: RuntimeGate? = nil,
    serverStartGate: RuntimeGate? = nil,
    serverStopGate: RuntimeGate? = nil
) async throws -> RuntimeHarness {
    let eventLog = RuntimeEventLog()
    let state = RuntimeStateProvider()
    let actions = DebugActionRegistry()
    let activationCount = RuntimeCounter()
    _ = try actions.register(identifier: "header.settings", role: .navigation, description: "Open settings") {
        activationCount.increment()
    }
    let recording = RuntimeRecordingFake(eventLog: eventLog, cleanupGate: cleanupGate)
    let recordingSource = await recording.source()
    let server = RuntimeServerFake(eventLog: eventLog, startGate: serverStartGate, stopGate: serverStopGate)
    let serverSource = await server.source()
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    let screenshot = CapturedScreenshot(
        pngData: png,
        method: .drawHierarchy,
        pixelWidth: 20,
        pixelHeight: 40,
        scale: 2,
        sha256: SHA256.hexDigest(png)
    )
    let screenshotFake = RuntimeScreenshotFake(screenshot)
    let runtime = APIOSDebugRuntime(
        configuration: try .init(port: 9_876, bearerToken: token, maximumRecordingDuration: .seconds(12)),
        stateProvider: state,
        actionRegistry: actions,
        screenshotFactory: { .init(capture: { try screenshotFake.capture() }) },
        recordingFactory: { recordingSource },
        serverFactory: { _, _ in serverSource },
        limits: .init(
            requestBodyBytes: maximumRequestBodyBytes,
            pngBytes: maximumPNGBytes,
            mp4Bytes: maximumMP4Bytes
        )
    )
    await runtime.waitForRouteRegistrationForTesting()
    return .init(
        runtime: runtime, state: state, screenshot: screenshotFake, activationCount: activationCount, recording: recording, server: server, eventLog: eventLog)
}

@MainActor
private func request(
    _ harness: RuntimeHarness,
    _ method: HTTPMethod,
    _ path: String,
    body: Data = Data(),
    contentType: String? = nil,
    authorize: Bool = true
) async -> HTTPResponse {
    var headers: [String: String] = [:]
    if authorize { headers["authorization"] = "Bearer secret" }
    if let contentType { headers["content-type"] = contentType }
    return await harness.runtime.responseForTesting(.init(method: method, path: path, headers: headers, body: body))
}

private func json(_ response: HTTPResponse) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: response.body)
}

private func keys(_ value: JSONValue?, at path: String = "") -> Set<String> {
    let target = path.isEmpty ? value : value?.value(at: path)
    guard case .object(let object) = target else { return [] }
    return Set(object.keys)
}

private func expectJSONMetadata(_ response: HTTPResponse) throws {
    let payload = try json(response)
    #expect(keys(payload, at: "meta") == ["protocol_version", "request_id"])
    #expect(payload.value(at: "meta.protocol_version") == .number(1))
    guard case .string(let requestID) = payload.value(at: "meta.request_id") else {
        Issue.record("Expected string request_id")
        return
    }
    #expect(!requestID.isEmpty)
    #expect(response.headers["X-IOS-Debug-Protocol-Version"] == "1")
    #expect(response.headers["X-IOS-Debug-Request-ID"] == requestID)
    #expect(response.headers["Content-Length"] == String(response.body.count))
}

private func waitForEntry(into gate: RuntimeGate) async {
    while await gate.entryCount == 0 { await Task.yield() }
}

extension JSONValue {
    fileprivate func value(at path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { value, component in
            guard let value else { return nil }
            if case .object(let object) = value { return object[String(component)] }
            if case .array(let array) = value, let index = Int(component), array.indices.contains(index) { return array[index] }
            return nil
        }
    }
}

@Test @MainActor func configurationRejectsInvalidValues() throws {
    #expect(throws: ProtocolError.self) { try APIOSDebugRuntime.Configuration(port: 0) }
    #expect(throws: ProtocolError.self) { try APIOSDebugRuntime.Configuration(bearerToken: "") }
    #expect(throws: ProtocolError.self) { try APIOSDebugRuntime.Configuration(maximumRecordingDuration: .zero) }
    #expect(throws: ProtocolError.self) { try APIOSDebugRuntime.Configuration(maximumRecordingDuration: .seconds(601)) }
}

@Test @MainActor func allJSONRoutesUseExactSchemasAndMetadata() async throws {
    let harness = try await makeRuntime()

    let health = await request(harness, .get, "/v1/health", authorize: false)
    #expect(health.statusCode == 200)
    #expect(health.headers["Content-Type"] == "application/json; charset=utf-8")
    #expect(keys(try json(health)) == ["ok", "data", "meta"])
    #expect(keys(try json(health), at: "data") == ["protocol_version", "auth_required", "reachable"])
    #expect(try json(health).value(at: "data.protocol_version") == .number(1))
    #expect(try json(health).value(at: "data.auth_required") == .bool(true))
    #expect(try json(health).value(at: "data.reachable") == .bool(true))
    try expectJSONMetadata(health)

    let trustedHostHealth = await request(try await makeRuntime(token: nil), .get, "/v1/health", authorize: false)
    #expect(
        keys(try json(trustedHostHealth), at: "data") == [
            "service", "app_bundle_identifier", "app_version", "protocol_version", "auth_required", "reachable",
        ])
    #expect(try json(trustedHostHealth).value(at: "data.service") == .string("ap-ios-debug"))
    #expect(try json(trustedHostHealth).value(at: "data.auth_required") == .bool(false))
    #expect(try json(trustedHostHealth).value(at: "data.reachable") == .bool(true))

    let capabilities = await request(harness, .get, "/v1/capabilities")
    #expect(keys(try json(capabilities), at: "data") == ["protocol_version", "actions", "state", "screenshot", "recording", "limits"])
    #expect(
        keys(try json(capabilities), at: "data.limits") == [
            "header_bytes", "request_body_bytes", "state_bytes", "png_bytes", "mp4_bytes", "recording_default_seconds", "recording_maximum_seconds",
        ])
    #expect(try json(capabilities).value(at: "data.actions") == .bool(true))
    #expect(try json(capabilities).value(at: "data.recording") == .bool(true))
    #expect(try json(capabilities).value(at: "data.limits.mp4_bytes") == .number(Double(APIOSDebugProtocol.maximumMP4Bytes)))
    #expect(try json(capabilities).value(at: "data.limits.recording_default_seconds") == .number(12))
    #expect(try json(capabilities).value(at: "data.limits.recording_maximum_seconds") == .number(600))
    try expectJSONMetadata(capabilities)

    let actions = await request(harness, .get, "/v1/actions")
    let actionsJSON = try json(actions)
    #expect(keys(actionsJSON, at: "data") == ["generation", "actions"])
    #expect(keys(actionsJSON, at: "data.actions.0") == ["identifier", "role", "description", "enabled", "generation"])
    #expect(actionsJSON.value(at: "data.actions.0.identifier") == .string("header.settings"))
    #expect(actionsJSON.value(at: "data.actions.0.role") == .string("navigation"))
    #expect(actionsJSON.value(at: "data.actions.0.description") == .string("Open settings"))
    #expect(actionsJSON.value(at: "data.actions.0.enabled") == .bool(true))
    #expect(actionsJSON.value(at: "data.actions.0.generation") == actionsJSON.value(at: "data.generation"))
    #expect(actions.headers["X-IOS-Debug-Protocol-Version"] == "1")
    try expectJSONMetadata(actions)

    let activate = await request(
        harness, .post, "/v1/actions/activate",
        body: Data(#"{"identifier":"header.settings"}"#.utf8), contentType: "application/json"
    )
    #expect(activate.statusCode == 200)
    #expect(keys(try json(activate), at: "data") == ["identifier", "generation", "activated"])
    #expect(try json(activate).value(at: "data.identifier") == .string("header.settings"))
    #expect(try json(activate).value(at: "data.activated") == .bool(true))
    try expectJSONMetadata(activate)

    let state = await request(harness, .get, "/v1/state")
    #expect(keys(try json(state), at: "data") == ["screen"])
    #expect(try json(state).value(at: "data.screen") == .string("home"))
    try expectJSONMetadata(state)

    for path in ["/v1/recording/status", "/v1/recording/start"] {
        let method: HTTPMethod = path.hasSuffix("start") ? .post : .get
        let response = await request(harness, method, path)
        #expect(response.statusCode == 200)
        #expect(keys(try json(response), at: "data") == ["state", "elapsed_ms", "recording_id"])
        #expect(try json(response).value(at: "data.state") == .string("idle"))
        #expect(try json(response).value(at: "data.elapsed_ms") == .number(0))
        #expect(try json(response).value(at: "data.recording_id") == .null)
        try expectJSONMetadata(response)
    }

    let stop = await request(harness, .post, "/v1/recording/stop")
    #expect(keys(try json(stop), at: "data") == ["recording_id", "byte_count", "duration_ms", "sha256", "mime"])
    #expect(try json(stop).value(at: "data.recording_id") == .string("recording-1"))
    #expect(try json(stop).value(at: "data.byte_count") == .number(8))
    #expect(try json(stop).value(at: "data.duration_ms") == .number(1_234))
    #expect(try json(stop).value(at: "data.mime") == .string("video/mp4"))
    #expect(try json(stop).value(at: "data.sha256") == .string(RuntimeRecordingFake.metadata.sha256))
    try expectJSONMetadata(stop)

    let deleted = await request(harness, .delete, "/v1/recordings/recording-1")
    #expect(keys(try json(deleted), at: "data") == ["recording_id", "deleted"])
    #expect(try json(deleted).value(at: "data.recording_id") == .string("recording-1"))
    #expect(try json(deleted).value(at: "data.deleted") == .bool(true))
    try expectJSONMetadata(deleted)
}

@Test @MainActor func binaryRoutesUseExactBodiesHeadersLengthsAndHead() async throws {
    let harness = try await makeRuntime()
    let screenshot = await request(harness, .get, "/v1/screenshot")
    #expect(screenshot.statusCode == 200)
    #expect(screenshot.headers["Content-Type"] == "image/png")
    #expect(screenshot.headers["X-IOS-Debug-Capture-Method"] == "draw_hierarchy")
    #expect(screenshot.headers["X-IOS-Debug-Pixel-Width"] == "20")
    #expect(screenshot.headers["X-IOS-Debug-Pixel-Height"] == "40")
    #expect(screenshot.headers["X-IOS-Debug-Scale"] == "2.0")
    #expect(screenshot.headers["X-IOS-Debug-Protocol-Version"] == "1")
    #expect(screenshot.headers["X-IOS-Debug-Request-ID"]?.isEmpty == false)
    #expect(screenshot.headers["Content-Length"] == String(screenshot.body.count))
    #expect(
        Set(screenshot.headers.keys) == [
            "Content-Type", "Content-Length", "X-IOS-Debug-Protocol-Version", "X-IOS-Debug-Request-ID",
            "X-IOS-Debug-SHA256", "X-IOS-Debug-Capture-Method", "X-IOS-Debug-Pixel-Width",
            "X-IOS-Debug-Pixel-Height", "X-IOS-Debug-Scale",
        ])

    let recording = await request(harness, .get, "/v1/recordings/recording-1")
    #expect(recording.body == Data("mp4-data".utf8))
    #expect(recording.headers["Content-Type"] == "video/mp4")
    #expect(recording.headers["X-IOS-Debug-SHA256"] == RuntimeRecordingFake.metadata.sha256)
    #expect(recording.headers["Content-Length"] == "8")
    #expect(
        Set(recording.headers.keys) == [
            "Content-Type", "Content-Length", "X-IOS-Debug-Protocol-Version", "X-IOS-Debug-Request-ID", "X-IOS-Debug-SHA256",
        ])

    let head = await request(harness, .head, "/v1/recordings/recording-1")
    #expect(head.statusCode == 200)
    #expect(head.body == recording.body)
    #expect(head.serialized(headOnly: true).suffix(recording.body.count) != recording.body)
    #expect(head.serialized(headOnly: true).contains(Data("Content-Length: 8".utf8)))

    let screenshotHead = await request(harness, .head, "/v1/screenshot")
    #expect(
        screenshotHead.headers
            == screenshot.headers.filter { $0.key != "X-IOS-Debug-Request-ID" }.merging([
                "X-IOS-Debug-Request-ID": screenshotHead.headers["X-IOS-Debug-Request-ID"]!
            ]) { _, new in new })
    #expect(screenshotHead.serialized(headOnly: true).count < screenshotHead.serialized(headOnly: false).count)
}

@Test @MainActor func headDelegatesToEveryRegisteredGETAndOmitsOnlyWireBody() async throws {
    let harness = try await makeRuntime()
    for path in [
        "/v1/health", "/v1/capabilities", "/v1/actions", "/v1/state", "/v1/screenshot",
        "/v1/recording/status", "/v1/recordings/recording-1",
    ] {
        let get = await request(harness, .get, path)
        let head = await request(harness, .head, path)
        #expect(head.statusCode == get.statusCode, "HEAD status mismatch for \(path)")
        #expect(head.headers["Content-Type"] == get.headers["Content-Type"])
        #expect(head.headers["Content-Length"] == get.headers["Content-Length"])
        #expect(head.body.count == get.body.count)
        let wire = head.serialized(headOnly: true)
        #expect(wire.suffix(4) == Data("\r\n\r\n".utf8))
        #expect(wire.count < head.serialized(headOnly: false).count)
    }
}

@Test @MainActor func authAndUnknownRoutesNeverReachDependencies() async throws {
    let harness = try await makeRuntime()
    #expect((await request(harness, .get, "/v1/health", authorize: false)).statusCode == 200)
    let protectedRoutes: [(HTTPMethod, String)] = [
        (.head, "/v1/health"), (.get, "/v1/capabilities"), (.get, "/v1/actions"),
        (.post, "/v1/actions/activate"), (.get, "/v1/state"), (.get, "/v1/screenshot"),
        (.get, "/v1/recording/status"), (.post, "/v1/recording/start"), (.post, "/v1/recording/stop"),
        (.get, "/v1/recordings/recording-1"), (.delete, "/v1/recordings/recording-1"),
    ]
    for (method, path) in protectedRoutes {
        let response = await request(harness, method, path, authorize: false)
        #expect(response.statusCode == 401, "Expected auth on \(method.rawValue) \(path)")
        #expect(try json(response).value(at: "error.code") == .string("auth_required"))
        #expect(keys(try json(response)) == ["ok", "error", "meta"])
        #expect(keys(try json(response), at: "error") == ["code", "message", "hint"])
    }

    for (method, path, expected) in [
        (HTTPMethod.get, "/v1/unknown", 404),
        (.delete, "/v1/screenshot", 405),
        (.post, "/v1/state", 405),
        (.get, "/v1/recordings/invalid$id", 404),
    ] {
        #expect((await request(harness, method, path)).statusCode == expected)
    }
    #expect(harness.state.callCount == 0)
    #expect(harness.screenshot.callCount == 0)
    #expect(harness.activationCount.value == 0)
    #expect(await harness.recording.availableCount == 0)
    #expect(await harness.recording.statusCount == 0)
    #expect(await harness.recording.startCount == 0)
    #expect(await harness.recording.stopCount == 0)
    #expect(await harness.recording.fileIDs.isEmpty)
    #expect(await harness.recording.deleteIDs.isEmpty)
}

@Test @MainActor func malformedActivationAndActionErrorsMapToStableStatuses() async throws {
    let harness = try await makeRuntime()
    for body in [Data(), Data(#"{"identifier":"header.settings","extra":true}"#.utf8), Data(#"{}"#.utf8)] {
        let response = await request(harness, .post, "/v1/actions/activate", body: body, contentType: "application/json")
        #expect(response.statusCode == 400)
    }
    #expect((await request(harness, .post, "/v1/actions/activate", body: Data(#"{"identifier":"header.settings"}"#.utf8))).statusCode == 400)
    let missing = await request(harness, .post, "/v1/actions/activate", body: Data(#"{"identifier":"missing.action"}"#.utf8), contentType: "application/json")
    #expect(missing.statusCode == 404)

    let enabled = RuntimeEnabledFlag()
    _ = try harness.runtime.actions.register(identifier: "disabled.action", role: .mutation, description: "Disabled", isEnabled: { enabled.value }) {}
    let disabled = await request(harness, .post, "/v1/actions/activate", body: Data(#"{"identifier":"disabled.action"}"#.utf8), contentType: "application/json")
    #expect(disabled.statusCode == 409)
    enabled.value = true
    _ = try harness.runtime.actions.register(identifier: "failing.action", role: .mutation, description: "Fails") { throw RuntimeTestFailure() }
    let failed = await request(harness, .post, "/v1/actions/activate", body: Data(#"{"identifier":"failing.action"}"#.utf8), contentType: "application/json")
    #expect(failed.statusCode == 500)
}

@Test @MainActor func activationRejectsInjectedOverLimitBodyBeforeCallingAction() async throws {
    let harness = try await makeRuntime(maximumRequestBodyBytes: 7)
    let response = await request(
        harness, .post, "/v1/actions/activate",
        body: Data(#"{"identifier":"header.settings"}"#.utf8), contentType: "application/json"
    )
    #expect(response.statusCode == 413)
    #expect(try json(response).value(at: "error.code") == .string("artifact_too_large"))
    #expect(harness.activationCount.value == 0)
}

@Test @MainActor func domainFailuresAndLimitsMapToProtocolStatuses() async throws {
    let harness = try await makeRuntime()
    harness.state.result = .failure(RuntimeTestFailure())
    #expect((await request(harness, .get, "/v1/state")).statusCode == 500)

    await harness.recording.setStartError(.protocolError(.init(code: "recording_not_available", message: "Unavailable", hint: "Retry")))
    #expect((await request(harness, .post, "/v1/recording/start")).statusCode == 503)
    await harness.recording.setStartError(.protocolError(.init(code: "recording_permission_timeout", message: "Timeout", hint: "Retry")))
    #expect((await request(harness, .post, "/v1/recording/start")).statusCode == 504)
    for (error, expected) in [
        (ProtocolError(code: "recording_invalid_state", message: "Conflict", hint: "Wait"), 409),
        (.init(code: "recording_not_available", message: "Unavailable", hint: "Retry"), 503),
        (.init(code: "request_timeout", message: "Timeout", hint: "Resume"), 504),
    ] {
        await harness.recording.setStopError(.protocolError(error))
        let response = await request(harness, .post, "/v1/recording/stop")
        #expect(response.statusCode == expected)
        #expect(try json(response).value(at: "error.code") == .string(error.code))
    }
    await harness.recording.setFileError(.protocolError(.init(code: "recording_not_available", message: "Missing", hint: "Retry")))
    #expect((await request(harness, .get, "/v1/recordings/missing")).statusCode == 404)

    let oversizedHarness = try await makeRuntime(maximumMP4Bytes: 7)
    let oversizedData = Data(repeating: 0, count: 8)
    await oversizedHarness.recording.setFile(data: oversizedData)
    #expect((await request(oversizedHarness, .get, "/v1/recordings/recording-1")).statusCode == 413)
}

@Test @MainActor func screenshotFailureAndInjectedSizeLimitUseStableErrors() async throws {
    let failed = try await makeRuntime()
    failed.screenshot.result = .failure(RuntimeTestFailure())
    let failure = await request(failed, .get, "/v1/screenshot")
    #expect(failure.statusCode == 500)
    #expect(try json(failure).value(at: "error.code") == .string("screenshot_failed"))

    let oversized = try await makeRuntime(maximumPNGBytes: 7)
    let response = await request(oversized, .get, "/v1/screenshot")
    #expect(response.statusCode == 413)
    #expect(try json(response).value(at: "error.code") == .string("artifact_too_large"))
}

@Test @MainActor func recordingDownloadRetriesAndOnlyExplicitDeleteRemovesArtifact() async throws {
    let harness = try await makeRuntime()
    await harness.recording.setFileError(.internalFailure)
    #expect((await request(harness, .get, "/v1/recordings/recording-1")).statusCode == 500)
    #expect(await harness.recording.deleteIDs.isEmpty)

    await harness.recording.setFileError(nil)
    #expect((await request(harness, .get, "/v1/recordings/recording-1")).statusCode == 200)
    #expect((await request(harness, .head, "/v1/recordings/recording-1")).statusCode == 200)
    #expect(await harness.recording.fileIDs == ["recording-1", "recording-1"])
    #expect(await harness.recording.deleteIDs.isEmpty)

    #expect((await request(harness, .delete, "/v1/recordings/recording-1")).statusCode == 200)
    #expect(await harness.recording.deleteIDs == ["recording-1"])
}

@Test @MainActor func deleteMissingInvalidAndInternalFailuresRemainDistinct() async throws {
    let harness = try await makeRuntime()
    await harness.recording.setDeleteError(
        .protocolError(
            .init(
                code: "recording_not_available", message: "Missing", hint: "Record again"
            )))
    let missing = await request(harness, .delete, "/v1/recordings/missing")
    #expect(missing.statusCode == 404)
    #expect(try json(missing).value(at: "error.code") == .string("recording_not_available"))

    let count = await harness.recording.deleteIDs.count
    #expect((await request(harness, .delete, "/v1/recordings/bad$id")).statusCode == 404)
    #expect(await harness.recording.deleteIDs.count == count)

    await harness.recording.setDeleteError(.internalFailure)
    let internalFailure = await request(harness, .delete, "/v1/recordings/recording-1")
    #expect(internalFailure.statusCode == 500)
    #expect(try json(internalFailure).value(at: "error.code") == .string("recording_not_available"))
}

@Test @MainActor func recordingInternalFailuresAreStableHTTP500Errors() async throws {
    let harness = try await makeRuntime()

    await harness.recording.setStartError(.internalFailure)
    let start = await request(harness, .post, "/v1/recording/start")
    #expect(start.statusCode == 500)
    #expect(try json(start).value(at: "error.code") == .string("recording_not_available"))
    #expect(try json(start).value(at: "error.message") == .string("The recording operation failed."))
    #expect(try json(start).value(at: "error.hint") == .string("Keep the App running, inspect Debug logs, and retry with a new recording."))
    try expectJSONMetadata(start)

    await harness.recording.setStartError(nil)
    await harness.recording.setStopError(.internalFailure)
    let stop = await request(harness, .post, "/v1/recording/stop")
    #expect(stop.statusCode == 500)
    #expect(try json(stop).value(at: "error.code") == .string("recording_not_available"))
    #expect(try json(stop).value(at: "error.message") == .string("The recording operation failed."))
    #expect(try json(stop).value(at: "error.hint") == .string("Keep the App running, inspect Debug logs, and retry with a new recording."))
    try expectJSONMetadata(stop)

    await harness.recording.setStopError(nil)
    await harness.recording.setFileError(.internalFailure)
    let read = await request(harness, .get, "/v1/recordings/recording-1")
    #expect(read.statusCode == 500)
    #expect(try json(read).value(at: "error.code") == .string("recording_not_available"))
    #expect(try json(read).value(at: "error.message") == .string("The recording operation failed."))
    try expectJSONMetadata(read)

    await harness.recording.setFileError(nil)
    await harness.recording.setDeleteError(.internalFailure)
    let delete = await request(harness, .delete, "/v1/recordings/recording-1")
    #expect(delete.statusCode == 500)
    #expect(try json(delete).value(at: "error.code") == .string("recording_not_available"))
    #expect(try json(delete).value(at: "error.message") == .string("The recording operation failed."))
    try expectJSONMetadata(delete)
}

@Test @MainActor func everyRecordingPhaseUsesItsExactWireValue() async throws {
    let harness = try await makeRuntime()
    for phase in [RecordingPhase.idle, .starting, .recording, .stopping, .ready, .failed] {
        let metadata = phase == .ready ? RuntimeRecordingFake.metadata : nil
        await harness.recording.setStatus(
            .init(
                phase: phase,
                elapsedMilliseconds: 42,
                recording: metadata,
                failureCode: phase == .failed ? "recording_not_available" : nil
            ))
        let response = await request(harness, .get, "/v1/recording/status")
        #expect(try json(response).value(at: "data.state") == .string(phase.rawValue))
        #expect(try json(response).value(at: "data.elapsed_ms") == .number(42))
        #expect(try json(response).value(at: "data.recording_id") == metadata.map { .string($0.id) } ?? .null)
    }
}

@Test @MainActor func lifecycleIsIdempotentCleansFirstAndCanRetryStartup() async throws {
    let harness = try await makeRuntime()
    try await harness.runtime.start()
    try await harness.runtime.start()
    #expect(await harness.recording.cleanupCount == 1)
    #expect(await harness.server.startCount == 1)
    #expect(await harness.eventLog.events == ["recording.cleanup", "server.start"])
    await harness.runtime.stop()
    await harness.runtime.stop()
    #expect(await harness.server.stopCount == 1)

    let retry = try await makeRuntime()
    await retry.server.setStartError(.init(code: "server_start_failed", message: "Failed", hint: "Retry"))
    await #expect(throws: ProtocolError.self) { try await retry.runtime.start() }
    await retry.server.setStartError(nil)
    try await retry.runtime.start()
    #expect(await retry.server.startCount == 1)
    #expect(await retry.server.stopCount == 1)
}

@Test @MainActor func concurrentStartsShareStartupWhileCleanupIsSuspended() async throws {
    let gate = RuntimeGate()
    let harness = try await makeRuntime(cleanupGate: gate)

    let first = Task { @MainActor in try await harness.runtime.start() }
    await waitForEntry(into: gate)
    let second = Task { @MainActor in try await harness.runtime.start() }
    await Task.yield()
    await gate.release()

    try await first.value
    try await second.value
    #expect(await harness.recording.cleanupCount == 1)
    #expect(await harness.server.startAttemptCount == 1)
    #expect(await harness.server.startCount == 1)
    await harness.runtime.stop()
}

@Test @MainActor func stopDuringCleanupWaitsForStartupAndLeavesServerStopped() async throws {
    let gate = RuntimeGate()
    let harness = try await makeRuntime(cleanupGate: gate)

    let starting = Task { @MainActor in try await harness.runtime.start() }
    await waitForEntry(into: gate)
    let stopping = Task { @MainActor in await harness.runtime.stop() }
    await Task.yield()
    await gate.release()

    try await starting.value
    await stopping.value
    #expect(await harness.server.startCount == 1)
    #expect(await harness.server.stopCount == 1)
    #expect(await harness.server.isRunning == false)
}

@Test @MainActor func stopDuringServerStartWaitsForListenerAndLeavesItStopped() async throws {
    let gate = RuntimeGate()
    let harness = try await makeRuntime(serverStartGate: gate)

    let starting = Task { @MainActor in try await harness.runtime.start() }
    await waitForEntry(into: gate)
    let stopping = Task { @MainActor in await harness.runtime.stop() }
    await Task.yield()
    await gate.release()

    try await starting.value
    await stopping.value
    #expect(await harness.server.startCount == 1)
    #expect(await harness.server.stopCount == 1)
    #expect(await harness.server.isRunning == false)
}

@Test @MainActor func lateStartupFailureDuringStopRollsBackOnceAndCanRetry() async throws {
    let gate = RuntimeGate()
    let harness = try await makeRuntime(serverStartGate: gate)

    let starting = Task { @MainActor in try await harness.runtime.start() }
    await waitForEntry(into: gate)
    await harness.server.setStartError(.init(code: "server_start_failed", message: "Failed", hint: "Retry"))
    let stopping = Task { @MainActor in await harness.runtime.stop() }
    await Task.yield()
    await gate.release()

    await #expect(throws: ProtocolError.self) { try await starting.value }
    await stopping.value
    #expect(await harness.server.stopCount == 1)
    #expect(await harness.server.isRunning == false)

    await harness.server.setStartError(nil)
    try await harness.runtime.start()
    #expect(await harness.server.startCount == 1)
    #expect(await harness.server.isRunning == true)
    await harness.runtime.stop()
}

@Test @MainActor func concurrentStopsShareShutdownWhileServerStopIsSuspended() async throws {
    let gate = RuntimeGate()
    let harness = try await makeRuntime(serverStopGate: gate)
    try await harness.runtime.start()

    let first = Task { @MainActor in await harness.runtime.stop() }
    await waitForEntry(into: gate)
    let second = Task { @MainActor in await harness.runtime.stop() }
    await Task.yield()
    await gate.release()

    await first.value
    await second.value
    #expect(await harness.server.stopCount == 1)
    #expect(await harness.server.isRunning == false)
}

@Test @MainActor func stopFinalizesAnActiveRecordingOnce() async throws {
    let harness = try await makeRuntime()
    await harness.recording.setStatus(.init(phase: .recording, elapsedMilliseconds: 50, recording: nil, failureCode: nil))
    try await harness.runtime.start()

    await harness.runtime.stop()
    await harness.runtime.stop()

    #expect(await harness.server.stopCount == 1)
    #expect(await harness.recording.stopCount == 1)
    #expect(await harness.eventLog.events == ["recording.cleanup", "server.start", "server.stop", "recording.stop"])
}

extension RuntimeRecordingFake {
    fileprivate func setStartError(_ error: RuntimeInjectedError?) { startError = error }
    fileprivate func setStopError(_ error: RuntimeInjectedError?) { stopError = error }
    fileprivate func setFileError(_ error: RuntimeInjectedError?) { fileError = error }
    fileprivate func setDeleteError(_ error: RuntimeInjectedError?) { deleteError = error }
    fileprivate func setFile(data: Data) { fileData = data }
    fileprivate func setStatus(_ status: RecordingStatus) { current = status }
}

extension RuntimeServerFake {
    fileprivate func setStartError(_ error: ProtocolError?) { startError = error }
}
#endif
