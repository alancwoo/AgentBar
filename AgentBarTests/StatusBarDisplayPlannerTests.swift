import XCTest
import SwiftUI
@testable import AgentBar

final class ServiceTypeColorTests: XCTestCase {
    func testCodexDarkColorIsGray400() {
        let color = ServiceType.codex.darkColor
        // gray-400: (0.60, 0.63, 0.67)
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        XCTAssertEqual(resolved.redComponent, 0.60, accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent, 0.63, accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent, 0.67, accuracy: 0.01)
    }

    func testAllServicesHaveDistinctDarkColors() {
        let colors = ServiceType.allCases.map { NSColor($0.darkColor).usingColorSpace(.sRGB)! }
        for i in 0..<colors.count {
            for j in (i + 1)..<colors.count {
                let same = abs(colors[i].redComponent - colors[j].redComponent) < 0.05
                    && abs(colors[i].greenComponent - colors[j].greenComponent) < 0.05
                    && abs(colors[i].blueComponent - colors[j].blueComponent) < 0.05
                XCTAssertFalse(same, "\(ServiceType.allCases[i]) and \(ServiceType.allCases[j]) have nearly identical darkColor")
            }
        }
    }
}

final class StatusBarAppearanceTests: XCTestCase {
    private let suiteName = "StatusBarAppearanceTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testResolvesCompactByDefault() {
        XCTAssertEqual(
            StatusBarAppearance.resolve(from: makeDefaults()),
            .compact,
            "New installs should start with the narrowest style."
        )
    }

    func testResolvesCompactWhenStored() {
        let defaults = makeDefaults()
        defaults.set(StatusBarAppearance.compact.rawValue, forKey: StatusBarAppearance.defaultsKey)
        XCTAssertEqual(StatusBarAppearance.resolve(from: defaults), .compact)
    }

    func testResolvesDefaultForUnknownStoredValue() {
        let defaults = makeDefaults()
        defaults.set("bogus", forKey: StatusBarAppearance.defaultsKey)
        XCTAssertEqual(StatusBarAppearance.resolve(from: defaults), .compact)
    }

    func testCompactHidesServiceLabel() {
        XCTAssertTrue(StatusBarAppearance.labeled.showsServiceLabel)
        XCTAssertFalse(StatusBarAppearance.compact.showsServiceLabel)
    }

    func testAppearanceNamesDescribeTheirOrientation() {
        XCTAssertEqual(StatusBarAppearance.compact.displayName, "Compact (Vertical)")
        XCTAssertEqual(StatusBarAppearance.labeled.displayName, "Extended (Horizontal)")
        for appearance in StatusBarAppearance.allCases {
            XCTAssertFalse(appearance.summary.isEmpty)
        }
    }
}

final class StatusBarDisplayPlannerTests: XCTestCase {
    func testRanksServicesByHighestUsageScoreDescending() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.20, weeklyPct: 0.40),
            makeUsage(service: .codex, fiveHourPct: 0.90, weeklyPct: 0.10),
            makeUsage(service: .gemini, fiveHourPct: 0.50, weeklyPct: 0.60)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.codex, .gemini, .claude])
    }

    func testIgnoresUnavailableServicesWhenRanking() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.8),
            makeUsage(service: .codex, fiveHourPct: 0.7),
            makeUsage(service: .gemini, fiveHourPct: 0.9, available: false)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.claude, .codex])
    }

    func testCompactWidthGrowsOneColumnPerService() {
        let single = StatusBarDisplayPlanner.statusItemLength(for: .compact, serviceCount: 1)
        let triple = StatusBarDisplayPlanner.statusItemLength(for: .compact, serviceCount: 3)

        XCTAssertEqual(
            single,
            StatusBarDisplayPlanner.columnWidth + StatusBarDisplayPlanner.horizontalInset * 2
        )
        XCTAssertEqual(
            triple,
            StatusBarDisplayPlanner.columnWidth * 3
                + StatusBarDisplayPlanner.columnSpacing * 2
                + StatusBarDisplayPlanner.horizontalInset * 2
        )
        XCTAssertLessThan(single, triple)
    }

    func testCompactSingleServiceIsFarNarrowerThanLabeled() {
        let compact = StatusBarDisplayPlanner.statusItemLength(for: .compact, serviceCount: 1)
        let labeled = StatusBarDisplayPlanner.statusItemLength(for: .labeled, serviceCount: 1)

        XCTAssertEqual(labeled, StatusBarDisplayPlanner.labeledItemLength)
        XCTAssertLessThan(compact, labeled / 4)
    }

    func testLabeledWidthIsIndependentOfServiceCount() {
        XCTAssertEqual(
            StatusBarDisplayPlanner.statusItemLength(for: .labeled, serviceCount: 1),
            StatusBarDisplayPlanner.statusItemLength(for: .labeled, serviceCount: 6)
        )
    }

    func testColumnHeightFillsMenuBarHeightMinusInsets() {
        XCTAssertEqual(
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 24),
            24 - StatusBarDisplayPlanner.columnVerticalInset * 2
        )
        XCTAssertEqual(
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 22),
            22 - StatusBarDisplayPlanner.columnVerticalInset * 2
        )
    }

    func testColumnHeightIsClampedToSaneBounds() {
        XCTAssertEqual(
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 200),
            StatusBarDisplayPlanner.maxColumnHeight
        )
        XCTAssertEqual(
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 0),
            StatusBarDisplayPlanner.minColumnHeight
        )
    }

    func testColumnHeightGrowsWithMenuBarHeight() {
        XCTAssertGreaterThan(
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 24),
            StatusBarDisplayPlanner.columnHeight(forItemHeight: 18)
        )
    }

    func testCompactFallsBackToGlyphWidthWithNoServices() {
        XCTAssertEqual(
            StatusBarDisplayPlanner.statusItemLength(for: .compact, serviceCount: 0),
            StatusBarDisplayPlanner.emptyItemLength
        )
    }

    func testOrderedServicesKeepsFixedServiceOrderRegardlessOfUsage() {
        let services = [
            makeUsage(service: .zai, fiveHourPct: 0.90),
            makeUsage(service: .codex, fiveHourPct: 0.10),
            makeUsage(service: .claude, fiveHourPct: 0.50)
        ]

        let ordered = StatusBarDisplayPlanner.orderedServices(from: services)
        XCTAssertEqual(ordered.map(\.service), [.claude, .codex, .zai])
    }

    func testOrderedServicesIgnoresUnavailableServices() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.5),
            makeUsage(service: .codex, fiveHourPct: 0.5, available: false)
        ]

        XCTAssertEqual(
            StatusBarDisplayPlanner.orderedServices(from: services).map(\.service),
            [.claude]
        )
    }

    func testCompactHostingInsetIsZeroSoTinyItemsUseFullWidth() {
        XCTAssertEqual(StatusBarDisplayPlanner.hostingInset(for: .compact), 0)
        XCTAssertGreaterThan(StatusBarDisplayPlanner.hostingInset(for: .labeled), 0)
    }

    func testMaxScrollIndexIsZeroWhenServicesWithinVisibleCount() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.95),
            makeUsage(service: .codex, fiveHourPct: 0.90),
            makeUsage(service: .gemini, fiveHourPct: 0.85)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(StatusBarDisplayPlanner.maxScrollIndex(for: ranked), 0)
    }

    func testMaxScrollIndexEqualsOverflowRowCount() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.99),
            makeUsage(service: .codex, fiveHourPct: 0.98),
            makeUsage(service: .gemini, fiveHourPct: 0.97),
            makeUsage(service: .copilot, fiveHourPct: 0.96),
            makeUsage(service: .cursor, fiveHourPct: 0.95),
            makeUsage(service: .zai, fiveHourPct: 0.94),
            makeUsage(service: .claude, fiveHourPct: 0.93)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(StatusBarDisplayPlanner.maxScrollIndex(for: ranked), 4)
    }

    func testTieBreakUsesServiceOrder() {
        let services = [
            makeUsage(service: .zai, fiveHourPct: 0.50),
            makeUsage(service: .codex, fiveHourPct: 0.50),
            makeUsage(service: .claude, fiveHourPct: 0.50)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.claude, .codex, .zai])
    }

    func testTopPriorityHoldIsLongerThanStepHold() {
        XCTAssertGreaterThan(
            StatusBarDisplayPlanner.topPriorityHoldSeconds,
            StatusBarDisplayPlanner.scrollStepHoldSeconds
        )
    }

    private func makeUsage(
        service: ServiceType,
        fiveHourPct: Double,
        weeklyPct: Double = 0,
        available: Bool = true
    ) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(
                used: fiveHourPct * 100,
                total: 100,
                unit: .percent,
                resetTime: nil
            ),
            weeklyUsage: UsageMetric(
                used: weeklyPct * 100,
                total: 100,
                unit: .percent,
                resetTime: nil
            ),
            lastUpdated: Date(),
            isAvailable: available
        )
    }
}
