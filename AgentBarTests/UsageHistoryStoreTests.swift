import XCTest
@testable import AgentBar

final class UsageHistoryStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var historyFileURL: URL!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        historyFileURL = tempDirectory.appendingPathComponent("usage-history.json")

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar = gregorian
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testDefaultFileURLIsRedirectedAwayFromRealHistoryDuringTests() {
        let url = UsageHistoryStore.defaultFileURL()

        XCTAssertTrue(
            UsageHistoryStore.isRunningUnitTests,
            "Expected the XCTest environment marker to be visible to the store."
        )
        XCTAssertFalse(
            url.path.contains("Application Support/AgentBar"),
            "Tests must never record mock usage into the user's real history file."
        )
        XCTAssertTrue(url.path.contains("AgentBarTestHistory"))
    }

    func testDayRecordAggregatesPeakAndAverage() async {
        let store = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)
        let resetAt = makeDate(2026, 2, 20, 0, 0)

        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.2, secondaryRatio: 0.4, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 10, 0)
        )

        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.8, secondaryRatio: 0.6, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 11, 0)
        )

        let dayStart = makeDate(2026, 2, 19, 0, 0)
        let records = await store.dayRecords(for: .codex, since: dayStart, until: dayStart)

        XCTAssertEqual(records.count, 1)
        guard let record = records.first else { return }
        XCTAssertEqual(record.sampleCount, 2)
        XCTAssertEqual(record.primaryPeakRatio, 0.8, accuracy: 0.0001)
        XCTAssertEqual(record.primaryAverageRatio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(record.secondaryPeakRatio ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(record.secondaryAverageRatio ?? -1, 0.5, accuracy: 0.0001)
    }

    func testSecondaryAverageUsesSecondarySampleCountInsteadOfTotalSamples() async {
        let store = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)
        let resetAt = makeDate(2026, 2, 20, 0, 0)

        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.2, secondaryRatio: 0.4, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 10, 0)
        )

        // Second sample has no secondary window and must not dilute secondary averages.
        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.8, secondaryRatio: nil, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 11, 0)
        )

        let dayStart = makeDate(2026, 2, 19, 0, 0)
        let records = await store.dayRecords(for: .codex, since: dayStart, until: dayStart)

        XCTAssertEqual(records.count, 1)
        guard let record = records.first else { return }
        XCTAssertEqual(record.sampleCount, 2)
        XCTAssertEqual(record.secondarySampleCount, 1)
        XCTAssertEqual(record.secondaryAverageRatio ?? -1, 0.4, accuracy: 0.0001)
    }

    func testSecondarySampleUsesFiveMinuteBucketAndKeepsHighestRatio() async {
        let store = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)
        let resetAt = makeDate(2026, 2, 20, 0, 0)

        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.3, secondaryRatio: 0.4, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 10, 1)
        )
        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.3, secondaryRatio: 0.7, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 10, 4)
        )
        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.3, secondaryRatio: 0.5, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 10, 6)
        )

        let since = makeDate(2026, 2, 19, 10, 0)
        let until = makeDate(2026, 2, 19, 11, 0)
        let samples = await store.secondarySamples(for: .codex, since: since, until: until)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].sampledAt, makeDate(2026, 2, 19, 10, 0))
        XCTAssertEqual(samples[0].ratio, 0.7, accuracy: 0.0001)
        XCTAssertEqual(samples[1].sampledAt, makeDate(2026, 2, 19, 10, 5))
        XCTAssertEqual(samples[1].ratio, 0.5, accuracy: 0.0001)
    }

    func testRetentionPrunesOldDayRecordsAndSecondarySamples() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let store = UsageHistoryStore(
            fileURL: historyFileURL,
            calendar: calendar,
            nowProvider: { now }
        )

        let oldRecordedAt = calendar.date(byAdding: .day, value: -400, to: now) ?? now
        let oldResetAt = calendar.date(byAdding: .day, value: 7, to: oldRecordedAt) ?? oldRecordedAt
        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.4, secondaryRatio: 0.4, resetAt: oldResetAt)],
            recordedAt: oldRecordedAt
        )

        let recentResetAt = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        await store.record(
            samples: [makeUsage(service: .codex, primaryRatio: 0.6, secondaryRatio: 0.6, resetAt: recentResetAt)],
            recordedAt: now
        )

        let dayRecords = await store.dayRecords(
            for: .codex,
            since: calendar.date(byAdding: .day, value: -500, to: now) ?? now,
            until: now
        )
        XCTAssertEqual(dayRecords.count, 1)
        XCTAssertEqual(dayRecords.first?.dayStart, calendar.startOfDay(for: now))

        let secondarySamples = await store.secondarySamples(
            for: .codex,
            since: calendar.date(byAdding: .day, value: -500, to: now) ?? now,
            until: now
        )
        XCTAssertEqual(secondarySamples.count, 1)
        XCTAssertEqual(secondarySamples.first?.ratio ?? -1, 0.6, accuracy: 0.0001)
    }

    func testStoreRoundTripLoadsPersistedData() async {
        let resetAt = makeDate(2026, 2, 20, 0, 0)
        let store = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)

        await store.record(
            samples: [makeUsage(service: .claude, primaryRatio: 0.9, secondaryRatio: 1.0, resetAt: resetAt)],
            recordedAt: makeDate(2026, 2, 19, 8, 0)
        )

        let reloadedStore = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)
        let dayStart = makeDate(2026, 2, 19, 0, 0)
        let records = await reloadedStore.dayRecords(for: .claude, since: dayStart, until: dayStart)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.primaryPeakRatio ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertEqual(records.first?.secondaryPeakRatio ?? -1, 1.0, accuracy: 0.0001)
    }

    func testCorruptStoreIsBackedUpAndReset() async throws {
        let badData = Data("not-json".utf8)
        try badData.write(to: historyFileURL, options: .atomic)

        let store = UsageHistoryStore(fileURL: historyFileURL, calendar: calendar)
        let services = await store.availableServices(
            since: makeDate(2026, 1, 1, 0, 0),
            until: makeDate(2026, 12, 31, 0, 0)
        )
        XCTAssertTrue(services.isEmpty)

        let files = (try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(
            files.contains { $0.lastPathComponent.hasPrefix("usage-history.corrupt-") },
            "Expected a corrupt backup file to be created."
        )

        let recoveredData = try Data(contentsOf: historyFileURL)
        let recovered = try JSONDecoder().decode(UsageHistoryStoreFile.self, from: recoveredData)
        XCTAssertEqual(recovered.schemaVersion, 2)
        XCTAssertTrue(recovered.dayRecords.isEmpty)
        XCTAssertTrue(recovered.secondarySamples.isEmpty)
    }

    private func makeUsage(
        service: ServiceType,
        primaryRatio: Double,
        secondaryRatio: Double?,
        resetAt: Date
    ) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(
                used: primaryRatio * 100,
                total: 100,
                unit: .percent,
                resetTime: nil
            ),
            weeklyUsage: secondaryRatio.map {
                UsageMetric(
                    used: $0 * 100,
                    total: 100,
                    unit: .percent,
                    resetTime: resetAt
                )
            },
            lastUpdated: Date(),
            isAvailable: true
        )
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
