import Foundation
import SQLite3

/// What the detector learned about one service on this Mac.
struct ProviderActivity: Sendable, Equatable {
    let service: ServiceType
    /// Newest modification date among the service's local footprint, or nil
    /// when the footprint is absent (or timeless, like a stored API key).
    let lastActivity: Date?
    /// Path (home-relative) that produced `lastActivity`, for the settings UI.
    let evidence: String?
    /// True when the service was used inside the detector's activity window.
    let isActive: Bool
}

/// Looks for signs that each AI tool has actually been used recently, so the
/// menu bar only shows tools the user works with instead of everything that
/// happens to be installed or logged in.
///
/// A stale `gh` login or a Gemini directory from a one-off trial should not
/// earn a permanent slot in the bar; a session log touched this week should.
struct ProviderActivityDetector: Sendable {
    static let autoDetectDefaultsKey = "providerAutoDetectEnabled"
    static let defaultActivityWindowDays = 30

    static func isAutoDetectEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: autoDetectDefaultsKey, defaultValue: true)
    }

    /// Services that participate in usage tracking (OpenCode is notification-only).
    static let trackedServices: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .grok, .zai]

    struct Probe: Sendable {
        /// Home-relative path of a file or directory.
        let path: String
        /// How many directory levels below `path` to inspect for newer files.
        let depth: Int
    }

    let homeDirectory: URL
    let activityWindow: TimeInterval
    let nowProvider: @Sendable () -> Date
    let secretExists: @Sendable (String) -> Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        activityWindowDays: Int = ProviderActivityDetector.defaultActivityWindowDays,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        secretExists: @escaping @Sendable (String) -> Bool = { account in
            KeychainManager.load(account: account) != nil
        }
    ) {
        self.homeDirectory = homeDirectory
        self.activityWindow = TimeInterval(activityWindowDays) * 24 * 3600
        self.nowProvider = nowProvider
        self.secretExists = secretExists
    }

    func detectAll() -> [ServiceType: ProviderActivity] {
        var result: [ServiceType: ProviderActivity] = [:]
        for service in ServiceType.allCases {
            result[service] = detect(service)
        }
        return result
    }

    func activeServices() -> Set<ServiceType> {
        Set(ServiceType.allCases.filter { detect($0).isActive })
    }

    func detect(_ service: ServiceType) -> ProviderActivity {
        let now = nowProvider()

        // API-key services leave no activity trail; a saved key is the signal.
        if service == .zai {
            let hasKey = secretExists(service.keychainAccount)
            return ProviderActivity(
                service: service,
                lastActivity: nil,
                evidence: hasKey ? "API key in Keychain" : nil,
                isActive: hasKey
            )
        }

        // Cursor writes its state database on every launch, so file dates only
        // prove the app was opened. Real use is a chat with at least one message.
        if service == .cursor {
            let dbURL = homeDirectory.appendingPathComponent(Self.cursorStateDBPath)
            switch Self.cursorLastChatActivity(dbPath: dbURL.path) {
            case .noDatabase:
                return ProviderActivity(service: service, lastActivity: nil, evidence: nil, isActive: false)
            case .noChats:
                return ProviderActivity(
                    service: service,
                    lastActivity: Self.newestModification(at: dbURL, depth: 0),
                    evidence: "~/" + Self.cursorStateDBPath + " (no chats)",
                    isActive: false
                )
            case .lastChat(let date):
                return ProviderActivity(
                    service: service,
                    lastActivity: date,
                    evidence: "Cursor chat history",
                    isActive: now.timeIntervalSince(date) <= activityWindow
                )
            case .unavailable:
                break // schema changed or DB locked: fall through to file dates
            }
        }

        var newest: (date: Date, path: String)?
        for probe in Self.probes(for: service) {
            let url = homeDirectory.appendingPathComponent(probe.path)
            guard let date = Self.newestModification(at: url, depth: probe.depth) else { continue }
            if newest == nil || date > newest!.date {
                newest = (date, probe.path)
            }
        }

        guard let newest else {
            return ProviderActivity(service: service, lastActivity: nil, evidence: nil, isActive: false)
        }
        let isActive = now.timeIntervalSince(newest.date) <= activityWindow
        return ProviderActivity(
            service: service,
            lastActivity: newest.date,
            evidence: "~/" + newest.path,
            isActive: isActive
        )
    }

    // MARK: - Footprints

    static func probes(for service: ServiceType) -> [Probe] {
        switch service {
        case .claude:
            return [
                Probe(path: ".claude/history.jsonl", depth: 0),
                Probe(path: ".claude/projects", depth: 2),
            ]
        case .codex:
            return [
                Probe(path: ".codex/history.jsonl", depth: 0),
                Probe(path: ".codex/sessions", depth: 3),
            ]
        case .gemini:
            return [
                Probe(path: ".gemini/tmp", depth: 2),
            ]
        case .copilot:
            return [
                Probe(path: ".copilot", depth: 1),
                Probe(path: ".config/github-copilot", depth: 1),
                Probe(path: "Library/Application Support/Code/User/globalStorage/github.copilot-chat", depth: 1),
            ]
        case .cursor:
            // Fallback only; see cursorLastChatActivity.
            return [
                Probe(path: cursorStateDBPath, depth: 0),
            ]
        case .opencode:
            return [
                Probe(path: ".local/share/opencode", depth: 2),
                Probe(path: ".config/opencode", depth: 1),
            ]
        case .grok:
            return [
                Probe(path: ".grok/logs/unified.jsonl", depth: 0),
                Probe(path: ".grok/sessions", depth: 2),
            ]
        case .zai:
            return []
        }
    }

    /// Newest modification date of `url` and, for directories, of anything up
    /// to `depth` levels below it. Directory mtimes only change when entries are
    /// added or removed, so a couple of levels are needed to see appended logs.
    static func newestModification(at url: URL, depth: Int) -> Date? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        var newest = modificationDate(of: url)

        guard isDir.boolValue, depth > 0,
              let children = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: []
              ) else {
            return newest
        }

        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if let date = values?.contentModificationDate, newest == nil || date > newest! {
                newest = date
            }
            if values?.isDirectory == true, depth > 1,
               let deeper = newestModification(at: child, depth: depth - 1),
               newest == nil || deeper > newest! {
                newest = deeper
            }
        }
        return newest
    }

    // MARK: - Cursor chat history

    static let cursorStateDBPath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    enum CursorChatActivity: Equatable {
        case noDatabase
        case unavailable
        case noChats
        case lastChat(Date)
    }

    /// Newest `lastUpdatedAt` among Cursor composers that hold at least one
    /// message. Cursor keeps them in `cursorDiskKV` under `composerData:<id>`
    /// as JSON; `fullConversationHeadersOnly` is empty for the placeholder
    /// chat Cursor opens on launch.
    static func cursorLastChatActivity(dbPath: String) -> CursorChatActivity {
        guard FileManager.default.fileExists(atPath: dbPath) else { return .noDatabase }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return .unavailable
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT MAX(json_extract(value, '$.lastUpdatedAt'))
            FROM cursorDiskKV
            WHERE key LIKE 'composerData:%'
              AND json_array_length(json_extract(value, '$.fullConversationHeadersOnly')) > 0
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .unavailable
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return .unavailable }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return .noChats }

        let millis = sqlite3_column_double(stmt, 0)
        guard millis > 0 else { return .noChats }
        return .lastChat(Date(timeIntervalSince1970: millis / 1000))
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Caches detection results so the per-tick usage refresh does not re-walk
/// session directories every minute.
final class ProviderActivityMonitor: @unchecked Sendable {
    private let detector: ProviderActivityDetector
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cached: (services: Set<ServiceType>, at: Date)?

    init(detector: ProviderActivityDetector = ProviderActivityDetector(), ttl: TimeInterval = 5 * 60) {
        self.detector = detector
        self.ttl = ttl
    }

    func activeServices(now: Date = Date()) -> Set<ServiceType> {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < ttl {
            return cached.services
        }
        let services = detector.activeServices()
        cached = (services, now)
        return services
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
