import XCTest
@testable import AgentBar

@MainActor
final class InsightsViewTests: XCTestCase {
    func testShowsWeekdayAxisOnlyForPrimaryWindow() {
        XCTAssertTrue(InsightsView.showsWeekdayAxis(for: .primary))
        XCTAssertFalse(InsightsView.showsWeekdayAxis(for: .secondary))
    }
}
