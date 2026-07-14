#if DEBUG && canImport(ReplayKit)
import AVFoundation
import Foundation
import IOSDebugCore
import ReplayKit

protocol RecordingClock: Sendable {
    func now() -> RecordingInstant
    func sleep(for duration: Duration) async throws
}

private struct ContinuousRecordingClock: RecordingClock {
    func now() -> RecordingInstant {
        .init(milliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
    }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

protocol ScreenCaptureSource: Sendable {
    func isAvailable() -> Bool
    func start(
        handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async throws
}

private final class ReplayKitCaptureSource: ScreenCaptureSource, @unchecked Sendable {
    private let recorder = RPScreenRecorder.shared()
    func isAvailable() -> Bool { recorder.isAvailable }
    func start(
        handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) async throws {
        recorder.isMicrophoneEnabled = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { buffer, type, error in
                if error == nil { handler(buffer, type) }
                else { failureHandler() }
            }, completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.stopCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

public struct RecordingFile: Sendable, Equatable {
    public let metadata: RecordingMetadata
    public let url: URL
    public let mime: String
}

public actor RecordingController {
    private let source: any ScreenCaptureSource
    private let writerFactory: @Sendable (URL) -> any RecordingWriting
    private let clock: any RecordingClock
    private let storeURL: URL
    private var machine = RecordingStateMachine()
    private var writer: (any RecordingWriting)?
    private var intake: RecordingSampleIntake?
    private var activeID: String?
    private var activeURL: URL?
    private var captureStartedAt: RecordingInstant?
    private var unsettledStartID: String?
    private var automaticStop: Task<Void, Never>?

    public init() {
        source = ReplayKitCaptureSource()
        writerFactory = { RecordingWriter(outputURL: $0) }
        clock = ContinuousRecordingClock()
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("ios-debug-recordings", isDirectory: true)
    }

    init(
        source: any ScreenCaptureSource,
        writerFactory: @escaping @Sendable (URL) -> any RecordingWriting = { RecordingWriter(outputURL: $0) },
        clock: any RecordingClock = ContinuousRecordingClock(),
        storeURL: URL
    ) {
        self.source = source
        self.writerFactory = writerFactory
        self.clock = clock
        self.storeURL = storeURL
    }

    public func isAvailable() -> Bool { source.isAvailable() }
    public func status() -> RecordingStatus {
        let status = machine.status
        guard status.phase == .recording, let captureStartedAt else { return status }
        return RecordingStatus(
            phase: status.phase,
            elapsedMilliseconds: max(0, clock.now().milliseconds - captureStartedAt.milliseconds),
            recording: status.recording,
            failureCode: status.failureCode
        )
    }

    public func start(maximumDuration: Duration = .seconds(120)) async throws {
        guard maximumDuration >= .seconds(1), maximumDuration <= .seconds(600) else {
            throw ProtocolError(code: AppErrorCode.configInvalid.rawValue, message: "Recording duration must be between 1 and 600 seconds.", hint: "Choose a recording duration from 1 through 600 seconds.")
        }
        let milliseconds = try durationMilliseconds(maximumDuration)
        guard unsettledStartID == nil else {
            throw ProtocolError(
                code: AppErrorCode.recordingInvalidState.rawValue,
                message: "Recording operation is invalid while a previous capture start is still resolving.",
                hint: "Wait for the previous screen recording permission callback to finish, then retry."
            )
        }
        if machine.status.phase == .failed { try machine.apply(.reset) }
        let now = clock.now()
        try machine.apply(.startRequested(at: now, maximumDuration: .init(milliseconds: milliseconds)))
        do {
            try cleanup()
            guard source.isAvailable() else { throw CaptureFailure.unavailable }
            let id = UUID().uuidString.lowercased()
            let url = storeURL.appendingPathComponent("\(id).mp4.partial")
            let recordingWriter = writerFactory(url)
            let recordingIntake = RecordingSampleIntake(writer: recordingWriter)
            activeID = id
            activeURL = url
            writer = recordingWriter
            intake = recordingIntake
            unsettledStartID = id
            try await withTimeout(.seconds(60), timeout: CaptureFailure.permissionTimeout) {
                try await self.startCapture(
                    recordingID: id,
                    intake: recordingIntake
                )
            }
            let started = clock.now()
            let failedAtPublication = try recordingIntake.publishCaptureStarted {
                captureStartedAt = started
                try machine.apply(.captureStarted(at: started))
            }
            if failedAtPublication { _ = try await stop() }
            automaticStop = Task { [weak self, clock] in
                do { try await clock.sleep(for: maximumDuration) }
                catch { return }
                await self?.stopIfCurrent(recordingID: id)
            }
        } catch {
            let instant = clock.now()
            let protocolError = mapStartError(error)
            if machine.status.phase == .starting { try? machine.apply(.failed(code: protocolError.code, at: instant)) }
            discardPartial()
            throw protocolError
        }
    }

    public func stop() async throws -> RecordingMetadata {
        let stoppedAt = clock.now()
        try machine.apply(.stopRequested(at: stoppedAt))
        automaticStop?.cancel()
        automaticStop = nil
        do {
            guard let writer, let intake, let id = activeID, let partialURL = activeURL, let started = captureStartedAt else {
                throw CaptureFailure.unavailable
            }
            try await withTimeout(.seconds(90), timeout: CaptureFailure.stopTimeout) {
                try await self.source.stop()
                try Task.checkCancellation()
                try await intake.finishAcceptingAndDrain()
                try Task.checkCancellation()
                try await writer.finish()
            }
            let finalURL = storeURL.appendingPathComponent("\(id).mp4")
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            activeURL = finalURL
            let data = try Data(contentsOf: finalURL, options: .mappedIfSafe)
            guard (1...IOSDebugProtocol.maximumMP4Bytes).contains(data.count) else { throw CaptureFailure.invalidArtifact }
            let metadata = RecordingMetadata(
                id: id,
                byteCount: data.count,
                durationMilliseconds: max(0, stoppedAt.milliseconds - started.milliseconds),
                sha256: SHA256.hexDigest(data),
                createdAt: stoppedAt
            )
            try JSONEncoder().encode(metadata).write(to: metadataURL(id: id), options: .atomic)
            try machine.apply(.writerFinished(metadata))
            activeURL = finalURL
            return metadata
        } catch {
            let protocolError = mapStopError(error)
            try? machine.apply(.failed(code: protocolError.code, at: clock.now()))
            discardPartial()
            throw protocolError
        }
    }

    public func file(id: String) throws -> RecordingFile {
        try cleanup()
        guard let metadata = loadMetadata(id: id) else {
            throw ProtocolError(code: AppErrorCode.recordingNotAvailable.rawValue, message: "The requested recording is not available.", hint: "Query recording status and use the returned recording identifier.")
        }
        let url = storeURL.appendingPathComponent("\(id).mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProtocolError(code: AppErrorCode.recordingNotAvailable.rawValue, message: "The requested recording is not available.", hint: "Create a new recording and retry the download.")
        }
        return RecordingFile(metadata: metadata, url: url, mime: "video/mp4")
    }

    public func delete(id: String) throws {
        let recording = try file(id: id)
        try FileManager.default.removeItem(at: recording.url)
        try? FileManager.default.removeItem(at: metadataURL(id: id))
        if machine.status.phase == .ready, machine.status.recording?.id == id {
            try machine.apply(.downloadedAndDeleted(id: id))
            clearActive()
        }
    }

    func cleanup() throws {
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: storeURL, includingPropertiesForKeys: nil)
        for url in urls where
            url.pathExtension == "partial"
                && url.standardizedFileURL != activeURL?.standardizedFileURL
        {
            try? FileManager.default.removeItem(at: url)
        }
        var metadataByID: [String: RecordingMetadata] = [:]
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) {
                metadataByID[metadata.id] = metadata
            } else { try? FileManager.default.removeItem(at: url) }
        }
        let entries = metadataByID.values.map { RecordingRetentionEntry(identifier: $0.id, phase: .ready, createdAt: $0.createdAt) }
        let identifiers = RecordingRetentionPolicy.identifiersToDelete(now: clock.now(), entries: entries)
        for id in identifiers {
            try? FileManager.default.removeItem(at: storeURL.appendingPathComponent("\(id).mp4"))
            try? FileManager.default.removeItem(at: metadataURL(id: id))
        }
        if
            machine.status.phase == .ready,
            let currentID = machine.status.recording?.id,
            identifiers.contains(currentID)
        {
            try machine.apply(.downloadedAndDeleted(id: currentID))
            clearActive()
        }
        let known = Set(metadataByID.keys)
        for url in urls where url.pathExtension == "mp4" && !known.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        timeout: CaptureFailure,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = TimeoutRaceGate(continuation: continuation)
            let operationTask = Task {
                do { gate.resolve(.success(try await operation()), winner: .operation) }
                catch { gate.resolve(.failure(error), winner: .operation) }
            }
            let timeoutTask = Task { [clock] in
                do {
                    try await clock.sleep(for: duration)
                    gate.resolve(.failure(timeout), winner: .timeout)
                } catch {
                    if !Task.isCancelled { gate.resolve(.failure(error), winner: .timeout) }
                }
            }
            gate.install(operation: operationTask, timeout: timeoutTask)
        }
    }

    private func durationMilliseconds(_ duration: Duration) throws -> Int64 {
        let parts = duration.components
        guard parts.seconds >= 0, parts.attoseconds >= 0 else { throw CaptureFailure.invalidDuration }
        let (seconds, overflow) = parts.seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { throw CaptureFailure.invalidDuration }
        let (result, additionOverflow) = seconds.addingReportingOverflow(parts.attoseconds / 1_000_000_000_000_000)
        guard !additionOverflow else { throw CaptureFailure.invalidDuration }
        return result
    }

    private func metadataURL(id: String) -> URL { storeURL.appendingPathComponent("\(id).json") }
    private func loadMetadata(id: String) -> RecordingMetadata? {
        guard
            let data = try? Data(contentsOf: metadataURL(id: id)),
            let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data),
            metadata.id == id
        else { return nil }
        return metadata
    }
    private func stopIfCurrent(recordingID: String) async {
        guard activeID == recordingID, machine.status.phase == .recording else { return }
        _ = try? await stop()
    }
    private func startCapture(recordingID: String, intake: RecordingSampleIntake) async throws {
        do {
            try await source.start(
                handler: { buffer, type in
                    guard type == .video else { return }
                    intake.enqueue(UncheckedSendableSampleBuffer(buffer))
                },
                failureHandler: { [weak self] in
                    intake.fail(CaptureFailure.unavailable)
                    Task { await self?.stopIfCurrent(recordingID: recordingID) }
                }
            )
        } catch {
            settleStartOperation(recordingID: recordingID)
            throw error
        }

        let belongsToCurrentStart =
            unsettledStartID == recordingID
                && activeID == recordingID
                && machine.status.phase == .starting
        guard belongsToCurrentStart else {
            defer { settleStartOperation(recordingID: recordingID) }
            try? await source.stop()
            throw CancellationError()
        }
        settleStartOperation(recordingID: recordingID)
        do { try intake.throwIfFailed() }
        catch {
            try? await source.stop()
            throw error
        }
    }
    private func settleStartOperation(recordingID: String) {
        if unsettledStartID == recordingID { unsettledStartID = nil }
    }
    private func discardPartial() { if let activeURL { try? FileManager.default.removeItem(at: activeURL) }; clearActive() }
    private func clearActive() {
        automaticStop?.cancel()
        automaticStop = nil
        intake?.stopAccepting()
        intake = nil
        writer = nil
        activeID = nil
        activeURL = nil
        captureStartedAt = nil
    }

    private func mapStartError(_ error: Error) -> ProtocolError {
        if case CaptureFailure.permissionTimeout = error {
            return ProtocolError(code: AppErrorCode.recordingPermissionTimeout.rawValue, message: "Screen recording permission was not granted before the deadline.", hint: "Approve screen recording promptly, keep the App foregrounded, and retry.")
        }
        return ProtocolError(code: AppErrorCode.recordingNotAvailable.rawValue, message: "Screen recording is not available.", hint: "Keep the App foregrounded, confirm ReplayKit is available, and retry.")
    }

    private func mapStopError(_ error: Error) -> ProtocolError {
        if case CaptureFailure.stopTimeout = error {
            return ProtocolError(code: AppErrorCode.requestTimeout.rawValue, message: "Recording finalization exceeded its deadline.", hint: "Keep the App running and retry recording status; if paused at a breakpoint, resume it.")
        }
        return ProtocolError(code: AppErrorCode.recordingNotAvailable.rawValue, message: "The recording could not be finalized.", hint: "Keep the App foregrounded and create a new recording.")
    }

    private enum CaptureFailure: Error, Sendable {
        case unavailable, permissionTimeout, stopTimeout, invalidDuration, invalidArtifact
    }
}

private final class RecordingSampleIntake: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<UncheckedSendableSampleBuffer>.Continuation
    private let worker: Task<Error?, Never>
    private var accepting = true
    private var captureFailure: Error?

    init(writer: any RecordingWriting) {
        let (stream, continuation) = AsyncStream.makeStream(of: UncheckedSendableSampleBuffer.self)
        self.continuation = continuation
        worker = Task {
            do {
                for await sample in stream { try await writer.append(sample) }
                return nil
            } catch { return error }
        }
    }

    func enqueue(_ sample: UncheckedSendableSampleBuffer) {
        lock.withLock {
            guard accepting else { return }
            continuation.yield(sample)
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            if captureFailure == nil { captureFailure = error }
        }
    }

    func stopAccepting() {
        lock.withLock {
            guard accepting else { return }
            accepting = false
            continuation.finish()
        }
    }

    func finishAcceptingAndDrain() async throws {
        stopAccepting()
        if let error = await worker.value { throw error }
        if let error = lock.withLock({ captureFailure }) { throw error }
    }

    func throwIfFailed() throws {
        if let error = lock.withLock({ captureFailure }) { throw error }
    }

    func publishCaptureStarted(_ publication: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try publication()
        return captureFailure != nil
    }
}

private final class TimeoutRaceGate<Value: Sendable>: @unchecked Sendable {
    enum Winner { case operation, timeout }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func install(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.withLock {
            guard continuation != nil else {
                operation.cancel()
                timeout.cancel()
                return
            }
            operationTask = operation
            timeoutTask = timeout
        }
    }

    func resolve(_ result: Result<Value, Error>, winner: Winner) {
        let resolved: (CheckedContinuation<Value, Error>, Task<Void, Never>?)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            let loser = winner == .operation ? timeoutTask : operationTask
            operationTask = nil
            timeoutTask = nil
            return (continuation, loser)
        }
        guard let (continuation, loser) = resolved else { return }
        loser?.cancel()
        continuation.resume(with: result)
    }
}
#endif
