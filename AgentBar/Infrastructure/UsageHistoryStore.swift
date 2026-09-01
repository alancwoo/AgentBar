import Foundation

protocol UsageHistoryStoreProtocol: Sendable {
    func record(samples: [UsageData], recordedAt: Date) async
    func dayRecords(for service: ServiceType, since: Date, until: Date) async -> [UsageHistoryDayRecord]
    func secondarySamples(for service: ServiceType, since: Date, until: Date) async -> [UsageHistorySecondarySample]
    func availableServices(since: Date, until: Date) async -> [ServiceType]
}

actor UsageHistoryStore: UsageHistoryStoreProtocol {
    private static let schemaVersion = 2
    private static let dayRetentionDays = 365
    private static let secondarySampleRetentionDays = 120
    private static let secondarySampleBucketSeconds: TimeInterval = 5 * 60
    private static let logCompactionEventThreshold = 500
    private static let logCompactionByteThreshold: UInt64 = 512 * 1024

    private let fileURL: URL
    private let logFileURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var state: UsageHistoryStoreFile
    private var dayRecordIndex: [DayRecordKey: Int] = [:]
    private var secondarySampleIndex: [SecondarySampleKey: Int] = [:]
    private var logEventCountSinceCompaction = 0
    private var hasLoaded = false

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.nowProvider = nowProvider
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.logFileURL = Self.defaultLogFileURL(for: self.fileURL)
        self.state = UsageHistoryStoreFile(
            schemaVersion: Self.schemaVersion,
            dayRecords: [],
            secondarySamples: []
        )
    }

    func record(samples: [UsageData], recordedAt: Date) async {
        await ensureLoaded()

        var logEvents: [UsageHistoryLogEvent] = []
        for usage in samples where usage.isAvailable {
            let event = makeLogEvent(from: usage, recordedAt: recordedAt)
            apply(logEvent: event)
            logEvents.append(event)
        }

        _ = prune(retainedRelativeTo: recordedAt)
        guard !logEvents.isEmpty else { return }

        if appendLogEvents(logEvents) {
            logEventCountSinceCompaction += logEvents.count
        } else {
            _ = saveSnapshotToDisk()
        }

        maybeCompactLog()
    }

    func dayRecords(for service: ServiceType, since: Date, until: Date) async -> [UsageHistoryDayRecord] {
        await ensureLoaded()
        return state.dayRecords
            .filter { record in
                record.service == service &&
                record.dayStart >= since &&
                record.dayStart <= until
            }
            .sorted { $0.dayStart < $1.dayStart }
    }

    func secondarySamples(
        for service: ServiceType,
        since: Date,
        until: Date
    ) async -> [UsageHistorySecondarySample] {
        await ensureLoaded()
        return state.secondarySamples
            .filter { sample in
                sample.service == service &&
                sample.sampledAt >= since &&
                sample.sampledAt <= until
            }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    func availableServices(since: Date, until: Date) async -> [ServiceType] {
        await ensureLoaded()

        var serviceSet = Set<ServiceType>()

        for record in state.dayRecords where record.dayStart >= since && record.dayStart <= until {
            serviceSet.insert(record.service)
        }

        for sample in state.secondarySamples where sample.sampledAt >= since && sample.sampledAt <= until {
            serviceSet.insert(sample.service)
        }

        return serviceSet.sorted {
            Self.serviceOrderIndex(for: $0) < Self.serviceOrderIndex(for: $1)
        }
    }

    // MARK: - Day Records

    private func upsertDayRecord(
        service: ServiceType,
        dayStart: Date,
        primaryRatio: Double,
        secondaryRatio: Double?,
        primaryUsed: Double,
        secondaryUsed: Double?,
        primaryUnit: UsageUnit,
        secondaryUnit: UsageUnit?,
        recordedAt: Date
    ) {
        let key = DayRecordKey(service: service, dayStart: dayStart)
        if let index = dayRecordIndex[key] {
            var record = state.dayRecords[index]
            let previousCount = record.sampleCount
            let nextCount = previousCount + 1

            record.primaryPeakRatio = max(record.primaryPeakRatio, primaryRatio)
            record.primaryAverageRatio = (
                (record.primaryAverageRatio * Double(previousCount)) + primaryRatio
            ) / Double(nextCount)
            let existingPrimaryAverageUsed = record.primaryAverageUsed ?? 0
            record.primaryAverageUsed = (
                (existingPrimaryAverageUsed * Double(previousCount)) + primaryUsed
            ) / Double(nextCount)
            record.primaryPeakUsed = max(record.primaryPeakUsed ?? 0, primaryUsed)
            record.primaryUnitRawValue = primaryUnit.rawValue

            if let secondaryRatio {
                let previousSecondaryCount = max(0, record.secondarySampleCount)
                let nextSecondaryCount = previousSecondaryCount + 1
                let previousSecondaryAverage = record.secondaryAverageRatio ?? 0
                let nextSecondaryAverage = (
                    (previousSecondaryAverage * Double(previousSecondaryCount)) + secondaryRatio
                ) / Double(nextSecondaryCount)
                record.secondaryAverageRatio = nextSecondaryAverage
                record.secondaryPeakRatio = max(record.secondaryPeakRatio ?? 0, secondaryRatio)
                record.secondarySampleCount = nextSecondaryCount

                if let secondaryUsed {
                    let existingSecondaryAverageUsed = record.secondaryAverageUsed ?? 0
                    let nextSecondaryAverageUsed = (
                        (existingSecondaryAverageUsed * Double(previousSecondaryCount)) + secondaryUsed
                    ) / Double(nextSecondaryCount)
                    record.secondaryAverageUsed = nextSecondaryAverageUsed
                    record.secondaryPeakUsed = max(record.secondaryPeakUsed ?? 0, secondaryUsed)
                }

                if let secondaryUnit {
                    record.secondaryUnitRawValue = secondaryUnit.rawValue
                }
            }

            record.sampleCount = nextCount
            record.lastSampleAt = recordedAt
            state.dayRecords[index] = record
            return
        }

        state.dayRecords.append(
            UsageHistoryDayRecord(
                service: service,
                dayStart: dayStart,
                primaryPeakRatio: primaryRatio,
                primaryAverageRatio: primaryRatio,
                secondaryPeakRatio: secondaryRatio,
                secondaryAverageRatio: secondaryRatio,
                sampleCount: 1,
                secondarySampleCount: secondaryRatio == nil ? 0 : 1,
                lastSampleAt: recordedAt,
                primaryPeakUsed: primaryUsed,
                primaryAverageUsed: primaryUsed,
                primaryUnitRawValue: primaryUnit.rawValue,
                secondaryPeakUsed: secondaryUsed,
                secondaryAverageUsed: secondaryUsed,
                secondaryUnitRawValue: secondaryUnit?.rawValue
            )
        )
        dayRecordIndex[key] = state.dayRecords.count - 1
    }

    // MARK: - Secondary Samples

    private func upsertSecondarySample(_ sample: UsageHistorySecondarySample) {
        let key = SecondarySampleKey(
            service: sample.service,
            sampledAt: sample.sampledAt,
            resetAt: sample.resetAt
        )

        if let index = secondarySampleIndex[key] {
            let existing = state.secondarySamples[index]
            if sample.ratio > existing.ratio {
                state.secondarySamples[index] = sample
            }
            return
        }

        state.secondarySamples.append(sample)
        secondarySampleIndex[key] = state.secondarySamples.count - 1
    }

    // MARK: - Persistence

    private func ensureLoaded() async {
        guard !hasLoaded else { return }
        loadFromDisk()
        hasLoaded = true
    }

    private func loadFromDisk() {
        var shouldPersistSnapshot = false

        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                if let decoded = try? decoder.decode(UsageHistoryStoreFile.self, from: data) {
                    state = decoded
                } else if let legacy = try? decoder.decode(UsageHistoryStoreFileLegacyV1.self, from: data) {
                    state = UsageHistoryStoreFile(
                        schemaVersion: Self.schemaVersion,
                        dayRecords: legacy.records,
                        secondarySamples: []
                    )
                    shouldPersistSnapshot = true
                } else {
                    backupCorruptStoreFile()
                    resetToEmptyState()
                    shouldPersistSnapshot = true
                }
            } catch {
                backupCorruptStoreFile()
                resetToEmptyState()
                shouldPersistSnapshot = true
            }
        }

        rebuildIndices()
        let replayedEvents = replayLogEvents()
        if prune(retainedRelativeTo: nowProvider()) {
            shouldPersistSnapshot = true
        }
        maybeCompactLog(force: shouldPersistSnapshot || replayedEvents > 0)
    }

    private func replayLogEvents() -> Int {
        let events = loadLogEventsFromDisk()
        guard !events.isEmpty else { return 0 }

        for event in events {
            apply(logEvent: event)
        }

        logEventCountSinceCompaction = events.count
        return events.count
    }

    @discardableResult
    private func saveSnapshotToDisk() -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        var writableState = state
        writableState.schemaVersion = Self.schemaVersion

        guard let data = try? encoder.encode(writableState) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func backupCorruptStoreFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let timestamp = Int(nowProvider().timeIntervalSince1970)
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("usage-history.corrupt-\(timestamp).json")
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }

    private func backupCorruptLogFile() {
        guard fileManager.fileExists(atPath: logFileURL.path) else { return }
        let timestamp = Int(nowProvider().timeIntervalSince1970)
        let backupURL = logFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("usage-history.events.corrupt-\(timestamp).jsonl")
        try? fileManager.moveItem(at: logFileURL, to: backupURL)
    }

    private func resetToEmptyState() {
        state = UsageHistoryStoreFile(
            schemaVersion: Self.schemaVersion,
            dayRecords: [],
            secondarySamples: []
        )
        dayRecordIndex = [:]
        secondarySampleIndex = [:]
    }

    // MARK: - Retention

    @discardableResult
    private func prune(retainedRelativeTo now: Date) -> Bool {
        let dayCutoff = calendar.date(
            byAdding: .day,
            value: -(Self.dayRetentionDays - 1),
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)

        let secondaryCutoff = calendar.date(
            byAdding: .day,
            value: -(Self.secondarySampleRetentionDays - 1),
            to: now
        ) ?? now

        let originalDayCount = state.dayRecords.count
        let originalSecondaryCount = state.secondarySamples.count
        state.dayRecords.removeAll { $0.dayStart < dayCutoff }
        state.secondarySamples.removeAll { $0.sampledAt < secondaryCutoff }

        let didChange = state.dayRecords.count != originalDayCount ||
            state.secondarySamples.count != originalSecondaryCount
        if didChange {
            rebuildIndices()
        }
        return didChange
    }

    // MARK: - Append Log

    private func makeLogEvent(from usage: UsageData, recordedAt: Date) -> UsageHistoryLogEvent {
        UsageHistoryLogEvent(
            service: usage.service,
            recordedAt: recordedAt,
            primaryRatio: Self.clampRatio(usage.fiveHourUsage.percentage),
            secondaryRatio: usage.weeklyUsage.map { Self.clampRatio($0.percentage) },
            primaryUsed: usage.fiveHourUsage.used,
            secondaryUsed: usage.weeklyUsage?.used,
            primaryUnitRawValue: usage.fiveHourUsage.unit.rawValue,
            secondaryUnitRawValue: usage.weeklyUsage?.unit.rawValue,
            secondaryResetAt: usage.weeklyUsage?.resetTime.map(Self.truncateToMinute)
        )
    }

    private func apply(logEvent: UsageHistoryLogEvent) {
        let dayStart = calendar.startOfDay(for: logEvent.recordedAt)
        upsertDayRecord(
            service: logEvent.service,
            dayStart: dayStart,
            primaryRatio: logEvent.primaryRatio,
            secondaryRatio: logEvent.secondaryRatio,
            primaryUsed: logEvent.primaryUsed,
            secondaryUsed: logEvent.secondaryUsed,
            primaryUnit: UsageUnit(rawValue: logEvent.primaryUnitRawValue) ?? .percent,
            secondaryUnit: logEvent.secondaryUnitRawValue.flatMap(UsageUnit.init(rawValue:)),
            recordedAt: logEvent.recordedAt
        )

        if let secondaryRatio = logEvent.secondaryRatio,
           let resetAt = logEvent.secondaryResetAt {
            upsertSecondarySample(
                UsageHistorySecondarySample(
                    service: logEvent.service,
                    sampledAt: Self.truncateToBucket(
                        logEvent.recordedAt,
                        bucketSeconds: Self.secondarySampleBucketSeconds
                    ),
                    ratio: secondaryRatio,
                    resetAt: resetAt
                )
            )
        }
    }

    private func appendLogEvents(_ events: [UsageHistoryLogEvent]) -> Bool {
        let directory = logFileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return false
        }

        do {
            try handle.seekToEnd()
            for event in events {
                guard let data = try? encoder.encode(event) else { continue }
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.close()
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    private func loadLogEventsFromDisk() -> [UsageHistoryLogEvent] {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            logEventCountSinceCompaction = 0
            return []
        }

        guard let data = try? Data(contentsOf: logFileURL), !data.isEmpty else {
            logEventCountSinceCompaction = 0
            return []
        }

        let lines = data.split(separator: 0x0A)
        var events: [UsageHistoryLogEvent] = []
        events.reserveCapacity(lines.count)

        for line in lines where !line.isEmpty {
            guard let event = try? decoder.decode(UsageHistoryLogEvent.self, from: Data(line)) else {
                backupCorruptLogFile()
                logEventCountSinceCompaction = 0
                return []
            }
            events.append(event)
        }

        logEventCountSinceCompaction = events.count
        return events
    }

    private func maybeCompactLog(force: Bool = false) {
        guard force || shouldCompactLog() else { return }
        sortState()
        guard saveSnapshotToDisk() else { return }
        try? fileManager.removeItem(at: logFileURL)
        logEventCountSinceCompaction = 0
    }

    private func shouldCompactLog() -> Bool {
        if logEventCountSinceCompaction >= Self.logCompactionEventThreshold {
            return true
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.uint64Value >= Self.logCompactionByteThreshold
    }

    // MARK: - Indexes

    private func sortState() {
        state.dayRecords.sort {
            if $0.service != $1.service {
                return Self.serviceOrderIndex(for: $0.service) < Self.serviceOrderIndex(for: $1.service)
            }
            return $0.dayStart < $1.dayStart
        }

        state.secondarySamples.sort {
            if $0.service != $1.service {
                return Self.serviceOrderIndex(for: $0.service) < Self.serviceOrderIndex(for: $1.service)
            }
            if $0.resetAt != $1.resetAt {
                return $0.resetAt < $1.resetAt
            }
            return $0.sampledAt < $1.sampledAt
        }

        rebuildIndices()
    }

    private func rebuildIndices() {
        dayRecordIndex = [:]
        dayRecordIndex.reserveCapacity(state.dayRecords.count)
        for (index, record) in state.dayRecords.enumerated() {
            dayRecordIndex[DayRecordKey(service: record.service, dayStart: record.dayStart)] = index
        }

        secondarySampleIndex = [:]
        secondarySampleIndex.reserveCapacity(state.secondarySamples.count)
        for (index, sample) in state.secondarySamples.enumerated() {
            secondarySampleIndex[SecondarySampleKey(
                service: sample.service,
                sampledAt: sample.sampledAt,
                resetAt: sample.resetAt
            )] = index
        }
    }

    /// Unit tests exercise `UsageViewModel` with mock providers, which record
    /// samples. Those must never land in the user's real history file.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        if isRunningUnitTests {
            return fileManager.temporaryDirectory
                .appendingPathComponent("AgentBarTestHistory", isDirectory: true)
                .appendingPathComponent("usage-history.json")
        }

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("AgentBar", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    private static func defaultLogFileURL(for snapshotURL: URL) -> URL {
        let directory = snapshotURL.deletingLastPathComponent()
        let baseName = snapshotURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(baseName).events.jsonl")
    }

    private static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }

    private static func truncateToMinute(_ date: Date) -> Date {
        let seconds = floor(date.timeIntervalSince1970 / 60) * 60
        return Date(timeIntervalSince1970: seconds)
    }

    private static func truncateToBucket(_ date: Date, bucketSeconds: TimeInterval) -> Date {
        let seconds = floor(date.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
        return Date(timeIntervalSince1970: seconds)
    }

    private static func serviceOrderIndex(for service: ServiceType) -> Int {
        let order: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai]
        return order.firstIndex(of: service) ?? Int.max
    }
}

private struct DayRecordKey: Hashable, Sendable {
    let service: ServiceType
    let dayStart: Date
}

private struct SecondarySampleKey: Hashable, Sendable {
    let service: ServiceType
    let sampledAt: Date
    let resetAt: Date
}

private struct UsageHistoryLogEvent: Codable, Sendable {
    let service: ServiceType
    let recordedAt: Date
    let primaryRatio: Double
    let secondaryRatio: Double?
    let primaryUsed: Double
    let secondaryUsed: Double?
    let primaryUnitRawValue: String
    let secondaryUnitRawValue: String?
    let secondaryResetAt: Date?
}
