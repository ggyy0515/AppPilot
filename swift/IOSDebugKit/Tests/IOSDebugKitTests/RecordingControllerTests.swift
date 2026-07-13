#if DEBUG && canImport(ReplayKit)
import AVFoundation
import Foundation
import IOSDebugCore
import ReplayKit
import Testing
@testable import IOSDebugKit

private actor FakeCaptureSource: ScreenCaptureSource {
    let available: Bool
    let hangsOnStart: Bool
    let hangsOnStop: Bool
    private var handler: (@Sendable (CMSampleBuffer, RPSampleBufferType) -> Void)?
    private var failureHandler: (@Sendable () -> Void)?
    private var startContinuation: UnsafeContinuation<Void, Never>?
    private var stopContinuation: UnsafeContinuation<Void, Never>?
    private(set) var stopCount = 0

    init(available: Bool = true, hangsOnStart: Bool = false, hangsOnStop: Bool = false) {
        self.available = available
        self.hangsOnStart = hangsOnStart
        self.hangsOnStop = hangsOnStop
    }

    nonisolated func isAvailable() -> Bool { available }
    func start(
        handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) async throws {
        self.handler = handler
        self.failureHandler = failureHandler
        if hangsOnStart { await withUnsafeContinuation { startContinuation = $0 } }
    }
    func stop() async throws {
        stopCount += 1
        if hangsOnStop { await withUnsafeContinuation { stopContinuation = $0 } }
    }
    func emit(_ sequence: [(RPSampleBufferType, Int64)]) {
        for (type, timestamp) in sequence {
            if let sample = makeSampleBuffer(timestamp: timestamp) { handler?(sample, type) }
        }
    }
    func emitFailure() { failureHandler?() }
    func completeLateStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }
    func hasLateStart() -> Bool { startContinuation != nil }
    func completeLateStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
    func hasLateStop() -> Bool { stopContinuation != nil }
}

private actor FakeRecordingWriter: RecordingWriting {
    let url: URL
    var finishError: Error?
    let appendDelay: Duration
    let sabotageMetadataWrite: Bool
    private(set) var finishCount = 0
    private(set) var appendedPresentationTimes: [Int64] = []

    init(
        url: URL,
        bytes: Data = Data("mp4".utf8),
        finishError: Error? = nil,
        appendDelay: Duration = .zero,
        sabotageMetadataWrite: Bool = false
    ) {
        self.url = url
        self.finishError = finishError
        self.appendDelay = appendDelay
        self.sabotageMetadataWrite = sabotageMetadataWrite
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: url)
    }

    func append(_ sample: UncheckedSendableSampleBuffer) async throws {
        if appendDelay > .zero { try await Task.sleep(for: appendDelay) }
        appendedPresentationTimes.append(CMSampleBufferGetPresentationTimeStamp(sample.value).value)
    }
    func finish() async throws {
        finishCount += 1
        if let finishError { throw finishError }
        if sabotageMetadataWrite {
            let id = url.lastPathComponent.replacingOccurrences(of: ".mp4.partial", with: "")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent().appendingPathComponent("\(id).json"),
                withIntermediateDirectories: true
            )
        }
    }
}

private struct FakeFailure: Error {}

private func makeSampleBuffer(timestamp: Int64) -> CMSampleBuffer? {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { return nil }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
          let format else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: timestamp, timescale: 1), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

private struct ImmediateClock: RecordingClock {
    let nowValue: RecordingInstant
    init(milliseconds: Int64 = 10_000) { nowValue = .init(milliseconds: milliseconds) }
    func now() -> RecordingInstant { nowValue }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

private struct DeadlineClock: RecordingClock {
    let immediateMilliseconds: Int64
    func now() -> RecordingInstant { .init(milliseconds: 100_000) }
    func sleep(for duration: Duration) async throws {
        let parts = duration.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        if milliseconds == immediateMilliseconds { return }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }
}

private final class MutableClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(milliseconds: Int64) { value = milliseconds }
    func now() -> RecordingInstant { lock.withLock { .init(milliseconds: value) } }
    func advance(milliseconds: Int64) { lock.withLock { value += milliseconds } }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

private final class GenerationClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var durationContinuation: UnsafeContinuation<Void, Never>?
    func now() -> RecordingInstant { .init(milliseconds: 10_000) }
    func sleep(for duration: Duration) async throws {
        if duration == .seconds(1) {
            await withUnsafeContinuation { continuation in
                lock.withLock { durationContinuation = continuation }
            }
        } else {
            try await Task.sleep(for: .seconds(3_600))
        }
    }
    func hasDurationWaiter() -> Bool { lock.withLock { durationContinuation != nil } }
    func fireOldDuration() {
        let continuation = lock.withLock {
            let value = durationContinuation
            durationContinuation = nil
            return value
        }
        continuation?.resume()
    }
}

private final class FirstPermissionDeadlineClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var permissionSleeps = 0
    func now() -> RecordingInstant { .init(milliseconds: 10_000) }
    func sleep(for duration: Duration) async throws {
        if duration == .seconds(60) {
            let ordinal = lock.withLock {
                permissionSleeps += 1
                return permissionSleeps
            }
            if ordinal == 1 { return }
        }
        try await Task.sleep(for: .seconds(3_600))
    }
}

private actor FirstStartHangsCaptureSource: ScreenCaptureSource {
    let hangsOnStop: Bool
    let stopFails: Bool
    private var firstStart = true
    private var lateStart: UnsafeContinuation<Void, Never>?
    private var lateStop: UnsafeContinuation<Void, Never>?
    private(set) var stopCount = 0
    init(hangsOnStop: Bool = false, stopFails: Bool = false) {
        self.hangsOnStop = hangsOnStop
        self.stopFails = stopFails
    }
    nonisolated func isAvailable() -> Bool { true }
    func start(
        handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) async throws {
        if firstStart {
            firstStart = false
            await withUnsafeContinuation { lateStart = $0 }
        }
    }
    func stop() async throws {
        stopCount += 1
        if stopFails { throw FakeFailure() }
        if hangsOnStop { await withUnsafeContinuation { lateStop = $0 } }
    }
    func hasLateStart() -> Bool { lateStart != nil }
    func completeLateStart() {
        let continuation = lateStart
        lateStart = nil
        continuation?.resume()
    }
    func hasLateStop() -> Bool { lateStop != nil }
    func completeLateStop() {
        let continuation = lateStop
        lateStop = nil
        continuation?.resume()
    }
}

private final class BoundaryFailureCaptureSource: ScreenCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var failureHandler: (@Sendable () -> Void)?
    private var stops = 0
    func isAvailable() -> Bool { true }
    func start(
        handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock { self.failureHandler = failureHandler }
    }
    func stop() async throws { lock.withLock { stops += 1 } }
    func failSynchronously() { lock.withLock { failureHandler }?() }
    func stopCount() -> Int { lock.withLock { stops } }
}

private final class BoundaryFailureClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nowCount = 0
    let source: BoundaryFailureCaptureSource
    init(source: BoundaryFailureCaptureSource) { self.source = source }
    func now() -> RecordingInstant {
        let ordinal = lock.withLock {
            nowCount += 1
            return nowCount
        }
        if ordinal == 3 { source.failSynchronously() }
        return .init(milliseconds: 10_000)
    }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: .seconds(3_600)) }
}

private func temporaryStore() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func unavailableRecorderHasStableError() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(source: FakeCaptureSource(available: false), storeURL: store)
    await #expect(throws: ProtocolError.self) { try await controller.start() }
    #expect(await controller.status().failureCode == "recording_not_available")
}

@Test func missingPermissionCallbackTimesOutWithStableError() async throws {
    let controller = RecordingController(
        source: FakeCaptureSource(hangsOnStart: true),
        clock: DeadlineClock(immediateMilliseconds: 60_000),
        storeURL: try temporaryStore()
    )
    do {
        try await controller.start()
        Issue.record("Expected recording_permission_timeout")
    } catch let error as ProtocolError {
        #expect(error.code == "recording_permission_timeout")
        #expect(error.hint == "Approve screen recording promptly, keep the App foregrounded, and retry.")
    }
}

@Test func lateStartCompletionAfterTimeoutIsIgnoredAndCaptureIsStopped() async throws {
    let source = FakeCaptureSource(hangsOnStart: true)
    let controller = RecordingController(
        source: source,
        clock: DeadlineClock(immediateMilliseconds: 60_000),
        storeURL: try temporaryStore()
    )
    await #expect(throws: ProtocolError.self) { try await controller.start() }

    for _ in 0..<100 where !(await source.hasLateStart()) { await Task.yield() }
    await source.completeLateStart()
    for _ in 0..<100 where await source.stopCount == 0 { await Task.yield() }

    #expect(await source.stopCount == 1)
    #expect(await controller.status().phase == .failed)
}

@Test func pendingTimedOutStartBlocksNewGenerationUntilLateCompletionIsContained() async throws {
    let source = FirstStartHangsCaptureSource()
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: FirstPermissionDeadlineClock(),
        storeURL: try temporaryStore()
    )
    await #expect(throws: ProtocolError.self) { try await controller.start() }

    do {
        try await controller.start()
        Issue.record("Expected the unresolved old ReplayKit start to block a new generation")
    } catch let error as ProtocolError {
        #expect(error.code == "recording_invalid_state")
    }

    for _ in 0..<100 where !(await source.hasLateStart()) { await Task.yield() }
    await source.completeLateStart()
    for _ in 0..<100 where await source.stopCount == 0 { await Task.yield() }
    try await controller.start()

    #expect(await source.stopCount == 1)
    #expect(await controller.status().phase == .recording)
}

@Test func pendingTimedOutStartRemainsLockedUntilLateCaptureStopCompletes() async throws {
    let source = FirstStartHangsCaptureSource(hangsOnStop: true)
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: FirstPermissionDeadlineClock(),
        storeURL: try temporaryStore()
    )
    await #expect(throws: ProtocolError.self) { try await controller.start() }
    for _ in 0..<100 where !(await source.hasLateStart()) { await Task.yield() }
    await source.completeLateStart()
    for _ in 0..<100 where !(await source.hasLateStop()) { await Task.yield() }

    do {
        try await controller.start()
        Issue.record("Expected old capture cleanup to retain the generation lock")
    } catch let error as ProtocolError {
        #expect(error.code == "recording_invalid_state")
    }

    await source.completeLateStop()
    for _ in 0..<100 { await Task.yield() }
    try await controller.start()
    #expect(await controller.status().phase == .recording)
}

@Test func failedLateCaptureStopReleasesGenerationLockAfterCleanupReturns() async throws {
    let source = FirstStartHangsCaptureSource(stopFails: true)
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: FirstPermissionDeadlineClock(),
        storeURL: try temporaryStore()
    )
    await #expect(throws: ProtocolError.self) { try await controller.start() }
    for _ in 0..<100 where !(await source.hasLateStart()) { await Task.yield() }
    await source.completeLateStart()
    for _ in 0..<100 where await source.stopCount == 0 { await Task.yield() }
    for _ in 0..<100 { await Task.yield() }

    try await controller.start()

    #expect(await source.stopCount == 1)
    #expect(await controller.status().phase == .recording)
}

@Test func finalizationTimeoutUsesRequestTimeout() async throws {
    let controller = RecordingController(
        source: FakeCaptureSource(hangsOnStop: true),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: DeadlineClock(immediateMilliseconds: 90_000),
        storeURL: try temporaryStore()
    )
    try await controller.start()
    do {
        _ = try await controller.stop()
        Issue.record("Expected request_timeout")
    } catch let error as ProtocolError {
        #expect(error.code == "request_timeout")
        #expect(error.hint == "Keep the App running and retry recording status; if paused at a breakpoint, resume it.")
    }
}

@Test func lateStopCompletionAfterTimeoutDoesNotFinalizeWriter() async throws {
    let source = FakeCaptureSource(hangsOnStop: true)
    let store = try temporaryStore()
    let writer = FakeRecordingWriter(url: store.appendingPathComponent("writer.mp4.partial"))
    let controller = RecordingController(
        source: source,
        writerFactory: { url in
            try? Data("mp4".utf8).write(to: url)
            return writer
        },
        clock: DeadlineClock(immediateMilliseconds: 90_000),
        storeURL: store
    )
    try await controller.start()
    await #expect(throws: ProtocolError.self) { _ = try await controller.stop() }

    for _ in 0..<100 where !(await source.hasLateStop()) { await Task.yield() }
    await source.completeLateStop()
    for _ in 0..<100 { await Task.yield() }

    #expect(await writer.finishCount == 0)
    #expect(await controller.status().phase == .failed)
}

@Test func maximumDurationRequestsAutomaticStop() async throws {
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: DeadlineClock(immediateMilliseconds: 1_000),
        storeURL: try temporaryStore()
    )
    try await controller.start(maximumDuration: .seconds(1))
    for _ in 0..<1_000 {
        if await controller.status().phase == .ready { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await controller.status().phase == .ready)
}

@Test func rejectsDurationOutsideHardLimit() async throws {
    let controller = RecordingController(source: FakeCaptureSource(), storeURL: try temporaryStore())
    do {
        try await controller.start(maximumDuration: .seconds(601))
        Issue.record("Expected config_invalid")
    } catch let error as ProtocolError {
        #expect(error.code == "config_invalid")
    }
}

@Test(arguments: [
    Duration.seconds(-1),
    .milliseconds(-1),
    .zero,
    .milliseconds(999),
    .milliseconds(600_001),
    .seconds(601),
    .seconds(Int64.max),
])
func rejectsEveryDurationOutsideInclusiveOneToSixHundredSeconds(_ duration: Duration) async throws {
    let controller = RecordingController(source: FakeCaptureSource(), storeURL: try temporaryStore())
    do {
        try await controller.start(maximumDuration: duration)
        Issue.record("Expected config_invalid for \(duration)")
    } catch let error as ProtocolError {
        #expect(error.code == "config_invalid")
    }
}

@Test func concurrentOperationsUseStableInvalidStateError() async throws {
    let controller = RecordingController(source: FakeCaptureSource(), storeURL: try temporaryStore())
    try await controller.start()
    do {
        try await controller.start()
        Issue.record("Expected recording_invalid_state")
    } catch let error as ProtocolError {
        #expect(error.code == "recording_invalid_state")
    }
}

@Test func writerFailureMovesControllerToRecoverableFailedState() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0, finishError: FakeFailure()) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()

    await #expect(throws: ProtocolError.self) { _ = try await controller.stop() }

    #expect(await controller.status().phase == .failed)
    try await controller.start()
    #expect(await controller.status().phase == .recording)
}

@Test func startStopProducesValidMetadataAndFile() async throws {
    let store = try temporaryStore()
    let source = FakeCaptureSource()
    let controller = RecordingController(
        source: source,
        writerFactory: { url in FakeRecordingWriter(url: url) },
        clock: ImmediateClock(),
        storeURL: store
    )

    try await controller.start(maximumDuration: .seconds(120))
    let metadata = try await controller.stop()
    let file = try await controller.file(id: metadata.id)

    #expect(metadata.id == metadata.id.lowercased())
    #expect(metadata.byteCount == 3)
    #expect(metadata.sha256 == SHA256.hexDigest(Data("mp4".utf8)))
    #expect(file.mime == "video/mp4")
    #expect(file.metadata == metadata)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func ignoresAudioAndPreservesVideoCallbackOrder() async throws {
    let source = FakeCaptureSource()
    let store = try temporaryStore()
    let writer = FakeRecordingWriter(url: store.appendingPathComponent("writer.mp4.partial"))
    let controller = RecordingController(
        source: source,
        writerFactory: { url in
            try? Data("mp4".utf8).write(to: url)
            return writer
        },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    await source.emit([(.audioApp, 1), (.video, 2), (.audioMic, 3), (.video, 4)])
    for _ in 0..<100 where await writer.appendedPresentationTimes.count < 2 { await Task.yield() }
    _ = try? await controller.stop()

    #expect(await writer.appendedPresentationTimes == [2, 4])
}

@Test func stopDrainsAllAcceptedVideoFramesInCallbackOrder() async throws {
    let source = FakeCaptureSource()
    let store = try temporaryStore()
    let writer = FakeRecordingWriter(
        url: store.appendingPathComponent("writer.mp4.partial"),
        appendDelay: .milliseconds(2)
    )
    let controller = RecordingController(
        source: source,
        writerFactory: { url in
            try? Data("mp4".utf8).write(to: url)
            return writer
        },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    await source.emit((0..<40).map { (.video, Int64($0)) })

    _ = try await controller.stop()

    #expect(await writer.appendedPresentationTimes == Array(0..<40).map(Int64.init))
    #expect(await writer.finishCount == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await writer.appendedPresentationTimes == Array(0..<40).map(Int64.init))
}

@Test func statusReportsLiveElapsedTimeWhileRecording() async throws {
    let clock = MutableClock(milliseconds: 10_000)
    let controller = RecordingController(source: FakeCaptureSource(), clock: clock, storeURL: try temporaryStore())
    try await controller.start()
    clock.advance(milliseconds: 1_234)

    #expect(await controller.status().elapsedMilliseconds == 1_234)
}

@Test func runtimeCaptureFailureMapsToRecordingNotAvailable() async throws {
    let source = FakeCaptureSource()
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: try temporaryStore()
    )
    try await controller.start()
    await source.emitFailure()

    for _ in 0..<100 where await controller.status().phase != .failed {
        await Task.yield()
    }
    #expect(await controller.status().phase == .failed)
    #expect(await controller.status().failureCode == "recording_not_available")
}

@Test func runtimeFailureBeforeStartCompletionNeverEntersRecording() async throws {
    let source = FakeCaptureSource(hangsOnStart: true)
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: try temporaryStore()
    )
    let start = Task { try await controller.start() }
    for _ in 0..<1_000 where !(await source.hasLateStart()) {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await source.hasLateStart())
    await source.emitFailure()
    await source.completeLateStart()

    do {
        try await start.value
        Issue.record("Expected recording_not_available")
    } catch let error as ProtocolError {
        #expect(error.code == "recording_not_available")
    }
    #expect(await controller.status().phase == .failed)
    #expect(await source.stopCount == 1)
}

@Test func runtimeFailureAtCapturePublicationBoundaryCannotBeLost() async throws {
    let source = BoundaryFailureCaptureSource()
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: BoundaryFailureClock(source: source),
        storeURL: try temporaryStore()
    )

    await #expect(throws: ProtocolError.self) { try await controller.start() }

    #expect(await controller.status().phase == .failed)
    #expect(await controller.status().failureCode == "recording_not_available")
    #expect(source.stopCount() == 1)
}

@Test func staleAutomaticStopCannotStopANewerRecording() async throws {
    let source = FakeCaptureSource()
    let clock = GenerationClock()
    let controller = RecordingController(
        source: source,
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: clock,
        storeURL: try temporaryStore()
    )
    try await controller.start(maximumDuration: .seconds(1))
    for _ in 0..<100 where !clock.hasDurationWaiter() { await Task.yield() }
    let first = try await controller.stop()
    try await controller.delete(id: first.id)
    try await controller.start(maximumDuration: .seconds(600))

    clock.fireOldDuration()
    for _ in 0..<20 { await Task.yield() }

    #expect(await source.stopCount == 1)
    #expect(await controller.status().phase == .recording)
}

@Test func deleteRemovesDownloadedRecordingAndReturnsToIdle() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    let metadata = try await controller.stop()
    let url = try await controller.file(id: metadata.id).url

    try await controller.delete(id: metadata.id)

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(await controller.status().phase == .idle)
}

@Test func failedLookupRetainsCompletedFile() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    let metadata = try await controller.stop()

    await #expect(throws: ProtocolError.self) { _ = try await controller.file(id: "missing") }

    #expect(FileManager.default.fileExists(atPath: try await controller.file(id: metadata.id).url.path))
}

@Test func startupCleanupRemovesPartialAndKeepsOnlyThreeReadyFiles() async throws {
    let store = try temporaryStore()
    try Data("partial".utf8).write(to: store.appendingPathComponent("partial.mp4.partial"))
    for index in 0..<5 {
        let id = "ready-\(index)"
        try Data("mp4".utf8).write(to: store.appendingPathComponent("\(id).mp4"))
        let metadata = RecordingMetadata(id: id, byteCount: 3, durationMilliseconds: 1, sha256: SHA256.hexDigest(Data("mp4".utf8)), createdAt: .init(milliseconds: Int64(index)))
        try JSONEncoder().encode(metadata).write(to: store.appendingPathComponent("\(id).json"))
    }

    let controller = RecordingController(source: FakeCaptureSource(), clock: ImmediateClock(milliseconds: 1_000), storeURL: store)
    try await controller.cleanup()
    let names = try FileManager.default.contentsOfDirectory(atPath: store.path)

    #expect(!names.contains("partial.mp4.partial"))
    #expect(names.filter { $0.hasSuffix(".mp4") }.count == 3)
}

@Test func retainedRecordingCanBeReadAndDeletedAfterControllerRecreation() async throws {
    let store = try temporaryStore()
    let first = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await first.start()
    let metadata = try await first.stop()

    let recreated = RecordingController(source: FakeCaptureSource(), clock: ImmediateClock(), storeURL: store)
    let file = try await recreated.file(id: metadata.id)
    #expect(file.metadata == metadata)
    try await recreated.delete(id: metadata.id)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

@Test func readingRetainedRecordingDoesNotDeleteActivePartialFile() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    let retained = try await controller.stop()
    try await controller.delete(id: retained.id)

    let retainedID = "retained"
    let bytes = Data("mp4".utf8)
    try bytes.write(to: store.appendingPathComponent("\(retainedID).mp4"))
    let retainedMetadata = RecordingMetadata(
        id: retainedID,
        byteCount: bytes.count,
        durationMilliseconds: 1,
        sha256: SHA256.hexDigest(bytes),
        createdAt: .init(milliseconds: 10_000)
    )
    try JSONEncoder().encode(retainedMetadata).write(to: store.appendingPathComponent("\(retainedID).json"))

    try await controller.start()
    _ = try await controller.file(id: retainedID)
    _ = try await controller.stop()
}

@Test func failureAfterMovingFinalArtifactDeletesTheFinalFile() async throws {
    let store = try temporaryStore()
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0, sabotageMetadataWrite: true) },
        clock: ImmediateClock(),
        storeURL: store
    )
    try await controller.start()
    await #expect(throws: ProtocolError.self) { _ = try await controller.stop() }

    let mp4s = try FileManager.default.contentsOfDirectory(atPath: store.path).filter { $0.hasSuffix(".mp4") }
    #expect(mp4s.isEmpty)
}

@Test func realRecordingWriterCreatesANonemptyMP4() async throws {
    let store = try temporaryStore()
    let url = store.appendingPathComponent("real-writer.mp4.partial")
    let writer = RecordingWriter(outputURL: url)
    let first = try #require(makeSampleBuffer(timestamp: 0))
    let second = try #require(makeSampleBuffer(timestamp: 1))

    try await writer.append(UncheckedSendableSampleBuffer(first))
    try await writer.append(UncheckedSendableSampleBuffer(second))
    try await writer.finish()

    let data = try Data(contentsOf: url)
    #expect(!data.isEmpty)
    #expect(data.count <= IOSDebugProtocol.maximumMP4Bytes)
}

@Test func cleanupDeletesReadyArtifactAtExactThirtyMinuteBoundary() async throws {
    let store = try temporaryStore()
    let id = "expired-boundary"
    let bytes = Data("mp4".utf8)
    try bytes.write(to: store.appendingPathComponent("\(id).mp4"))
    let metadata = RecordingMetadata(
        id: id,
        byteCount: bytes.count,
        durationMilliseconds: 1,
        sha256: SHA256.hexDigest(bytes),
        createdAt: .init(milliseconds: 1_000)
    )
    try JSONEncoder().encode(metadata).write(to: store.appendingPathComponent("\(id).json"))
    let controller = RecordingController(
        source: FakeCaptureSource(),
        clock: ImmediateClock(milliseconds: 1_801_000),
        storeURL: store
    )

    try await controller.cleanup()

    #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("\(id).mp4").path))
    #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("\(id).json").path))
}

@Test func cleanupOfCurrentExpiredReadyRecordingResetsStateAndAllowsRestart() async throws {
    let store = try temporaryStore()
    let clock = MutableClock(milliseconds: 10_000)
    let controller = RecordingController(
        source: FakeCaptureSource(),
        writerFactory: { FakeRecordingWriter(url: $0) },
        clock: clock,
        storeURL: store
    )
    try await controller.start()
    let expired = try await controller.stop()
    clock.advance(milliseconds: 1_800_000)

    try await controller.cleanup()

    #expect(await controller.status().phase == .idle)
    #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("\(expired.id).mp4").path))
    try await controller.start()
    #expect(await controller.status().phase == .recording)
}
#endif
