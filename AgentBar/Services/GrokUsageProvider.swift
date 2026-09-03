import Foundation

/// One `billing: fetched credits config` line from Grok CLI's unified log.
///
/// Grok CLI (`~/.grok`) fetches the SuperGrok credits allowance from xAI while a
/// session is running and logs the response verbatim. Example (trimmed):
///
/// ```json
/// {"ts":"2026-09-03T08:58:50.902Z","msg":"billing: fetched credits config",
///  "ctx":{"config":{"creditUsagePercent":70.0,
///          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
///                           "start":"2026-08-31T09:32:37.697368+00:00",
///                           "end":"2026-09-07T09:32:37.697368+00:00"}},
///         "subscriptionTier":"SuperGrok"}}
/// ```
struct GrokBillingLogLine: Decodable, Sendable {
    struct Context: Decodable, Sendable {
        let config: Config?
        let subscriptionTier: String?
    }

    struct Config: Decodable, Sendable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    struct Period: Decodable, Sendable {
        let type: String?
        let start: String?
        let end: String?
    }

    let ts: String?
    let msg: String?
    let ctx: Context?

    static let marker = "billing: fetched credits config"
}

/// Resolved view of the latest billing snapshot.
struct GrokBillingSnapshot: Sendable, Equatable {
    let loggedAt: Date?
    let creditUsagePercent: Double
    let periodStart: Date?
    let periodEnd: Date?
    let subscriptionTier: String?
}

final class GrokUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .grok

    static let detectedPlanDefaultsKey = "grokDetectedPlan"
    private static let defaultPeriodLength: TimeInterval = 7 * 24 * 3600

    private let grokHome: URL
    private let logFile: URL
    private let nowProvider: @Sendable () -> Date
    private let defaults: UserDefaults

    init(
        grokHome: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = grokHome ?? home.appendingPathComponent(".grok")
        self.grokHome = root
        self.logFile = root.appendingPathComponent("logs/unified.jsonl")
        self.nowProvider = nowProvider
        self.defaults = defaults
    }

    func isConfigured() async -> Bool {
        FileManager.default.fileExists(atPath: grokHome.path)
    }

    func fetchUsage() async throws -> UsageData {
        let now = nowProvider()

        guard let snapshot = Self.latestSnapshot(in: logFile) else {
            // Grok is installed but has never logged a billing fetch (or the
            // log was cleared). Keep the bar visible at zero rather than failing.
            return UsageData(
                service: .grok,
                fiveHourUsage: UsageMetric(used: 0, total: 100, unit: .percent, resetTime: nil),
                weeklyUsage: nil,
                lastUpdated: now,
                isAvailable: true,
                planName: defaults.string(forKey: Self.detectedPlanDefaultsKey)
            )
        }

        let (used, reset) = Self.resolveWindow(snapshot: snapshot, now: now)

        if let tier = snapshot.subscriptionTier, !tier.isEmpty {
            defaults.set(tier, forKey: Self.detectedPlanDefaultsKey)
        }

        return UsageData(
            service: .grok,
            fiveHourUsage: UsageMetric(used: used, total: 100, unit: .percent, resetTime: reset),
            weeklyUsage: nil,
            lastUpdated: now,
            isAvailable: true,
            planName: snapshot.subscriptionTier ?? defaults.string(forKey: Self.detectedPlanDefaultsKey)
        )
    }

    // MARK: - Window resolution

    /// The logged percentage belongs to the period that was current when the
    /// CLI fetched it. Once that period ends the counter has reset server-side
    /// even if Grok has not run since, so roll the window forward and show 0.
    static func resolveWindow(snapshot: GrokBillingSnapshot, now: Date) -> (used: Double, resetTime: Date?) {
        let used = min(max(snapshot.creditUsagePercent, 0), 100)

        guard var end = snapshot.periodEnd else {
            return (used, nil)
        }

        if end > now {
            return (used, end)
        }

        var length = Self.defaultPeriodLength
        if let start = snapshot.periodStart, end.timeIntervalSince(start) > 0 {
            length = end.timeIntervalSince(start)
        }
        while end <= now {
            end = end.addingTimeInterval(length)
        }
        return (0, end)
    }

    // MARK: - Log parsing

    static func latestSnapshot(in logFile: URL) -> GrokBillingSnapshot? {
        guard let line = ReverseLineScanner.lastLine(containing: GrokBillingLogLine.marker, in: logFile) else {
            return nil
        }
        return parseSnapshot(fromLine: line)
    }

    static func parseSnapshot(fromLine line: String) -> GrokBillingSnapshot? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONDecoder().decode(GrokBillingLogLine.self, from: data),
              record.msg == GrokBillingLogLine.marker,
              let ctx = record.ctx,
              let config = ctx.config,
              let percent = config.creditUsagePercent else {
            return nil
        }

        let start = config.currentPeriod?.start ?? config.billingPeriodStart
        let end = config.currentPeriod?.end ?? config.billingPeriodEnd

        return GrokBillingSnapshot(
            loggedAt: record.ts.flatMap(parseTimestamp),
            creditUsagePercent: percent,
            periodStart: start.flatMap(parseTimestamp),
            periodEnd: end.flatMap(parseTimestamp),
            subscriptionTier: ctx.subscriptionTier
        )
    }

    /// Grok writes microsecond precision (`.697368+00:00`), which
    /// `ISO8601DateFormatter` rejects; trim to milliseconds first.
    static func parseTimestamp(_ raw: String) -> Date? {
        if let date = DateUtils.parseISO8601(raw) { return date }

        guard let dot = raw.firstIndex(of: "."),
              let tzStart = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let fraction = raw[raw.index(after: dot)..<tzStart]
        let trimmed = String(raw[..<dot]) + "." + String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(raw[tzStart...])
        return DateUtils.parseISO8601(trimmed)
    }
}

/// Reads a file from the end in fixed-size chunks and returns the last line
/// containing `marker`, without loading the whole file. Grok's unified log
/// grows by a few megabytes a week and is polled every refresh tick.
enum ReverseLineScanner {
    static func lastLine(
        containing marker: String,
        in url: URL,
        chunkSize: Int = 256 * 1024,
        maxBytes: Int = 64 * 1024 * 1024
    ) -> String? {
        guard let markerData = marker.data(using: .utf8),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        let newline = UInt8(ascii: "\n")
        var offset = Int(fileSize)
        var carry = Data()           // incomplete first line of the previously read chunk
        var scanned = 0

        while offset > 0, scanned < maxBytes {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            scanned += readSize

            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let chunk = try? handle.read(upToCount: readSize) else {
                return nil
            }

            var buffer = chunk
            buffer.append(carry)

            if let firstNewline = buffer.firstIndex(of: newline) {
                let complete = buffer[buffer.index(after: firstNewline)...]
                if let line = lastMatchingLine(in: complete, marker: markerData, newline: newline) {
                    return line
                }
                carry = Data(buffer[..<firstNewline])
            } else {
                carry = buffer
            }
        }

        if offset == 0, !carry.isEmpty, carry.range(of: markerData) != nil {
            return decode(carry)
        }
        return nil
    }

    private static func lastMatchingLine(in region: Data, marker: Data, newline: UInt8) -> String? {
        var end = region.endIndex
        while end > region.startIndex {
            let lineStart: Data.Index
            if let nl = region[region.startIndex..<end].lastIndex(of: newline) {
                lineStart = region.index(after: nl)
            } else {
                lineStart = region.startIndex
            }
            let line = region[lineStart..<end]
            if !line.isEmpty, line.range(of: marker) != nil {
                return decode(line)
            }
            end = lineStart == region.startIndex ? region.startIndex : region.index(before: lineStart)
        }
        return nil
    }

    private static func decode(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
