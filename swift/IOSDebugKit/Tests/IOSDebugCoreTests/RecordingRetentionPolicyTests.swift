import Testing
@testable import IOSDebugCore

@Suite struct RecordingRetentionPolicyTests {
    @Test func deletesPartialAndFailedEntriesFirstInStableOrder() {
        let entries = [
            entry("partial-b", .starting, 2),
            entry("ready", .ready, 3),
            entry("failed", .failed, 1),
            entry("partial-a", .stopping, 2),
        ]
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: .seconds(100), entries: entries) == [
            "failed", "partial-a", "partial-b",
        ])
    }

    @Test func expiresReadyEntriesAtExactlyThirtyMinutes() {
        let now = RecordingInstant.seconds(2_000)
        let entries = [
            entry("expired", .ready, 200),
            RecordingRetentionEntry(identifier: "fresh", phase: .ready, createdAt: RecordingInstant(milliseconds: 200_001)),
        ]
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: now, entries: entries) == ["expired"])
    }

    @Test func keepsNewestThreeReadyEntriesWithDeterministicTieBreaking() {
        let entries = [
            entry("newest", .ready, 50),
            entry("same-b", .ready, 40),
            entry("oldest", .ready, 10),
            entry("same-a", .ready, 40),
            entry("middle", .ready, 30),
        ]
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: .seconds(100), entries: entries) == [
            "oldest", "middle",
        ])
    }

    @Test func deletionIdentifiersAreUniqueEvenForDuplicateEntries() {
        let duplicate = entry("duplicate", .failed, 1)
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: .seconds(2), entries: [duplicate, duplicate]) == ["duplicate"])
    }

    @Test func failedDuplicateCannotBeHiddenByEarlierFreshReadyEntry() {
        let entries = [
            entry("shared", .ready, 10),
            entry("other", .failed, 15),
            entry("shared", .failed, 20),
        ]
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: .seconds(100), entries: entries) == [
            "other", "shared",
        ])
    }

    @Test func failedAndPartialPriorityPrecedesExpiredAndOverflowBeforeFinalDeduplication() {
        let entries = [
            entry("shared", .failed, 90),
            entry("shared", .ready, 0),
            entry("expired", .ready, 1),
            entry("overflow", .ready, 201),
            entry("keep-1", .ready, 202),
            entry("keep-2", .ready, 203),
            entry("keep-3", .ready, 204),
        ]
        #expect(RecordingRetentionPolicy.identifiersToDelete(now: .seconds(1_801), entries: entries) == [
            "shared", "expired", "overflow",
        ])
    }

    private func entry(_ identifier: String, _ phase: RecordingPhase, _ seconds: Int64) -> RecordingRetentionEntry {
        RecordingRetentionEntry(identifier: identifier, phase: phase, createdAt: .seconds(seconds))
    }
}
