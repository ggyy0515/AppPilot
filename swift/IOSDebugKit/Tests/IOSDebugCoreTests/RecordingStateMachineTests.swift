import Testing
@testable import IOSDebugCore

@Suite struct RecordingStateMachineTests {
    private let metadata = RecordingMetadata(
        id: "rec-1",
        byteCount: 42,
        durationMilliseconds: 1_000,
        sha256: String(repeating: "a", count: 64),
        createdAt: .seconds(3)
    )

    @Test func happyPathProducesReadyMetadataAndCanBeDeleted() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        try machine.apply(.captureStarted(at: .seconds(1)))
        try machine.apply(.stopRequested(at: .seconds(2)))
        try machine.apply(.writerFinished(metadata))
        #expect(machine.status == RecordingStatus(
            phase: .ready,
            elapsedMilliseconds: 1_000,
            recording: metadata,
            failureCode: nil
        ))
        try machine.apply(.downloadedAndDeleted(id: "rec-1"))
        #expect(machine.status.phase == .idle)
    }

    @Test(arguments: [RecordingPhase.starting, .recording, .stopping])
    func activePhasesCanFailAndFailedCanReset(phase: RecordingPhase) throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        if phase != .starting { try machine.apply(.captureStarted(at: .seconds(1))) }
        if phase == .stopping { try machine.apply(.stopRequested(at: .seconds(2))) }
        try machine.apply(.failed(code: "capture_failed", at: .seconds(3)))
        #expect(machine.status.phase == .failed)
        #expect(machine.status.failureCode == "capture_failed")
        try machine.apply(.reset)
        #expect(machine.status == RecordingStatus(phase: .idle, elapsedMilliseconds: 0, recording: nil, failureCode: nil))
    }

    @Test func rejectsConcurrentStartAndStopOperationsWithStableError() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        #expect(throws: invalidState(for: .starting)) {
            try machine.apply(.startRequested(at: .seconds(1), maximumDuration: .seconds(120)))
        }
        #expect(throws: invalidState(for: .starting)) {
            try machine.apply(.stopRequested(at: .seconds(1)))
        }
        try machine.apply(.captureStarted(at: .seconds(2)))
        try machine.apply(.stopRequested(at: .seconds(3)))
        #expect(throws: invalidState(for: .stopping)) {
            try machine.apply(.stopRequested(at: .seconds(4)))
        }
    }

    @Test func permissionTimeoutRequiresStartingAndSixtySeconds() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(10), maximumDuration: .seconds(120)))
        #expect(throws: invalidState(for: .starting)) {
            try machine.apply(.permissionTimedOut(at: RecordingInstant(milliseconds: 69_999)))
        }
        try machine.apply(.permissionTimedOut(at: .seconds(70)))
        #expect(machine.status.phase == .failed)
        #expect(machine.status.failureCode == "recording_permission_timeout")
    }

    @Test func stopTimeoutRequiresStoppingAndNinetySeconds() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        try machine.apply(.captureStarted(at: .seconds(1)))
        try machine.apply(.stopRequested(at: .seconds(10)))
        #expect(throws: invalidState(for: .stopping)) {
            try machine.apply(.stopTimedOut(at: RecordingInstant(milliseconds: 99_999)))
        }
        try machine.apply(.stopTimedOut(at: .seconds(100)))
        #expect(machine.status.phase == .failed)
        #expect(machine.status.failureCode == "request_timeout")
    }

    @Test func maximumDurationAutomaticallyBeginsStoppingAtBoundary() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        try machine.apply(.captureStarted(at: .seconds(1)))
        #expect(throws: invalidState(for: .recording)) {
            try machine.apply(.maximumDurationReached(at: RecordingInstant(milliseconds: 120_999)))
        }
        try machine.apply(.maximumDurationReached(at: .seconds(121)))
        #expect(machine.status.phase == .stopping)
        #expect(machine.status.elapsedMilliseconds == 120_000)
    }

    @Test func staleCallbacksAreRejectedWithoutMutatingState() throws {
        var machine = RecordingStateMachine()
        try machine.apply(.startRequested(at: .seconds(10), maximumDuration: .seconds(120)))
        #expect(throws: invalidState(for: .starting)) {
            try machine.apply(.captureStarted(at: .seconds(9)))
        }
        #expect(machine.status.phase == .starting)
        try machine.apply(.captureStarted(at: .seconds(11)))
        #expect(throws: invalidState(for: .recording)) {
            try machine.apply(.failed(code: "late", at: .seconds(10)))
        }
        try machine.apply(.stopRequested(at: .seconds(12)))
        let stale = RecordingMetadata(id: "old", byteCount: 1, durationMilliseconds: 1, sha256: "0", createdAt: .seconds(11))
        #expect(throws: invalidState(for: .stopping)) { try machine.apply(.writerFinished(stale)) }
        #expect(machine.status.phase == .stopping)
    }

    @Test func readyDeletionRequiresMatchingIdentifierAndResetRequiresFailure() throws {
        var machine = RecordingStateMachine()
        #expect(throws: invalidState(for: .idle)) { try machine.apply(.reset) }
        try machine.apply(.startRequested(at: .seconds(0), maximumDuration: .seconds(120)))
        try machine.apply(.captureStarted(at: .seconds(1)))
        try machine.apply(.stopRequested(at: .seconds(2)))
        try machine.apply(.writerFinished(metadata))
        #expect(throws: invalidState(for: .ready)) {
            try machine.apply(.downloadedAndDeleted(id: "another-recording"))
        }
    }

    private func invalidState(for phase: RecordingPhase) -> ProtocolError {
        ProtocolError(
            code: "recording_invalid_state",
            message: "Recording operation is invalid while state is \(phase.rawValue).",
            hint: "Query recording status and retry only after the current transition finishes."
        )
    }
}
