import Foundation

/// Health of a service as reported by its public status page.
enum ServiceHealth: Int, Sendable, Comparable, CaseIterable {
    case operational = 0
    case maintenance
    case degraded
    case partialOutage
    case majorOutage

    static func < (lhs: ServiceHealth, rhs: ServiceHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .operational: return "OK"
        case .maintenance: return "Maintenance"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial Outage"
        case .majorOutage: return "Major Outage"
        }
    }

    /// Statuspage.io component status strings.
    init?(statuspageComponentStatus raw: String) {
        switch raw.lowercased() {
        case "operational": self = .operational
        case "under_maintenance": self = .maintenance
        case "degraded_performance": self = .degraded
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        default: return nil
        }
    }
}

/// Where a service's status lives and which Statuspage components describe the
/// part of it AgentBar cares about.
struct StatusPageSource: Sendable, Equatable {
    enum ComponentMatch: Sendable, Equatable {
        case exact([String])
        case contains(String)
    }

    let pageURL: URL
    let match: ComponentMatch

    var componentsURL: URL {
        pageURL.appendingPathComponent("api/v2/components.json")
    }

    func matches(componentName: String) -> Bool {
        switch match {
        case .exact(let names):
            return names.contains { $0.caseInsensitiveCompare(componentName) == .orderedSame }
        case .contains(let fragment):
            return componentName.range(of: fragment, options: .caseInsensitive) != nil
        }
    }
}

enum StatusPageRegistry {
    /// Only services with a Statuspage.io-backed page are covered. Gemini, Grok
    /// and Z.ai have none that answers `/api/v2/components.json`.
    static func source(for service: ServiceType) -> StatusPageSource? {
        switch service {
        case .claude:
            return StatusPageSource(
                pageURL: URL(string: "https://status.claude.com")!,
                match: .exact(["Claude Code"])
            )
        case .codex:
            return StatusPageSource(
                pageURL: URL(string: "https://status.openai.com")!,
                match: .contains("Codex")
            )
        case .copilot:
            return StatusPageSource(
                pageURL: URL(string: "https://www.githubstatus.com")!,
                match: .contains("Copilot")
            )
        case .cursor:
            return StatusPageSource(
                pageURL: URL(string: "https://status.cursor.com")!,
                match: .exact(["IDE", "CLI"])
            )
        case .gemini, .grok, .opencode, .zai:
            return nil
        }
    }
}

struct StatuspageComponentsResponse: Decodable, Sendable {
    struct Component: Decodable, Sendable {
        let name: String
        let status: String
    }

    let components: [Component]

    /// Worst health across the components a source cares about; nil when none
    /// of them appear in the response.
    func health(for source: StatusPageSource) -> ServiceHealth? {
        components
            .filter { source.matches(componentName: $0.name) }
            .compactMap { ServiceHealth(statuspageComponentStatus: $0.status) }
            .max()
    }
}

protocol ServiceStatusMonitoring: Sendable {
    func health(for services: [ServiceType]) async -> [ServiceType: ServiceHealth]
}

/// Fetches each status page at most once per `cacheTTL`, since AgentBar polls
/// usage far more often than status pages change.
actor ServiceStatusMonitor: ServiceStatusMonitoring {
    static let cacheTTL: TimeInterval = 5 * 60

    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private var cache: [URL: (fetchedAt: Date, response: StatuspageComponentsResponse)] = [:]

    init(
        session: URLSession = .shared,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.nowProvider = nowProvider
    }

    func health(for services: [ServiceType]) async -> [ServiceType: ServiceHealth] {
        var result: [ServiceType: ServiceHealth] = [:]
        for service in services {
            guard let source = StatusPageRegistry.source(for: service),
                  let response = await components(from: source) else {
                continue
            }
            if let health = response.health(for: source) {
                result[service] = health
            }
        }
        return result
    }

    private func components(from source: StatusPageSource) async -> StatuspageComponentsResponse? {
        let now = nowProvider()
        if let cached = cache[source.componentsURL],
           now.timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached.response
        }

        var request = URLRequest(url: source.componentsURL, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(StatuspageComponentsResponse.self, from: data) else {
            // Keep serving the last good answer rather than flapping to unknown.
            return cache[source.componentsURL]?.response
        }

        cache[source.componentsURL] = (now, decoded)
        return decoded
    }
}
