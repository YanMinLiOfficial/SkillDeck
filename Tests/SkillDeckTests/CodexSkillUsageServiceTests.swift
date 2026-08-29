import Foundation
import XCTest

@testable import SkillDeck

/// Tests for best-effort Codex skill usage reconstruction.
final class CodexSkillUsageServiceTests: XCTestCase {

    func testScanCountsTrustedToolCallsAcrossActiveAndArchivedHistory() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let activeDirectory = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        let archivedDirectory = fixture.root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)

        let activeLines = [
            // A message mentioning a trusted path is not invocation evidence because it is not a tool call.
            try makeEvent(
                timestamp: "2026-08-01T10:00:00.000Z",
                payloadType: "message",
                input: "Read /Users/test/.agents/skills/find-skills/SKILL.md"
            ),
            // Repeating one path inside the same tool call counts once, not once per string occurrence.
            try makeEvent(
                timestamp: "2026-08-02T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/find-skills/SKILL.md /Users/test/.agents/skills/find-skills/SKILL.md"
            ),
            // Nested system skills use the final parent directory as their identifier.
            try makeEvent(
                timestamp: "2026-08-03T10:00:00.000Z",
                input: "sed /Users/test/.codex/skills/.system/openai-docs/SKILL.md"
            ),
            // Repository files are intentionally ignored even when their layout includes `skills/`.
            try makeEvent(
                timestamp: "2026-08-04T10:00:00.000Z",
                input: "sed /tmp/repository/skills/find-skills/SKILL.md"
            ),
            "{ malformed json",
        ]
        try writeJSONL(activeLines, to: activeDirectory.appendingPathComponent("active.jsonl"))

        let archivedLines = [
            // Function-call payloads use `arguments` instead of `input` in Codex history.
            try makeEvent(
                timestamp: "2026-08-05T10:00:00Z",
                payloadType: "function_call",
                input: "head /Users/test/.agents/skills/find-skills/SKILL.md"
            ),
        ]
        try writeJSONL(archivedLines, to: archivedDirectory.appendingPathComponent("archived.jsonl"))

        let service = CodexSkillUsageService(
            historyDirectories: [activeDirectory, archivedDirectory]
        )
        let result = await service.scan()

        XCTAssertEqual(result.scannedLogCount, 2)
        XCTAssertEqual(result.records["find-skills"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["openai-docs"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["repository"])

        let expectedLastUsed = ISO8601DateFormatter().date(from: "2026-08-05T10:00:00Z")
        XCTAssertEqual(result.records["find-skills"]?.lastDetectedAt, expectedLastUsed)
    }

    func testScanRecognizesPluginCacheSkillPaths() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let historyDirectory = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let event = try makeEvent(
            timestamp: "2026-08-06T10:00:00.000Z",
            input: "sed /Users/test/.codex/plugins/cache/openai-bundled/computer-use/1.0.0/skills/computer-use/SKILL.md"
        )
        try writeJSONL([event], to: historyDirectory.appendingPathComponent("plugin.jsonl"))

        let result = await CodexSkillUsageService(historyDirectories: [historyDirectory]).scan()

        XCTAssertEqual(result.records["computer-use"]?.detectedInvocationCount, 1)
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let missingDirectory = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let result = await CodexSkillUsageService(historyDirectories: [missingDirectory]).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testScanReusesUnchangedFilesAndRescansOnlyChangedFiles() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let historyDirectory = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        let cacheURL = fixture.root.appendingPathComponent("usage-cache.json")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let unchangedURL = historyDirectory.appendingPathComponent("archived.jsonl")
        let changingURL = historyDirectory.appendingPathComponent("active.jsonl")
        try writeJSONL([
            try makeEvent(
                timestamp: "2026-08-01T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/unchanged/SKILL.md"
            ),
        ], to: unchangedURL)
        try writeJSONL([
            try makeEvent(
                timestamp: "2026-08-02T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/changing/SKILL.md"
            ),
        ], to: changingURL)

        let service = CodexSkillUsageService(
            historyDirectories: [historyDirectory],
            cacheURL: cacheURL
        )
        let first = await service.scan()
        XCTAssertEqual(first.records["unchanged"]?.detectedInvocationCount, 1)
        XCTAssertEqual(first.records["changing"]?.detectedInvocationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // Appending changes the active log fingerprint. The archived file remains unchanged and
        // must still contribute exactly once when its cached per-file result is merged.
        let appendedEvent = try makeEvent(
            timestamp: "2026-08-03T10:00:00.000Z",
            input: "sed /Users/test/.agents/skills/changing/SKILL.md"
        ) + "\n"
        let handle = try FileHandle(forWritingTo: changingURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: XCTUnwrap(appendedEvent.data(using: .utf8)))
        try handle.close()

        let second = await service.scan()
        XCTAssertEqual(second.records["unchanged"]?.detectedInvocationCount, 1)
        XCTAssertEqual(second.records["changing"]?.detectedInvocationCount, 2)
    }

    /// Build one top-level Codex JSONL event without hand-escaping nested command strings.
    private func makeEvent(
        timestamp: String,
        payloadType: String = "custom_tool_call",
        input: String
    ) throws -> String {
        var payload: [String: Any] = ["type": payloadType]
        if payloadType == "function_call" {
            payload["arguments"] = input
        } else {
            payload["input"] = input
        }

        let object: [String: Any] = [
            "timestamp": timestamp,
            "type": "response_item",
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeJSONL(_ lines: [String], to url: URL) throws {
        let contents = lines.joined(separator: "\n") + "\n"
        try XCTUnwrap(contents.data(using: .utf8)).write(to: url, options: .atomic)
    }

    /// Each test owns a uniquely named temporary directory and removes only that exact path.
    private struct TemporaryHistoryFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SkillDeckUsageTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
