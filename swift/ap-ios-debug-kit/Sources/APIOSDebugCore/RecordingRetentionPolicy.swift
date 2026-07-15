public struct RecordingRetentionEntry: Codable, Sendable, Equatable {
    public let identifier: String
    public let phase: RecordingPhase
    public let createdAt: RecordingInstant

    public init(identifier: String, phase: RecordingPhase, createdAt: RecordingInstant) {
        self.identifier = identifier
        self.phase = phase
        self.createdAt = createdAt
    }
}

public enum RecordingRetentionPolicy {
    public static func identifiersToDelete(
        now: RecordingInstant,
        entries: [RecordingRetentionEntry]
    ) -> [String] {
        let ordered = entries.sorted(by: precedes)
        let partialOrFailed = ordered.filter { $0.phase != .ready }
        let ready = ordered.filter { $0.phase == .ready }
        let expired = ready.filter { age(of: $0, at: now) >= 1_800_000 }
        let mandatoryIdentifiers = Set((partialOrFailed + expired).map(\.identifier))
        var retainedIdentifiers = Set<String>()
        let retainedCandidates = ready.filter {
            !mandatoryIdentifiers.contains($0.identifier)
                && retainedIdentifiers.insert($0.identifier).inserted
        }
        let overLimitCount = max(0, retainedCandidates.count - 3)
        let overLimit = retainedCandidates.prefix(overLimitCount)

        var deletedIdentifiers = Set<String>()
        return (partialOrFailed + expired + overLimit)
            .map(\.identifier)
            .filter { deletedIdentifiers.insert($0).inserted }
    }

    private static func precedes(_ lhs: RecordingRetentionEntry, _ rhs: RecordingRetentionEntry) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.identifier < rhs.identifier
    }

    private static func age(of entry: RecordingRetentionEntry, at now: RecordingInstant) -> Int64 {
        now.milliseconds - entry.createdAt.milliseconds
    }
}
