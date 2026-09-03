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
            return .compact
        }
        return appearance
    }

    var showsServiceLabel: Bool {
        self == .labeled
    }

    var displayName: String {
        switch self {
        case .labeled: return "Extended (Horizontal)"
        case .compact: return "Compact (Vertical)"
        }
    }

    var summary: String {
        switch self {
        case .labeled: return "Labelled rows, three at a time"
        case .compact: return "One colour per agent, narrowest"
        }
    }
}

enum StatusBarDisplayPlanner {
    static let visibleRowCount = 3
    static let rowHeight: CGFloat = 6
    static let rowSpacing: CGFloat = 1
    static let viewportHeight: CGFloat = 20

    /// Width of the labeled style's status item, which is fixed because the
    /// label + bar row is the same size no matter how many services there are.
    static let labeledItemLength: CGFloat = 90

    // Compact style: one thin vertical column per service, side by side.
    static let columnWidth: CGFloat = 5
    static let columnSpacing: CGFloat = 2
    static let horizontalInset: CGFloat = 2
    /// Breathing room above and below the columns, matching how system menu bar
    /// glyphs stay clear of the bar's edges.
    static let columnVerticalInset: CGFloat = 3
    static let minColumnHeight: CGFloat = 8
    static let maxColumnHeight: CGFloat = 20

    /// Columns fill the status item's height rather than a fixed size, so they
    /// adapt to the menu bar thickness (22pt, 24pt, notched displays).
    static func columnHeight(forItemHeight itemHeight: CGFloat) -> CGFloat {
        let available = itemHeight - columnVerticalInset * 2
        return min(maxColumnHeight, max(minColumnHeight, available))
    }
    /// Room for the placeholder/error glyph when there is nothing to chart.
    static let emptyItemLength: CGFloat = 24

    /// Inset between the status item button and the hosted SwiftUI bar. Compact
    /// budgets its own inset in `statusItemLength`, so it fills the button.
    static func hostingInset(for appearance: StatusBarAppearance) -> CGFloat {
        switch appearance {
        case .labeled: return 3
        case .compact: return 0
        }
    }

    /// Compact grows with the number of services, so a single service takes up
    /// as little of the menu bar as possible.
    static func statusItemLength(for appearance: StatusBarAppearance, serviceCount: Int) -> CGFloat {
        switch appearance {
        case .labeled:
            return labeledItemLength
        case .compact:
            guard serviceCount > 0 else { return emptyItemLength }
            let columns = CGFloat(serviceCount) * columnWidth
            let gaps = CGFloat(serviceCount - 1) * columnSpacing
            return columns + gaps + horizontalInset * 2
        }
    }

    static let topPriorityHoldSeconds: TimeInterval = 8
    static let scrollStepHoldSeconds: TimeInterval = 3
    static let scrollTransitionSeconds: TimeInterval = 1.2

    private static let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .grok, .opencode, .zai]

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

    /// Compact shows every service at once, so it keeps a stable service order
    /// instead of the usage ranking that drives the scrolling labeled style.
    static func orderedServices(from services: [UsageData]) -> [UsageData] {
        services
            .filter(\.isAvailable)
            .sorted { lhs, rhs in
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
