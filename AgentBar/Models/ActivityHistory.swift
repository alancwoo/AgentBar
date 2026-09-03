import Foundation

/// One day of an assistant's activity, reconstructed from its local session
/// logs rather than sampled while AgentBar was running — so it reaches back to
/// the user's first session, not AgentBar's first launch.
struct ActivityDayRecord: Codable, Sendable, Equatable {
    let service: ServiceType
    let dayStart: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var messages: Int
    var sessions: Int

    /// Everything the model processed, which is what rate limits weigh.
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    static func empty(service: ServiceType, dayStart: Date) -> ActivityDayRecord {
        ActivityDayRecord(
            service: service,
            dayStart: dayStart,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            messages: 0,
            sessions: 0
        )
    }
}

struct ActivitySummary: Sendable, Equatable {
    let totalTokens: Int
    let activeDays: Int
    let sessions: Int
    let busiestDay: Date?
    let busiestDayTokens: Int
    let averageTokensPerActiveDay: Int

    static let empty = ActivitySummary(
        totalTokens: 0,
        activeDays: 0,
        sessions: 0,
        busiestDay: nil,
        busiestDayTokens: 0,
        averageTokensPerActiveDay: 0
    )
}

/// A local-log reader that can rebuild daily activity for one service.
protocol ActivityHistorySource: Sendable {
    var service: ServiceType { get }
    func scan(calendar: Calendar) async -> [ActivityDayRecord]
}
