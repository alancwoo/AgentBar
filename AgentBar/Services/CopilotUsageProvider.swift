import Foundation

// MARK: - API Response Models

struct CopilotUserResponse: Decodable, Sendable {
    let copilot_plan: String?
    let quota_snapshots: [CopilotQuotaSnapshot]?
}

struct CopilotQuotaSnapshot: Decodable, Sendable {
    let quota_id: String
    let entitlement: Int?
    let remaining: Int?
    let unlimited: Bool?
}

struct GHCLICommandConfiguration: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]

    /// A GUI-launched app inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
    /// so `env gh` cannot find a Homebrew-installed CLI. Probe the usual install
    /// locations first and only fall back to a PATH lookup.
    static var ghSearchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            "\(home)/.local/bin/gh"
        ]
    }

    static let pathLookup = GHCLICommandConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["gh", "auth", "token"]
    )

    static func resolved(
        candidatePaths: [String] = ghSearchPaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> GHCLICommandConfiguration {
        for path in candidatePaths where isExecutable(path) {
            return GHCLICommandConfiguration(
                executableURL: URL(fileURLWithPath: path),
                arguments: ["auth", "token"]
            )
        }
        return pathLookup
    }

    static var `default`: GHCLICommandConfiguration { resolved() }
}

// MARK: - Provider

final class CopilotUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .copilot

    private let session: URLSession
    private let primaryCredentialProvider: @Sendable () -> String?
    private let fallbackCredentialProvider: @Sendable () -> String?
    private let defaults: UserDefaults

    static let apiURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let usageCachePrefix = "copilotUsageCache.monthly"
    private static let planNameCacheKey = "copilotUsageCache.planName"
    private static let defaultGHTokenCacheTTL: TimeInterval = 60
    private static let ghTokenLookupTimeout: TimeInterval = 2
    private static let ghTokenCacheLock = NSLock()
    nonisolated(unsafe) static var ghCLICommandConfiguration = GHCLICommandConfiguration.default
    nonisolated(unsafe) static var ghCLICommandRunner: @Sendable (_ timeout: TimeInterval) -> String? = { timeout in
        runGHCLICommand(timeout: timeout)
    }
    nonisolated(unsafe) private static var cachedGHCLIToken: String?
    nonisolated(unsafe) private static var ghTokenLastLookupAt: Date?

    typealias GHCLIProcessRuntime = CLIProcessRuntime

    init(
        session: URLSession = .shared,
        credentialProvider: (@Sendable () -> String?)? = nil,
        fallbackCredentialProvider: (@Sendable () -> String?)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.defaults = defaults

        if credentialProvider == nil && fallbackCredentialProvider == nil {
            CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: defaults)
        }

        if let credentialProvider {
            self.primaryCredentialProvider = credentialProvider
            self.fallbackCredentialProvider = fallbackCredentialProvider ?? { nil }
        } else {
            self.primaryCredentialProvider = { Self.readGHCLIToken() }
            let defaultsBox = SendableDefaultsBox(defaults)
            self.fallbackCredentialProvider = fallbackCredentialProvider ?? { [defaultsBox] in
                guard CopilotCredentialSettings.isManualPATEnabled(in: defaultsBox.defaults) else {
                    return nil
                }
                return KeychainManager.load(account: ServiceType.copilot.keychainAccount)
            }
        }
    }

    func isConfigured() async -> Bool {
        primaryCredentialProvider() != nil || fallbackCredentialProvider() != nil
    }

    func fetchUsage() async throws -> UsageData {
        do {
            return try await fetchUsageFromAPI()
        } catch {
            return try cachedOrThrow(error)
        }
    }

    private func fetchUsageFromAPI() async throws -> UsageData {
        if let primaryToken = primaryCredentialProvider() {
            do {
                return try await fetchUsage(using: primaryToken)
            } catch APIError.unauthorized {
                if let fallbackToken = fallbackCredentialProvider(), fallbackToken != primaryToken {
                    return try await fetchUsage(using: fallbackToken)
                }
                throw APIError.unauthorized
            }
        }

        guard let fallbackToken = fallbackCredentialProvider() else {
            throw APIError.unauthorized
        }

        return try await fetchUsage(using: fallbackToken)
    }

    private func fetchUsage(using pat: String) async throws -> UsageData {
        var request = URLRequest(url: Self.apiURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(CopilotUserResponse.self, from: data)

        // Find the premium_requests quota snapshot
        let premiumSnapshot = apiResponse.quota_snapshots?.first { $0.quota_id == "premium_requests" }

        let used: Double
        let total: Double

        if let snapshot = premiumSnapshot {
            if snapshot.unlimited == true {
                // Unlimited plan — show 0/0
                used = 0
                total = 0
            } else {
                let entitlement = Double(snapshot.entitlement ?? 0)
                let remaining = Double(snapshot.remaining ?? 0)
                let rawUsed = entitlement - remaining
                used = max(0, min(entitlement, rawUsed))
                total = entitlement
            }
        } else {
            used = 0
            total = 0
        }

        // Reset = 1st of next month 00:00 UTC
        let resetTime = Self.firstOfNextMonthUTC()

        let metric = UsageMetric(
            used: used,
            total: total,
            unit: .requests,
            resetTime: resetTime
        )
        saveMetricCache(metric, forKey: Self.usageCachePrefix)

        let planName = apiResponse.copilot_plan.map { Self.capitalizedPlanName($0) } ?? "Free"
        savePlanNameCache(planName)

        return UsageData(
            service: .copilot,
            fiveHourUsage: metric,
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true,
            planName: planName
        )
    }

    // MARK: - Usage Caching

    private func cachedOrThrow(_ error: Error) throws -> UsageData {
        let now = Date()
        guard let cached = validCachedMetric(forKey: Self.usageCachePrefix, now: now) else {
            throw error
        }
        return UsageData(
            service: .copilot,
            fiveHourUsage: cached,
            weeklyUsage: nil,
            lastUpdated: now,
            isAvailable: true,
            planName: loadPlanNameCache()
        )
    }

    private func validCachedMetric(forKey key: String, now: Date) -> UsageMetric? {
        guard defaults.object(forKey: "\(key).used") != nil else { return nil }
        let used = defaults.double(forKey: "\(key).used")
        let total = defaults.object(forKey: "\(key).total") != nil
            ? defaults.double(forKey: "\(key).total") : 300
        let resetTimestamp = defaults.object(forKey: "\(key).resetTime") as? Double
        let resetTime = resetTimestamp.map { Date(timeIntervalSince1970: $0) }

        if let resetTime, resetTime <= now {
            clearMetricCache(forKey: key)
            return nil
        }
        if used <= 0, resetTime == nil {
            clearMetricCache(forKey: key)
            return nil
        }
        return UsageMetric(used: used, total: total, unit: .requests, resetTime: resetTime)
    }

    private func saveMetricCache(_ metric: UsageMetric, forKey key: String) {
        defaults.set(metric.used, forKey: "\(key).used")
        defaults.set(metric.total, forKey: "\(key).total")
        defaults.set(metric.resetTime?.timeIntervalSince1970, forKey: "\(key).resetTime")
    }

    private func clearMetricCache(forKey key: String) {
        defaults.removeObject(forKey: "\(key).used")
        defaults.removeObject(forKey: "\(key).total")
        defaults.removeObject(forKey: "\(key).resetTime")
    }

    private func savePlanNameCache(_ planName: String) {
        defaults.set(planName, forKey: Self.planNameCacheKey)
    }

    private func loadPlanNameCache() -> String? {
        defaults.string(forKey: Self.planNameCacheKey)
    }

    // MARK: - gh CLI Token

    static func readGHCLIToken(now: Date = Date(), cacheTTL: TimeInterval? = nil) -> String? {
        let effectiveCacheTTL = max(0, cacheTTL ?? cacheTTLFromRefreshInterval())
        ghTokenCacheLock.lock()
        defer { ghTokenCacheLock.unlock() }

        if let lastLookupAt = ghTokenLastLookupAt,
           now.timeIntervalSince(lastLookupAt) < effectiveCacheTTL {
            return cachedGHCLIToken
        }

        let token = ghCLICommandRunner(ghTokenLookupTimeout)
        cachedGHCLIToken = token
        ghTokenLastLookupAt = now
        return token
    }

    static func resetGHCLITokenCache() {
        ghTokenCacheLock.lock()
        cachedGHCLIToken = nil
        ghTokenLastLookupAt = nil
        ghTokenCacheLock.unlock()
    }

    private static func cacheTTLFromRefreshInterval() -> TimeInterval {
        let refreshInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        return refreshInterval > 0 ? refreshInterval : defaultGHTokenCacheTTL
    }

    private static func runGHCLICommand(timeout: TimeInterval) -> String? {
        let commandConfiguration = ghCLICommandConfiguration
        return CLIProcessExecutor.executeCommand(
            executableURL: commandConfiguration.executableURL,
            arguments: commandConfiguration.arguments,
            timeout: timeout
        )
    }

    static func executeGHCLICommand(timeout: TimeInterval, runtime: GHCLIProcessRuntime) -> String? {
        CLIProcessExecutor.executeCommand(timeout: timeout, runtime: runtime)
    }

    // MARK: - Helpers

    static func capitalizedPlanName(_ raw: String) -> String {
        raw.capitalizingFirstCharacter()
    }

    static func firstOfNextMonthUTC(relativeTo now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let startOfMonth = calendar.date(from: components),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else {
            return now
        }
        return nextMonth
    }
}

private final class SendableDefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}
