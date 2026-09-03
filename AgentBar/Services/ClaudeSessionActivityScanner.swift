import Foundation

/// Rebuilds Claude Code's daily activity from `~/.claude/projects/**/*.jsonl`.
///
/// Every assistant line carries a timestamp and token usage. A message that is
/// split into several blocks repeats the same usage under one `requestId`, so
/// usage is counted once per request. Per-file results are cached against the
/// file's size and modification date, so after the first pass only new or
/// changed sessions are re-read.
final class ClaudeSessionActivityScanner: ActivityHistorySource, @unchecked Sendable {
    let service: ServiceType = .claude

    struct FileFingerprint: Codable, Sendable, Equatable {
        let size: Int
        let modified: TimeInterval
    }

    /// What one session file contributed, keyed by day. Session logs are
    /// append-only, so a grown file is resumed from `parsedBytes` rather than
    /// re-read; `lastRequestId` carries the duplicate check across the seam.
    struct FileContribution: Codable, Sendable, Equatable {
        var fingerprint: FileFingerprint
        var days: [DayContribution]
        var parsedBytes: Int = 0
        var lastRequestId: String? = nil
    }

    struct DayContribution: Codable, Sendable, Equatable {
        let dayStart: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var messages: Int
    }

    struct Cache: Codable, Sendable {
        var version: Int
        var files: [String: FileContribution]
    }

    static let cacheVersion = 2

    private let projectsDirectory: URL
    private let cacheURL: URL
    private let fileManager: FileManager

    init(
        projectsDirectory: URL? = nil,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.projectsDirectory = projectsDirectory
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(fileManager: fileManager)
        self.fileManager = fileManager
    }

    func scan(calendar: Calendar) async -> [ActivityDayRecord] {
        let files = sessionFiles()
        var cache = loadCache()
        var contributions: [String: FileContribution] = [:]

        for file in files {
            guard let fingerprint = fingerprint(for: file) else { continue }
            let key = file.path

            if let cached = cache.files[key] {
                if cached.fingerprint == fingerprint {
                    contributions[key] = cached
                    continue
                }
                if fingerprint.size >= cached.parsedBytes, cached.parsedBytes > 0 {
                    // Appended to: pick up where the last pass stopped.
                    let tail = Self.parse(
                        file: file,
                        calendar: calendar,
                        fromOffset: cached.parsedBytes,
                        lastRequestId: cached.lastRequestId
                    )
                    contributions[key] = FileContribution(
                        fingerprint: fingerprint,
                        days: Self.merge(cached.days, tail.days),
                        parsedBytes: tail.parsedBytes,
                        lastRequestId: tail.lastRequestId
                    )
                    continue
                }
            }

            let parsed = Self.parse(file: file, calendar: calendar)
            contributions[key] = FileContribution(
                fingerprint: fingerprint,
                days: parsed.days,
                parsedBytes: parsed.parsedBytes,
                lastRequestId: parsed.lastRequestId
            )
        }

        cache.files = contributions
        saveCache(cache)

        return Self.aggregate(contributions.values, service: service)
    }

    // MARK: - Parsing

    private struct AssistantLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
            }
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    /// Only assistant lines carry usage, so the cheap byte scan for this marker
    /// skips the JSON decode for everything else — most of a session file.
    private static let assistantMarker = Array("\"type\":\"assistant\"".utf8)

    struct ParseResult {
        var days: [DayContribution]
        var parsedBytes: Int
        var lastRequestId: String?
    }

    static func parse(
        file: URL,
        calendar: Calendar,
        fromOffset: Int = 0,
        lastRequestId: String? = nil
    ) -> ParseResult {
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            return ParseResult(days: [], parsedBytes: fromOffset, lastRequestId: lastRequestId)
        }
        defer { handle.closeFile() }
        if fromOffset > 0 {
            handle.seek(toFileOffset: UInt64(fromOffset))
        }

        let decoder = JSONDecoder()
        var perDay: [Date: DayContribution] = [:]
        var previousRequestId = lastRequestId
        var consumedBytes = fromOffset
        var carry: [UInt8] = []
        let newline = UInt8(ascii: "\n")

        func consume(_ line: UnsafeBufferPointer<UInt8>) {
            guard containsMarker(line) else { return }
            guard let entry = try? decoder.decode(AssistantLine.self, from: Data(buffer: line)),
                  entry.type == "assistant",
                  let usage = entry.message?.usage,
                  let stamp = entry.timestamp,
                  let date = DateUtils.parseISO8601(stamp) else {
                return
            }

            // A message split into blocks repeats its usage under one requestId,
            // always on consecutive lines.
            if let requestId = entry.requestId {
                if requestId == previousRequestId { return }
                previousRequestId = requestId
            }

            let dayStart = calendar.startOfDay(for: date)
            var day = perDay[dayStart] ?? DayContribution(
                dayStart: dayStart,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                messages: 0
            )
            day.inputTokens += usage.input_tokens ?? 0
            day.outputTokens += usage.output_tokens ?? 0
            day.cacheReadTokens += usage.cache_read_input_tokens ?? 0
            day.cacheCreationTokens += usage.cache_creation_input_tokens ?? 0
            day.messages += 1
            perDay[dayStart] = day
        }

        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }

            var bytes = carry
            bytes.append(contentsOf: chunk)
            carry.removeAll(keepingCapacity: true)

            // memchr/memmem keep the hot loop in C; the Swift-level work is
            // only the JSON decode of assistant lines.
            let lineEnd: Int = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var lineStart = 0
                while lineStart < buffer.count {
                    guard let found = memchr(base + lineStart, Int32(newline), buffer.count - lineStart) else {
                        break
                    }
                    let index = UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - base
                    if index > lineStart {
                        consume(UnsafeBufferPointer(start: base + lineStart, count: index - lineStart))
                    }
                    lineStart = index + 1
                }
                return lineStart
            }

            // Only whole lines count as parsed, so a partial trailing line is
            // re-read on the next pass rather than lost.
            consumedBytes += lineEnd
            if lineEnd < bytes.count {
                carry = Array(bytes[lineEnd...])
            }
        }

        return ParseResult(
            days: perDay.values.sorted { $0.dayStart < $1.dayStart },
            parsedBytes: consumedBytes,
            lastRequestId: previousRequestId
        )
    }

    private static func containsMarker(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = line.baseAddress, line.count >= assistantMarker.count else { return false }
        return assistantMarker.withUnsafeBufferPointer { marker in
            memmem(base, line.count, marker.baseAddress, marker.count) != nil
        }
    }

    static func merge(_ base: [DayContribution], _ extra: [DayContribution]) -> [DayContribution] {
        var byDay = Dictionary(uniqueKeysWithValues: base.map { ($0.dayStart, $0) })
        for day in extra {
            if var existing = byDay[day.dayStart] {
                existing.inputTokens += day.inputTokens
                existing.outputTokens += day.outputTokens
                existing.cacheReadTokens += day.cacheReadTokens
                existing.cacheCreationTokens += day.cacheCreationTokens
                existing.messages += day.messages
                byDay[day.dayStart] = existing
            } else {
                byDay[day.dayStart] = day
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    static func aggregate(
        _ contributions: some Collection<FileContribution>,
        service: ServiceType
    ) -> [ActivityDayRecord] {
        var byDay: [Date: ActivityDayRecord] = [:]
        for contribution in contributions {
            for day in contribution.days {
                var record = byDay[day.dayStart] ?? .empty(service: service, dayStart: day.dayStart)
                record.inputTokens += day.inputTokens
                record.outputTokens += day.outputTokens
                record.cacheReadTokens += day.cacheReadTokens
                record.cacheCreationTokens += day.cacheCreationTokens
                record.messages += day.messages
                // One session file touching a day is one session that day.
                record.sessions += 1
                byDay[day.dayStart] = record
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    // MARK: - Files

    private func sessionFiles() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func fingerprint(for file: URL) -> FileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileFingerprint(size: size, modified: modified.timeIntervalSince1970)
    }

    // MARK: - Cache

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Self.cacheVersion else {
            return Cache(version: Self.cacheVersion, files: [:])
        }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        let directory = cacheURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func defaultCacheURL(fileManager: FileManager) -> URL {
        UsageHistoryStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("claude-activity-cache.json")
    }
}
