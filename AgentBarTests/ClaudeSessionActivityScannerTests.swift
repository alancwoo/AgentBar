import XCTest
@testable import AgentBar

final class ClaudeSessionActivityScannerTests: XCTestCase {
    private var tempDir: URL!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeActivity-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("projects/proj-a"),
            withIntermediateDirectories: true
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func line(
        type: String = "assistant",
        timestamp: String,
        requestId: String,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheCreate: Int = 0
    ) -> String {
        """
        {"type":"\(type)","timestamp":"\(timestamp)","requestId":"\(requestId)","sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreate)}}}
        """
    }

    private func writeSession(_ name: String, lines: [String]) -> URL {
        let url = tempDir.appendingPathComponent("projects/proj-a/\(name).jsonl")
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeScanner() -> ClaudeSessionActivityScanner {
        ClaudeSessionActivityScanner(
            projectsDirectory: tempDir.appendingPathComponent("projects"),
            cacheURL: tempDir.appendingPathComponent("cache.json")
        )
    }

    func testTokensAreBucketedByDayAndUserLinesIgnored() async {
        _ = writeSession("one", lines: [
            line(timestamp: "2026-08-01T10:00:00Z", requestId: "r1", input: 100, output: 50),
            line(type: "user", timestamp: "2026-08-01T10:01:00Z", requestId: "ignored", input: 999),
            line(timestamp: "2026-08-02T09:00:00Z", requestId: "r2", input: 10, output: 5, cacheRead: 1000)
        ])

        let records = await makeScanner().scan(calendar: calendar)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].inputTokens, 100)
        XCTAssertEqual(records[0].outputTokens, 50)
        XCTAssertEqual(records[0].messages, 1)
        XCTAssertEqual(records[1].totalTokens, 1015, "Cache reads count toward what the model processed.")
        XCTAssertEqual(records[0].service, .claude)
    }

    func testRepeatedRequestIdIsCountedOnce() async {
        // A message split into text + tool_use blocks repeats its usage.
        _ = writeSession("one", lines: [
            line(timestamp: "2026-08-01T10:00:00Z", requestId: "r1", input: 100, output: 50),
            line(timestamp: "2026-08-01T10:00:01Z", requestId: "r1", input: 100, output: 50),
            line(timestamp: "2026-08-01T10:05:00Z", requestId: "r2", input: 20, output: 10)
        ])

        let records = await makeScanner().scan(calendar: calendar)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 120)
        XCTAssertEqual(records[0].messages, 2)
    }

    func testSessionsPerDayCountsFilesThatTouchedTheDay() async {
        _ = writeSession("one", lines: [line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 1)])
        _ = writeSession("two", lines: [
            line(timestamp: "2026-08-01T22:00:00Z", requestId: "b", input: 1),
            line(timestamp: "2026-08-02T01:00:00Z", requestId: "c", input: 1)
        ])

        let records = await makeScanner().scan(calendar: calendar)

        XCTAssertEqual(records.map(\.sessions), [2, 1])
    }

    func testUnchangedFilesAreServedFromCacheAndChangedOnesReparsed() async throws {
        let url = writeSession("one", lines: [line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 10)])
        let scanner = makeScanner()

        let first = await scanner.scan(calendar: calendar)
        XCTAssertEqual(first.first?.inputTokens, 10)

        // Replace contents; the size changes, so the fingerprint changes.
        try (line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 10) + "\n"
             + line(timestamp: "2026-08-01T11:00:00Z", requestId: "b", input: 1000) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let second = await scanner.scan(calendar: calendar)
        XCTAssertEqual(second.first?.inputTokens, 1010, "A changed file must be re-read.")

        let cacheData = try Data(contentsOf: tempDir.appendingPathComponent("cache.json"))
        let cache = try JSONDecoder().decode(ClaudeSessionActivityScanner.Cache.self, from: cacheData)
        // Keyed by the enumerated path, which macOS resolves (/var -> /private/var).
        XCTAssertEqual(cache.files.count, 1)
        XCTAssertEqual(cache.files.values.first?.days.first?.inputTokens, 1010)
    }

    func testAppendedLinesAreParsedFromTheSavedOffset() async throws {
        let url = writeSession("one", lines: [line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 10)])
        let scanner = makeScanner()
        _ = await scanner.scan(calendar: calendar)

        // Append (not rewrite) so the size grows past parsedBytes.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((line(timestamp: "2026-08-02T10:00:00Z", requestId: "b", input: 5) + "\n").utf8))
        try handle.close()

        let records = await scanner.scan(calendar: calendar)
        XCTAssertEqual(records.map(\.inputTokens), [10, 5])

        let cacheData = try Data(contentsOf: tempDir.appendingPathComponent("cache.json"))
        let cache = try JSONDecoder().decode(ClaudeSessionActivityScanner.Cache.self, from: cacheData)
        let contribution = try XCTUnwrap(cache.files.values.first)
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(contribution.parsedBytes, fileSize, "Every whole line has been consumed.")
        XCTAssertEqual(contribution.lastRequestId, "b")
    }

    func testDuplicateRequestAcrossTheResumeSeamIsStillCountedOnce() async throws {
        let url = writeSession("one", lines: [line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 10)])
        let scanner = makeScanner()
        _ = await scanner.scan(calendar: calendar)

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((line(timestamp: "2026-08-01T10:00:01Z", requestId: "a", input: 10) + "\n").utf8))
        try handle.close()

        let records = await scanner.scan(calendar: calendar)
        XCTAssertEqual(records.first?.inputTokens, 10, "The block repeat after the seam must not double count.")
    }

    func testMalformedLinesAreSkipped() async {
        _ = writeSession("one", lines: [
            "not json at all",
            "{\"type\":\"assistant\"",
            line(timestamp: "2026-08-01T10:00:00Z", requestId: "a", input: 7)
        ])

        let records = await makeScanner().scan(calendar: calendar)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 7)
    }

    @MainActor
    func testActivityPanelShadesRelativeToBusiestDay() throws {
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let day2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
        var light = ActivityDayRecord.empty(service: .claude, dayStart: day1)
        light.inputTokens = 250
        light.sessions = 1
        var heavy = ActivityDayRecord.empty(service: .claude, dayStart: day2)
        heavy.inputTokens = 1000
        heavy.sessions = 3

        let panel = try XCTUnwrap(UsageHistoryViewModel.makeActivityPanel(
            service: .claude,
            records: [light, heavy],
            gridStart: day1,
            totalDays: 3,
            now: day2.addingTimeInterval(3600),
            calendar: calendar
        ))

        XCTAssertEqual(panel.heatmapCells.count, 3)
        XCTAssertEqual(panel.heatmapCells[0].ratio, 0.25, accuracy: 0.001)
        XCTAssertEqual(panel.heatmapCells[1].ratio, 1.0, accuracy: 0.001)
        XCTAssertEqual(panel.heatmapCells[1].level, 4)
        XCTAssertEqual(panel.heatmapCells[2].usedValue, 0, "Future days stay empty.")
        XCTAssertEqual(panel.trendUnit, .tokens)

        let summary = try XCTUnwrap(panel.activitySummary)
        XCTAssertEqual(summary.totalTokens, 1250)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.sessions, 4)
        XCTAssertEqual(summary.busiestDay, day2)
        XCTAssertEqual(summary.averageTokensPerActiveDay, 625)
    }

    @MainActor
    func testNoActivityYieldsNoPanel() {
        XCTAssertNil(UsageHistoryViewModel.makeActivityPanel(
            service: .claude,
            records: [],
            gridStart: Date(),
            totalDays: 7,
            now: Date(),
            calendar: calendar
        ))
    }
}
