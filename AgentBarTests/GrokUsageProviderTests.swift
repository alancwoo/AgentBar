import XCTest
@testable import AgentBar

final class GrokUsageProviderTests: XCTestCase {
    private var tempDir: URL!
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("logs"), withIntermediateDirectories: true
        )
        suiteName = "GrokUsageProviderTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // 2026-09-03T10:00:00Z, inside the 2026-08-31 → 2026-09-07 weekly period.
    private let now = Date(timeIntervalSince1970: 1_788_472_800)

    private func billingLine(percent: Double, start: String, end: String, tier: String = "SuperGrok", ts: String = "2026-09-03T09:57:16.148Z") -> String {
        #"{"ts":"\#(ts)","src":"shell","pid":1,"ver":"1.0.5","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":\#(percent),"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\#(start)","end":"\#(end)"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true,"billingPeriodStart":"\#(start)","billingPeriodEnd":"\#(end)","historyLen":0},"onDemandEnabled":null,"subscriptionTier":"\#(tier)"}}"#
    }

    private let noiseLine = #"{"ts":"2026-09-03T09:58:00.000Z","src":"shell","pid":1,"ver":"1.0.5","lvl":"info","sid":"abc","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":105262,"completion_tokens":2268}}"#

    private func writeLog(_ lines: [String]) throws {
        let url = tempDir.appendingPathComponent("logs/unified.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeProvider() -> GrokUsageProvider {
        GrokUsageProvider(grokHome: tempDir, nowProvider: { [now] in now }, defaults: testDefaults)
    }

    func testIsConfiguredRequiresGrokHome() async {
        let missing = GrokUsageProvider(grokHome: URL(fileURLWithPath: "/nonexistent/grok"), defaults: testDefaults)
        let isMissingConfigured = await missing.isConfigured()
        XCTAssertFalse(isMissingConfigured)

        let isPresentConfigured = await makeProvider().isConfigured()
        XCTAssertTrue(isPresentConfigured)
    }

    func testReadsLatestBillingEntryAsWeeklyPercent() async throws {
        try writeLog([
            billingLine(percent: 69, start: "2026-08-31T09:32:37.697368+00:00", end: "2026-09-07T09:32:37.697368+00:00"),
            noiseLine,
            billingLine(percent: 74, start: "2026-08-31T09:32:37.697368+00:00", end: "2026-09-07T09:32:37.697368+00:00"),
            noiseLine,
        ])

        let usage = try await makeProvider().fetchUsage()

        XCTAssertEqual(usage.service, .grok)
        XCTAssertEqual(usage.fiveHourUsage.unit, .percent)
        XCTAssertEqual(usage.fiveHourUsage.used, 74)
        XCTAssertEqual(usage.fiveHourUsage.total, 100)
        XCTAssertEqual(usage.fiveHourUsage.percentage, 0.74, accuracy: 0.001)
        XCTAssertNil(usage.weeklyUsage)
        XCTAssertEqual(usage.planName, "SuperGrok")

        let expectedReset = DateUtils.parseISO8601("2026-09-07T09:32:37.697Z")
        XCTAssertNotNil(expectedReset)
        XCTAssertEqual(usage.fiveHourUsage.resetTime?.timeIntervalSince1970 ?? 0,
                       expectedReset!.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(testDefaults.string(forKey: GrokUsageProvider.detectedPlanDefaultsKey), "SuperGrok")
    }

    func testStalePeriodRollsForwardAndResetsToZero() async throws {
        // Last fetch was in the previous weekly period; Grok has not run since.
        try writeLog([
            billingLine(percent: 89, start: "2026-08-24T09:32:37.697368+00:00", end: "2026-08-31T09:32:37.697368+00:00", ts: "2026-08-28T17:46:56.430Z"),
        ])

        let usage = try await makeProvider().fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        let expectedReset = DateUtils.parseISO8601("2026-09-07T09:32:37.697Z")!
        XCTAssertEqual(usage.fiveHourUsage.resetTime?.timeIntervalSince1970 ?? 0,
                       expectedReset.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(usage.planName, "SuperGrok")
    }

    func testMissingBillingEntryYieldsZeroWithRememberedPlan() async throws {
        testDefaults.set("SuperGrok", forKey: GrokUsageProvider.detectedPlanDefaultsKey)
        try writeLog([noiseLine, noiseLine])

        let usage = try await makeProvider().fetchUsage()

        XCTAssertTrue(usage.isAvailable)
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.fiveHourUsage.unit, .percent)
        XCTAssertNil(usage.fiveHourUsage.resetTime)
        XCTAssertEqual(usage.planName, "SuperGrok")
    }

    func testMissingLogFileYieldsZero() async throws {
        let usage = try await makeProvider().fetchUsage()
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertNil(usage.planName)
    }

    func testReverseScanFindsEntryBuriedUnderMegabytesOfLaterLines() throws {
        let billing = billingLine(percent: 42, start: "2026-08-31T09:32:37.697368+00:00", end: "2026-09-07T09:32:37.697368+00:00")
        // ~1.2 MB of noise after the entry forces the scanner across several chunks
        // and through a line straddling a chunk boundary.
        var lines = [noiseLine, billing]
        lines.append(contentsOf: Array(repeating: noiseLine, count: 6_000))
        try writeLog(lines)

        let url = tempDir.appendingPathComponent("logs/unified.jsonl")
        let found = ReverseLineScanner.lastLine(containing: GrokBillingLogLine.marker, in: url, chunkSize: 64 * 1024)
        XCTAssertEqual(found, billing)

        let snapshot = GrokUsageProvider.latestSnapshot(in: url)
        XCTAssertEqual(snapshot?.creditUsagePercent, 42)
    }

    func testReverseScanReturnsLastOfMultipleMatchesAcrossChunks() throws {
        let early = billingLine(percent: 10, start: "2026-08-31T09:32:37.697368+00:00", end: "2026-09-07T09:32:37.697368+00:00")
        let late = billingLine(percent: 55, start: "2026-08-31T09:32:37.697368+00:00", end: "2026-09-07T09:32:37.697368+00:00")
        var lines = [early]
        lines.append(contentsOf: Array(repeating: noiseLine, count: 2_000))
        lines.append(late)
        lines.append(contentsOf: Array(repeating: noiseLine, count: 2_000))
        try writeLog(lines)

        let url = tempDir.appendingPathComponent("logs/unified.jsonl")
        XCTAssertEqual(ReverseLineScanner.lastLine(containing: GrokBillingLogLine.marker, in: url, chunkSize: 4 * 1024), late)
    }

    func testMalformedBillingLineIsIgnored() throws {
        XCTAssertNil(GrokUsageProvider.parseSnapshot(fromLine: #"{"msg":"billing: fetched credits config","ctx":{}}"#))
        XCTAssertNil(GrokUsageProvider.parseSnapshot(fromLine: "not json billing: fetched credits config"))
    }

    func testParsesMicrosecondTimestamps() {
        let date = GrokUsageProvider.parseTimestamp("2026-08-31T09:32:37.697368+00:00")
        XCTAssertNotNil(date)
        XCTAssertEqual(date!.timeIntervalSince1970, 1_788_168_757.697, accuracy: 0.001)
        XCTAssertNotNil(GrokUsageProvider.parseTimestamp("2026-09-03T09:57:16.148Z"))
        XCTAssertNotNil(GrokUsageProvider.parseTimestamp("2026-09-03T09:57:16Z"))
    }
}
