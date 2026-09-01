import Foundation
import CoreGraphics

/// How the menu bar item renders each service row.
enum StatusBarAppearance: String, CaseIterable, Sendable {
    /// Short service label (e.g. "CC") followed by the usage bar.
    case labeled
    /// Usage bar only — services are told apart by color.
    case compact

    static let defaultsKey = "statusBarAppearance"

    static func resolve(from defaults: UserDefaults = .standard) -> StatusBarAppearance {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let appearance = StatusBarAppearance(rawValue: rawValue) else {
            return .labeled
        }
        return appearance
    }

    var showsServiceLabel: Bool {
        self == .labeled
    }

    /// Width of the `NSStatusItem`. Compact drops the label column entirely.
    var statusItemLength: CGFloat {
        switch self {
        case .labeled: return 90
        case .compact: return 46
        }
    }

    var displayName: String {
        switch self {
        case .labeled: return "Labels + bars"
        case .compact: return "Bars only (compact)"
        }
    }
}

enum StatusBarDisplayPlanner {
    static let visibleRowCount = 3
    static let rowHeight: CGFloat = 6
    static let rowSpacing: CGFloat = 1
    static let viewportHeight: CGFloat = 20

    static let topPriorityHoldSeconds: TimeInterval = 8
    static let scrollStepHoldSeconds: TimeInterval = 3
    static let scrollTransitionSeconds: TimeInterval = 1.2

    private static let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai]

    static func rankedServices(from services: [UsageData]) -> [UsageData] {
        services
            .filter(\.isAvailable)
            .sorted { lhs, rhs in
                let lhsScore = usageScore(lhs)
                let rhsScore = usageScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                let lhsRank = serviceOrder.firstIndex(of: lhs.service) ?? serviceOrder.count
                let rhsRank = serviceOrder.firstIndex(of: rhs.service) ?? serviceOrder.count
                return lhsRank < rhsRank
            }
    }

    static func maxScrollIndex(for rankedServices: [UsageData]) -> Int {
        max(0, rankedServices.count - visibleRowCount)
    }

    private static func usageScore(_ data: UsageData) -> Double {
        let weekly = data.weeklyUsage?.percentage ?? 0
        return max(data.fiveHourUsage.percentage, weekly)
    }
}
