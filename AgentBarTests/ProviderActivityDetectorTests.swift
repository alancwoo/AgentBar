import XCTest
@testable import AgentBar

final class ProviderActivityDetectorTests: XCTestCase {
    private var home: URL!

    // 2026-09-03T10:00:00Z
    private let now = Date(timeIntervalSince1970: 1_788_472_800)

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func touch(_ relativePath: String, daysAgo: Double) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        // Parent directories get "now" as mtime on creation; pin them to the file's date
        // so a fresh test directory does not read as recent activity.
        var dir = url.deletingLastPathComponent()
        while dir.path.hasPrefix(home.path), dir.path != home.path {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            dir = dir.deletingLastPathComponent()
        }
    }

    private func makeDetector(hasSecret: Bool = false) -> ProviderActivityDetector {
        ProviderActivityDetector(
            homeDirectory: home,
            activityWindowDays: 30,
            nowProvider: { [now] in now },
            secretExists: { _ in hasSecret }
        )
    }

    func testAbsentFootprintIsNotDetected() {
        let activity = makeDetector().detect(.grok)
        XCTAssertFalse(activity.isActive)
        XCTAssertNil(activity.lastActivity)
        XCTAssertNil(activity.evidence)
    }

    func testRecentLogFileCountsAsActive() throws {
        try touch(".grok/logs/unified.jsonl", daysAgo: 2)

        let activity = makeDetector().detect(.grok)

        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(activity.evidence, "~/.grok/logs/unified.jsonl")
        XCTAssertEqual(activity.lastActivity!.timeIntervalSince(now), -2 * 86_400, accuracy: 1)
    }

    func testOldFootprintIsFoundButInactive() throws {
        try touch(".gemini/tmp/project-a/logs.json", daysAgo: 400)

        let activity = makeDetector().detect(.gemini)

        XCTAssertFalse(activity.isActive)
        XCTAssertNotNil(activity.lastActivity, "An old footprint is still reported so Settings can explain why it is hidden.")
    }

    func testNestedSessionFilesAreSeenThroughDepth() throws {
        // Codex: sessions/YYYY/MM/DD/rollout.jsonl — depth 3 reaches the day directory.
        try touch(".codex/sessions/2026/09/01/rollout-1.jsonl", daysAgo: 2)
        XCTAssertTrue(makeDetector().detect(.codex).isActive)

        // Claude: projects/<encoded-cwd>/<session>.jsonl
        try touch(".claude/projects/-Users-me/abc.jsonl", daysAgo: 1)
        XCTAssertTrue(makeDetector().detect(.claude).isActive)
    }

    func testNewestOfSeveralProbesWins() throws {
        try touch(".codex/history.jsonl", daysAgo: 90)
        try touch(".codex/sessions/2026/08/30/rollout.jsonl", daysAgo: 4)

        let activity = makeDetector().detect(.codex)

        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(activity.evidence, "~/.codex/sessions")
    }

    func testStaleGhLoginWithoutCopilotFilesIsNotDetected() throws {
        // Nothing Copilot-specific on disk: a gh token alone must not show Copilot.
        XCTAssertFalse(makeDetector().detect(.copilot).isActive)

        try touch(".copilot/session-state/abc.json", daysAgo: 3)
        XCTAssertTrue(makeDetector().detect(.copilot).isActive)
    }

    func testZaiDependsOnStoredKey() {
        XCTAssertFalse(makeDetector(hasSecret: false).detect(.zai).isActive)

        let withKey = makeDetector(hasSecret: true).detect(.zai)
        XCTAssertTrue(withKey.isActive)
        XCTAssertNil(withKey.lastActivity)
    }

    func testActiveServicesCollectsOnlyRecentTools() throws {
        try touch(".grok/logs/unified.jsonl", daysAgo: 1)
        try touch(".claude/history.jsonl", daysAgo: 0.5)
        try touch(".gemini/tmp/p/logs.json", daysAgo: 200)

        XCTAssertEqual(makeDetector().activeServices(), [.grok, .claude])
    }

    func testAutoDetectDefaultsToOn() {
        let suite = "ProviderActivityDetectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ProviderActivityDetector.isAutoDetectEnabled(in: defaults))
        defaults.set(false, forKey: ProviderActivityDetector.autoDetectDefaultsKey)
        XCTAssertFalse(ProviderActivityDetector.isAutoDetectEnabled(in: defaults))
    }

    func testMonitorCachesUntilInvalidated() throws {
        let monitor = ProviderActivityMonitor(detector: makeDetector(), ttl: 3600)
        XCTAssertEqual(monitor.activeServices(now: now), [])

        try touch(".grok/logs/unified.jsonl", daysAgo: 1)
        XCTAssertEqual(monitor.activeServices(now: now), [], "Cached result is reused inside the TTL.")

        monitor.invalidate()
        XCTAssertEqual(monitor.activeServices(now: now), [.grok])
    }
}
