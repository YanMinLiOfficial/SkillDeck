import Foundation

/// A single skill's usage evidence recovered from local Agent history.
///
/// The count intentionally represents detected invocation evidence, not a guarantee that every
/// historical invocation was captured. Agent history can be disabled, deleted, or written in a
/// format that an older SkillDeck release does not understand.
struct SkillUsageRecord: Codable, Equatable {
    /// Number of distinct Codex tool-call events that referenced this skill's `SKILL.md` file.
    let detectedInvocationCount: Int

    /// Timestamp of the newest matching tool-call event, when the log provided a valid timestamp.
    let lastDetectedAt: Date?
}

/// Observable lifecycle state for a local usage-history scan.
///
/// Associated values let the `.available` case carry scan coverage without introducing a second
/// state variable that could become inconsistent with the enum.
enum SkillUsageScanState: Equatable {
    /// No scan has started during this app launch.
    case notScanned

    /// SkillDeck is reading local history files in the background.
    case scanning

    /// At least one Codex history file was readable, so a missing record means "not detected".
    case available(scannedLogCount: Int)

    /// No readable Codex history files were found, so usage must be reported as unknown.
    case unavailable
}

/// Complete result returned by an Agent-specific usage-history adapter.
struct SkillUsageScanResult: Equatable {
    /// Records are keyed by the skill directory name, which is also `Skill.id` in SkillDeck.
    let records: [String: SkillUsageRecord]

    /// Number of history files successfully read during this scan.
    let scannedLogCount: Int
}
