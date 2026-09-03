import Foundation
import Combine

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: [UsageData] = []
    @Published var lastError: String?
    @Published var isLoading: Bool = false

    private static let serviceOrder: [ServiceType] = [
        .claude, .codex, .gemini, .copilot, .cursor, .grok, .opencode, .zai
    ]

    private var providers: [any UsageProviderProtocol]
    private let historyStore: UsageHistoryStoreProtocol
    /// Filters providers down to tools actually used on this Mac. nil disables
    /// filtering (tests inject their own providers and expect all of them).
    private let activityMonitor: ProviderActivityMonitor?
    private let refreshInterval: TimeInterval
    private var timerCancellable: AnyCancellable?
    private var limitsCancellable: AnyCancellable?
    init(
        providers: [any UsageProviderProtocol]? = nil,
        refreshInterval: TimeInterval = 60,
        historyStore: UsageHistoryStoreProtocol = UsageHistoryStore(),
        activityMonitor: ProviderActivityMonitor? = nil
    ) {
        self.refreshInterval = refreshInterval
        self.providers = providers ?? Self.buildProviders()
        self.historyStore = historyStore
        self.activityMonitor = activityMonitor ?? (providers == nil ? ProviderActivityMonitor() : nil)

        if providers == nil {
            limitsCancellable = NotificationCenter.default
                .publisher(for: .limitsChanged)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.rebuildProviders()
                }
        }
    }

    func startMonitoring() {
        // Initial fetch
        Task { await fetchAllUsage() }

        // Periodic refresh
        timerCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.fetchAllUsage()
                }
            }
    }

    func stopMonitoring() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    func rebuildProviders() {
        providers = Self.buildProviders()
        activityMonitor?.invalidate()
        Task { await fetchAllUsage() }
    }

    func fetchAllUsage() async {
        isLoading = true
        defer { isLoading = false }

        var results: [UsageData] = []
        var successfulResults: [UsageData] = []
        let activeServices = activeServicesFilter()

        await withTaskGroup(of: ProviderFetchOutcome?.self) { group in
            for provider in providers {
                if let activeServices, !activeServices.contains(provider.serviceType) {
                    continue
                }
                group.addTask {
                    guard await provider.isConfigured() else { return nil }
                    do {
                        let usage = try await provider.fetchUsage()
                        return ProviderFetchOutcome(data: usage, shouldRecordHistory: true)
                    } catch {
                        // Return zero usage so the bar stays visible
                        return ProviderFetchOutcome(
                            data: Self.zeroUsageData(for: provider.serviceType),
                            shouldRecordHistory: false
                        )
                    }
                }
            }

            for await result in group {
                if let result {
                    results.append(result.data)
                    if result.shouldRecordHistory {
                        successfulResults.append(result.data)
                    }
                }
            }
        }

        results.sort { a, b in
            Self.sortIndex(for: a.service) < Self.sortIndex(for: b.service)
        }

        usageData = results
        if results.isEmpty {
            lastError = activeServices != nil && !providers.isEmpty
                ? "No recently used AI tools detected"
                : "No data available"
        } else {
            lastError = nil
        }

        guard !successfulResults.isEmpty else { return }
        await historyStore.record(samples: successfulResults, recordedAt: Date())
        NotificationCenter.default.post(name: .usageHistoryChanged, object: nil)
    }

    /// Services with recent local activity, or nil when auto-detection is off.
    private func activeServicesFilter() -> Set<ServiceType>? {
        guard let activityMonitor,
              ProviderActivityDetector.isAutoDetectEnabled(in: UserDefaults.standard) else {
            return nil
        }
        return activityMonitor.activeServices()
    }

    private static func sortIndex(for service: ServiceType) -> Int {
        serviceOrder.firstIndex(of: service) ?? Int.max
    }

    nonisolated private static func zeroUsageData(for service: ServiceType) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(used: 0, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true,
            planName: storedPlanName(for: service)
        )
    }

    nonisolated private static func storedPlanName(for service: ServiceType) -> String? {
        let defaults = UserDefaults.standard
        switch service {
        case .claude:
            return ClaudeUsageProvider.resolvedPlanName(
                defaults: defaults,
                detectedPlan: { ClaudeUsageProvider.detectedPlanName() }
            )
        case .codex:
            return defaults.string(forKey: "codexPlan")
        case .cursor:
            return defaults.string(forKey: "cursorPlan")
        case .grok:
            return defaults.string(forKey: GrokUsageProvider.detectedPlanDefaultsKey)
        default:
            return nil
        }
    }

    // MARK: - Provider Factory

    private static func buildProviders() -> [any UsageProviderProtocol] {
        let defaults = UserDefaults.standard
        var providers: [any UsageProviderProtocol] = []

        if isEnabled("claudeEnabled", in: defaults) {
            providers.append(ClaudeUsageProvider())
        }

        if isEnabled("codexEnabled", in: defaults) {
            let codexLimits = codexTokenLimits(in: defaults)
            providers.append(CodexUsageProvider(
                fiveHourTokenLimit: codexLimits.fiveHour,
                weeklyTokenLimit: codexLimits.weekly
            ))
        }

        if isEnabled("geminiEnabled", in: defaults) {
            providers.append(GeminiUsageProvider(
                dailyRequestLimit: geminiDailyLimit(in: defaults)
            ))
        }

        if isEnabled("copilotEnabled", in: defaults) {
            providers.append(CopilotUsageProvider())
        }

        if isEnabled("cursorEnabled", in: defaults) {
            providers.append(CursorUsageProvider(
                monthlyRequestLimit: cursorMonthlyLimit(in: defaults)
            ))
        }

        if isEnabled("grokEnabled", in: defaults) {
            providers.append(GrokUsageProvider())
        }

        if isEnabled("zaiEnabled", in: defaults) {
            providers.append(ZaiUsageProvider())
        }

        return providers
    }

    private static func isEnabled(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key, defaultValue: true)
    }

    private static func codexTokenLimits(in defaults: UserDefaults) -> (fiveHour: Double, weekly: Double) {
        let planRaw = defaults.string(forKey: "codexPlan") ?? CodexPlan.pro.rawValue
        let plan = CodexPlan(rawValue: planRaw) ?? .pro

        if plan == .custom {
            return (
                defaults.double(forKey: "codexFiveHourLimit").nonZero ?? CodexPlan.pro.fiveHourTokenLimit,
                defaults.double(forKey: "codexWeeklyLimit").nonZero ?? CodexPlan.pro.weeklyTokenLimit
            )
        }

        return (plan.fiveHourTokenLimit, plan.weeklyTokenLimit)
    }

    private static func geminiDailyLimit(in defaults: UserDefaults) -> Double {
        defaults.double(forKey: "geminiDailyLimit").nonZero ?? 1_000
    }

    private static func cursorMonthlyLimit(in defaults: UserDefaults) -> Double {
        let plan = CursorPlan.resolveAndMigrateStoredPlan(in: defaults)
        if plan == .custom {
            return defaults.double(forKey: "cursorMonthlyLimit").nonZero ?? CursorPlan.pro.monthlyRequestEstimate
        }
        return plan.monthlyRequestEstimate
    }
}

private struct ProviderFetchOutcome: Sendable {
    let data: UsageData
    let shouldRecordHistory: Bool
}

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
