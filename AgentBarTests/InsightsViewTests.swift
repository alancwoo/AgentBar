import XCTest
@testable import AgentBar

@MainActor
final class InsightsViewTests: XCTestCase {
    func testWeekdayAxisLabelsEveryRowStartingSunday() {
        // The view model builds the grid with firstWeekday = 1 (Sunday).
        XCTAssertEqual(InsightsView.weekdayInitials, ["S", "M", "T", "W", "T", "F", "S"])
        XCTAssertEqual(
            InsightsView.weekdayInitials.count,
            7,
            "Every heatmap row needs its own label, in both cycles."
        )
    }

    func testHelpTextCoversBothTheCycleAndTheCharts() {
        for window in [UsageHistoryWindow.primary, .secondary] {
            let help = InsightsView.helpText(for: window)
            XCTAssertTrue(help.contains(InsightsView.windowExplanation(for: window)))
            XCTAssertTrue(help.contains(InsightsView.chartExplanation))
        }
    }

    func testWindowExplanationsDifferPerCycle() {
        XCTAssertNotEqual(
            InsightsView.windowExplanation(for: .primary),
            InsightsView.windowExplanation(for: .secondary)
        )
    }
}
