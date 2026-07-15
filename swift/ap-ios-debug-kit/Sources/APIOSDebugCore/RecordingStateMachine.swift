public struct RecordingInstant: Codable, Sendable, Comparable {
    public let milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    public static func seconds(_ value: Int64) -> Self {
        .init(milliseconds: value * 1_000)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }
}

public enum RecordingPhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case ready
    case failed
}

public struct RecordingMetadata: Codable, Sendable, Equatable {
    public let id: String
    public let byteCount: Int
    public let durationMilliseconds: Int64
    public let sha256: String
    public let createdAt: RecordingInstant

    public init(
        id: String,
        byteCount: Int,
        durationMilliseconds: Int64,
        sha256: String,
        createdAt: RecordingInstant
    ) {
        self.id = id
        self.byteCount = byteCount
        self.durationMilliseconds = durationMilliseconds
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

public struct RecordingStatus: Codable, Sendable, Equatable {
    public let phase: RecordingPhase
    public let elapsedMilliseconds: Int64
    public let recording: RecordingMetadata?
    public let failureCode: String?

    public init(
        phase: RecordingPhase,
        elapsedMilliseconds: Int64,
        recording: RecordingMetadata?,
        failureCode: String?
    ) {
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.recording = recording
        self.failureCode = failureCode
    }
}

public enum RecordingEvent: Sendable, Equatable {
    case startRequested(at: RecordingInstant, maximumDuration: RecordingInstant)
    case captureStarted(at: RecordingInstant)
    case stopRequested(at: RecordingInstant)
    case writerFinished(RecordingMetadata)
    case failed(code: String, at: RecordingInstant)
    case permissionTimedOut(at: RecordingInstant)
    case stopTimedOut(at: RecordingInstant)
    case maximumDurationReached(at: RecordingInstant)
    case downloadedAndDeleted(id: String)
    case reset
}

public struct RecordingStateMachine: Sendable {
    public private(set) var status: RecordingStatus

    private var startRequestedAt: RecordingInstant?
    private var captureStartedAt: RecordingInstant?
    private var stopRequestedAt: RecordingInstant?
    private var maximumDuration: RecordingInstant?
    private var lastEventAt: RecordingInstant?

    public init() {
        status = Self.idleStatus
    }

    public mutating func apply(_ event: RecordingEvent) throws {
        switch event {
        case .startRequested(let at, let duration):
            guard status.phase == .idle, duration.milliseconds > 0 else { throw invalidStateError() }
            startRequestedAt = at
            maximumDuration = duration
            lastEventAt = at
            status = RecordingStatus(phase: .starting, elapsedMilliseconds: 0, recording: nil, failureCode: nil)

        case .captureStarted(let at):
            guard status.phase == .starting, isCurrent(at) else { throw invalidStateError() }
            captureStartedAt = at
            lastEventAt = at
            status = RecordingStatus(phase: .recording, elapsedMilliseconds: 0, recording: nil, failureCode: nil)

        case .stopRequested(let at):
            guard status.phase == .recording, isCurrent(at) else { throw invalidStateError() }
            beginStopping(at: at)

        case .writerFinished(let metadata):
            guard status.phase == .stopping, isCurrent(metadata.createdAt) else { throw invalidStateError() }
            lastEventAt = metadata.createdAt
            status = RecordingStatus(
                phase: .ready,
                elapsedMilliseconds: metadata.durationMilliseconds,
                recording: metadata,
                failureCode: nil
            )

        case .failed(let code, let at):
            guard [.starting, .recording, .stopping].contains(status.phase), isCurrent(at) else {
                throw invalidStateError()
            }
            fail(code: code, at: at)

        case .permissionTimedOut(let at):
            guard
                status.phase == .starting,
                isCurrent(at),
                let startRequestedAt,
                at.milliseconds - startRequestedAt.milliseconds >= 60_000
            else { throw invalidStateError() }
            fail(code: AppErrorCode.recordingPermissionTimeout.rawValue, at: at)

        case .stopTimedOut(let at):
            guard
                status.phase == .stopping,
                isCurrent(at),
                let stopRequestedAt,
                at.milliseconds - stopRequestedAt.milliseconds >= 90_000
            else { throw invalidStateError() }
            fail(code: AppErrorCode.requestTimeout.rawValue, at: at)

        case .maximumDurationReached(let at):
            guard
                status.phase == .recording,
                isCurrent(at),
                let captureStartedAt,
                let maximumDuration,
                at.milliseconds - captureStartedAt.milliseconds >= maximumDuration.milliseconds
            else { throw invalidStateError() }
            beginStopping(at: at)

        case .downloadedAndDeleted(let id):
            guard status.phase == .ready, status.recording?.id == id else { throw invalidStateError() }
            clearToIdle()

        case .reset:
            guard status.phase == .failed else { throw invalidStateError() }
            clearToIdle()
        }
    }

    private static let idleStatus = RecordingStatus(
        phase: .idle,
        elapsedMilliseconds: 0,
        recording: nil,
        failureCode: nil
    )

    private func invalidStateError() -> ProtocolError {
        ProtocolError(
            code: AppErrorCode.recordingInvalidState.rawValue,
            message: "Recording operation is invalid while state is \(status.phase.rawValue).",
            hint: "Query recording status and retry only after the current transition finishes."
        )
    }

    private func isCurrent(_ instant: RecordingInstant) -> Bool {
        guard let lastEventAt else { return true }
        return instant >= lastEventAt
    }

    private func elapsed(at instant: RecordingInstant) -> Int64 {
        guard let captureStartedAt else { return 0 }
        return max(0, instant.milliseconds - captureStartedAt.milliseconds)
    }

    private mutating func beginStopping(at: RecordingInstant) {
        stopRequestedAt = at
        lastEventAt = at
        status = RecordingStatus(
            phase: .stopping,
            elapsedMilliseconds: elapsed(at: at),
            recording: nil,
            failureCode: nil
        )
    }

    private mutating func fail(code: String, at: RecordingInstant) {
        lastEventAt = at
        status = RecordingStatus(
            phase: .failed,
            elapsedMilliseconds: elapsed(at: at),
            recording: nil,
            failureCode: code
        )
    }

    private mutating func clearToIdle() {
        status = Self.idleStatus
        startRequestedAt = nil
        captureStartedAt = nil
        stopRequestedAt = nil
        maximumDuration = nil
        lastEventAt = nil
    }
}
