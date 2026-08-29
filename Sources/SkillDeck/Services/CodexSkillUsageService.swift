import Foundation

/// Recovers best-effort skill invocation evidence from Codex's local JSONL history.
///
/// Codex does not currently expose a stable public usage-statistics API. This adapter therefore
/// treats a tool call that references a trusted local `SKILL.md` path as invocation evidence. The
/// parser is deliberately isolated in one service so a future structured Codex event can replace
/// this heuristic without changing the View or ViewModel layers.
actor CodexSkillUsageService {
    /// Codex currently keeps active and archived history under separate directory trees.
    private let historyDirectories: [URL]
    private let cacheURL: URL
    private let fileManager: FileManager

    /// Increment when the persisted cache schema or matching semantics change.
    private static let cacheVersion = 1

    /// Production initializer based on the current macOS user's home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let agentsDirectory = homeDirectory.appendingPathComponent(".agents", isDirectory: true)
        self.historyDirectories = [
            codexDirectory.appendingPathComponent("sessions", isDirectory: true),
            codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        self.cacheURL = agentsDirectory.appendingPathComponent(".skilldeck-usage-cache.json")
        self.fileManager = fileManager
    }

    /// Test initializer that avoids depending on the developer machine's real Codex history.
    init(
        historyDirectories: [URL],
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.historyDirectories = historyDirectories
        self.cacheURL = cacheURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("SkillDeckUsageCache-\(UUID().uuidString).json")
        self.fileManager = fileManager
    }

    /// Scan all readable JSONL files and build one index for every detected skill.
    ///
    /// Building a complete index in one pass is important because a user may click through many
    /// skills. Re-reading every history file once per detail page would scale poorly.
    func scan() -> SkillUsageScanResult {
        var cache = loadCache()
        var refreshedFiles: [String: CachedLogResult] = [:]
        var changedLogs: [URL: LogFingerprint] = [:]
        var scannedLogCount = 0

        for logURL in historyLogURLs() {
            guard let fingerprint = fingerprint(for: logURL) else {
                continue
            }

            let cached = cache.files[logURL.path]
            if let cached, cached.fingerprint == fingerprint {
                // Unchanged files can be reused without touching their potentially large contents.
                refreshedFiles[logURL.path] = cached
                scannedLogCount += 1
            } else {
                changedLogs[logURL] = fingerprint
            }
        }

        // macOS's native grep performs the broad byte search much faster than a Swift byte loop.
        // Swift still parses every candidate as JSON and applies the trusted-path rules below.
        if let scannedChanges = scanChangedLogs(changedLogs) {
            refreshedFiles.merge(scannedChanges) { _, new in new }
            scannedLogCount += scannedChanges.count
        }

        // Dropping cache entries for deleted logs prevents stale usage evidence from surviving forever.
        cache.files = refreshedFiles
        saveCache(cache)

        var merged: [String: MutableUsageRecord] = [:]
        for file in refreshedFiles.values {
            for (skillID, fileRecord) in file.records {
                var aggregate = merged[skillID] ?? MutableUsageRecord()
                aggregate.detectedInvocationCount += fileRecord.detectedInvocationCount
                if let timestamp = fileRecord.lastDetectedAt,
                   aggregate.lastDetectedAt == nil || timestamp > aggregate.lastDetectedAt! {
                    aggregate.lastDetectedAt = timestamp
                }
                merged[skillID] = aggregate
            }
        }

        let records = merged.mapValues {
            SkillUsageRecord(
                detectedInvocationCount: $0.detectedInvocationCount,
                lastDetectedAt: $0.lastDetectedAt
            )
        }
        return SkillUsageScanResult(records: records, scannedLogCount: scannedLogCount)
    }

    /// Scan all changed logs with a two-stage fixed-string grep pipeline.
    ///
    /// Stage one keeps only `response_item` events. Stage two keeps only those mentioning
    /// `SKILL.md`. This reduced roughly 1.8 GB of real-world history to a small candidate stream in
    /// local benchmarks, while the subsequent Swift parser remains responsible for correctness.
    private func scanChangedLogs(_ logs: [URL: LogFingerprint]) -> [String: CachedLogResult]? {
        guard !logs.isEmpty else { return [:] }

        let sortedURLs = logs.keys.sorted { $0.path < $1.path }
        let responseItemGrep = Process()
        responseItemGrep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        responseItemGrep.arguments = ["-H", "-F", "\"type\":\"response_item\""] + sortedURLs.map(\.path)

        let skillMarkerGrep = Process()
        skillMarkerGrep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        skillMarkerGrep.arguments = ["-F", "SKILL.md"]

        let intermediatePipe = Pipe()
        let outputPipe = Pipe()
        responseItemGrep.standardOutput = intermediatePipe
        skillMarkerGrep.standardInput = intermediatePipe
        skillMarkerGrep.standardOutput = outputPipe
        responseItemGrep.standardError = FileHandle.nullDevice
        skillMarkerGrep.standardError = FileHandle.nullDevice

        do {
            // Start the consumer before the producer so neither side can block on a full pipe.
            try skillMarkerGrep.run()
            outputPipe.fileHandleForWriting.closeFile()

            do {
                try responseItemGrep.run()
            } catch {
                skillMarkerGrep.terminate()
                return nil
            }
            intermediatePipe.fileHandleForWriting.closeFile()
            intermediatePipe.fileHandleForReading.closeFile()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            responseItemGrep.waitUntilExit()
            skillMarkerGrep.waitUntilExit()

            // grep uses status 1 for "no matching lines", which is a successful empty result here.
            guard [0, 1].contains(responseItemGrep.terminationStatus),
                  [0, 1].contains(skillMarkerGrep.terminationStatus),
                  let text = String(data: output, encoding: .utf8) else {
                return nil
            }

            var perFileRecords = Dictionary(
                uniqueKeysWithValues: sortedURLs.map { ($0.path, [String: MutableUsageRecord]()) }
            )

            text.enumerateLines { prefixedLine, _ in
                // `grep -H` prefixes each candidate with `<absolute path>:`. Codex-generated
                // rollout filenames do not contain colons, so the first delimiter is unambiguous.
                guard let delimiter = prefixedLine.firstIndex(of: ":") else { return }
                let path = String(prefixedLine[..<delimiter])
                guard var records = perFileRecords[path] else { return }

                let jsonStart = prefixedLine.index(after: delimiter)
                let jsonLine = String(prefixedLine[jsonStart...])
                self.consume(line: jsonLine, records: &records)
                perFileRecords[path] = records
            }

            return perFileRecords.reduce(into: [:]) { result, entry in
                guard let url = sortedURLs.first(where: { $0.path == entry.key }),
                      let fingerprint = logs[url] else {
                    return
                }
                result[entry.key] = CachedLogResult(
                    fingerprint: fingerprint,
                    records: entry.value.mapValues {
                        SkillUsageRecord(
                            detectedInvocationCount: $0.detectedInvocationCount,
                            lastDetectedAt: $0.lastDetectedAt
                        )
                    }
                )
            }
        } catch {
            return nil
        }
    }

    /// Enumerate active and archived Codex histories recursively.
    private func historyLogURLs() -> [URL] {
        var result: [URL] = []

        for directory in historyDirectories where fileManager.fileExists(atPath: directory.path) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                result.append(fileURL)
            }
        }

        // Stable ordering makes tests deterministic and keeps future incremental caching possible.
        return result.sorted { $0.path < $1.path }
    }

    /// Size plus modification time is a cheap and sufficient cache fingerprint for append-only logs.
    private func fingerprint(for url: URL) -> LogFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        return LogFingerprint(fileSize: UInt64(fileSize), modificationDate: modificationDate)
    }

    /// Parse one JSONL event and merge any trusted skill references into the index.
    private func consume(line: String, records: inout [String: MutableUsageRecord]) {
        // Most history lines do not mention a skill. This cheap filter avoids JSON parsing for them.
        guard line.contains("SKILL.md"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "custom_tool_call" || payloadType == "function_call" else {
            return
        }

        // Current Codex app logs use `input` for custom tool calls and `arguments` for function calls.
        guard let toolInput = (payload["input"] as? String) ?? (payload["arguments"] as? String) else {
            return
        }

        let skillIDs = trustedSkillIDs(in: toolInput)
        guard !skillIDs.isEmpty else { return }

        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
        for skillID in skillIDs {
            var record = records[skillID] ?? MutableUsageRecord()
            record.detectedInvocationCount += 1
            if let timestamp, record.lastDetectedAt == nil || timestamp > record.lastDetectedAt! {
                record.lastDetectedAt = timestamp
            }
            records[skillID] = record
        }
    }

    /// Extract skill directory names only from locations that Codex can legitimately load.
    ///
    /// A repository may also contain `skills/foo/SKILL.md`. Counting that path would create a false
    /// positive while a developer merely edits a skill, so paths outside Codex's local skill stores
    /// are intentionally ignored.
    private func trustedSkillIDs(in toolInput: String) -> Set<String> {
        let trustedMarkers = [
            "/.agents/skills/",
            "/.codex/skills/",
            "/.codex/plugins/cache/",
        ]

        var result: Set<String> = []
        var searchStart = toolInput.startIndex

        while let suffixRange = toolInput.range(of: "/SKILL.md", range: searchStart..<toolInput.endIndex) {
            let prefix = toolInput[..<suffixRange.lowerBound]

            // The parent directory immediately before SKILL.md is the SkillDeck skill identifier.
            guard let parentSlash = prefix.lastIndex(of: "/") else {
                searchStart = suffixRange.upperBound
                continue
            }

            let skillIDStart = toolInput.index(after: parentSlash)
            let skillID = String(toolInput[skillIDStart..<suffixRange.lowerBound])

            // Limit the trust check to the current command token. This prevents an earlier trusted
            // path in the same shell command from making a later repository path look trusted.
            let tokenStart = prefix.lastIndex { character in
                character.isWhitespace || character == "\"" || character == "'" || character == ";"
            }.map { toolInput.index(after: $0) } ?? toolInput.startIndex
            let pathToken = String(toolInput[tokenStart..<suffixRange.upperBound])

            if !skillID.isEmpty, trustedMarkers.contains(where: pathToken.contains) {
                result.insert(skillID)
            }

            searchStart = suffixRange.upperBound
        }

        return result
    }

    /// Codex timestamps are ISO-8601 and commonly include fractional seconds.
    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }

    /// Read a versioned local cache. Invalid or old files safely fall back to a clean first scan.
    private func loadCache() -> UsageCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(UsageCache.self, from: data),
              decoded.version == Self.cacheVersion else {
            return UsageCache(version: Self.cacheVersion, files: [:])
        }
        return decoded
    }

    /// Persist atomically so an interrupted app launch cannot leave a half-written cache.
    private func saveCache(_ cache: UsageCache) {
        let parent = cacheURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // Usage remains available in memory even when cache persistence is not permitted.
        }
    }

    /// Mutable accumulator kept private so the public model remains immutable.
    private struct MutableUsageRecord {
        var detectedInvocationCount = 0
        var lastDetectedAt: Date?
    }

    private struct UsageCache: Codable {
        let version: Int
        var files: [String: CachedLogResult]
    }

    private struct CachedLogResult: Codable {
        let fingerprint: LogFingerprint
        let records: [String: SkillUsageRecord]
    }

    private struct LogFingerprint: Codable, Equatable {
        let fileSize: UInt64
        let modificationDate: Date
    }
}
