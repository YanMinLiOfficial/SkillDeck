import Foundation
import XCTest

@testable import SkillDeck

/// Tests for best-effort Codex skill usage reconstruction.
final class CodexSkillUsageServiceTests: XCTestCase {
    private let testHomeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)

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
            // A trusted-looking directory nested inside a repository is still not a Codex skill store.
            try makeEvent(
                timestamp: "2026-08-04T11:00:00.000Z",
                input: "sed /Users/test/repository/.agents/skills/lookalike/SKILL.md"
            ),
            // Another user's skill store is outside the configured home directory.
            try makeEvent(
                timestamp: "2026-08-04T12:00:00.000Z",
                input: "sed /Users/other/.agents/skills/foreign/SKILL.md"
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
            historyDirectories: [activeDirectory, archivedDirectory],
            homeDirectory: testHomeDirectory
        )
        let result = await service.scan()

        XCTAssertEqual(result.scannedLogCount, 2)
        XCTAssertEqual(result.records["find-skills"]?.detectedInvocationCount, 2)
        XCTAssertEqual(result.records["openai-docs"]?.detectedInvocationCount, 1)
        XCTAssertNil(result.records["repository"])
        XCTAssertNil(result.records["lookalike"])
        XCTAssertNil(result.records["foreign"])
        XCTAssertEqual(result.failedLogCount, 0)

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

        let result = await CodexSkillUsageService(
            historyDirectories: [historyDirectory],
            homeDirectory: testHomeDirectory
        ).scan()

        XCTAssertEqual(result.records["computer-use"]?.detectedInvocationCount, 1)
    }

    func testScanReturnsNoCoverageWhenHistoryIsMissing() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let missingDirectory = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let result = await CodexSkillUsageService(
            historyDirectories: [missingDirectory],
            homeDirectory: testHomeDirectory
        ).scan()

        XCTAssertEqual(result.scannedLogCount, 0)
        XCTAssertEqual(result.failedLogCount, 0)
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
            homeDirectory: testHomeDirectory,
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

    func testScanIsolatesUnreadableChangedLogAndRetainsItsCachedEvidence() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let historyDirectory = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        let cacheURL = fixture.root.appendingPathComponent("usage-cache.json")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let readableURL = historyDirectory.appendingPathComponent("readable.jsonl")
        let unreadableURL = historyDirectory.appendingPathComponent("unreadable.jsonl")
        try writeJSONL([
            try makeEvent(
                timestamp: "2026-08-01T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/readable/SKILL.md"
            ),
        ], to: readableURL)
        try writeJSONL([
            try makeEvent(
                timestamp: "2026-08-01T11:00:00.000Z",
                input: "sed /Users/test/.agents/skills/unreadable/SKILL.md"
            ),
        ], to: unreadableURL)

        let service = CodexSkillUsageService(
            historyDirectories: [historyDirectory],
            homeDirectory: testHomeDirectory,
            cacheURL: cacheURL
        )
        let first = await service.scan()
        XCTAssertEqual(first.records["readable"]?.detectedInvocationCount, 1)
        XCTAssertEqual(first.records["unreadable"]?.detectedInvocationCount, 1)

        try appendJSONL(
            try makeEvent(
                timestamp: "2026-08-02T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/readable/SKILL.md"
            ),
            to: readableURL
        )
        try appendJSONL(
            try makeEvent(
                timestamp: "2026-08-02T11:00:00.000Z",
                input: "sed /Users/test/.agents/skills/unreadable/SKILL.md"
            ),
            to: unreadableURL
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
        }

        let partial = await service.scan()
        XCTAssertEqual(partial.records["readable"]?.detectedInvocationCount, 2)
        XCTAssertEqual(partial.records["unreadable"]?.detectedInvocationCount, 1)
        XCTAssertEqual(partial.scannedLogCount, 2)
        XCTAssertEqual(partial.failedLogCount, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
        let recovered = await service.scan()
        XCTAssertEqual(recovered.records["unreadable"]?.detectedInvocationCount, 2)
        XCTAssertEqual(recovered.failedLogCount, 0)
    }

    func testScanWithoutCacheURLDoesNotCreateProcessTemporaryCache() async throws {
        let fixture = try TemporaryHistoryFixture()
        defer { fixture.remove() }

        let historyDirectory = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try writeJSONL([
            try makeEvent(
                timestamp: "2026-08-01T10:00:00.000Z",
                input: "sed /Users/test/.agents/skills/no-cache/SKILL.md"
            ),
        ], to: historyDirectory.appendingPathComponent("history.jsonl"))

        let before = try generatedTemporaryCacheURLs()
        defer {
            let after = (try? generatedTemporaryCacheURLs()) ?? []
            for url in after.subtracting(before) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        _ = await CodexSkillUsageService(
            historyDirectories: [historyDirectory],
            homeDirectory: testHomeDirectory
        ).scan()

        XCTAssertEqual(try generatedTemporaryCacheURLs(), before)
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

    private func appendJSONL(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: XCTUnwrap("\(line)\n".data(using: .utf8)))
        try handle.close()
    }

    private func generatedTemporaryCacheURLs() throws -> Set<URL> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(urls.filter { $0.lastPathComponent.hasPrefix("SkillDeckUsageCache-") })
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
