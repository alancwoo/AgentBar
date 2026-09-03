import XCTest
import AppKit
import SwiftUI
@testable import AgentBar

@MainActor
final class FirstRunWindowControllerTests: XCTestCase {
    func testShowPresentsATitledWindowThatCannotBeDismissedWithoutChoosing() {
        FirstRunWindowController.shared.show { _ in }

        let window = NSApp.windows.first { $0.title == "Set Up AgentBar" }
        XCTAssertNotNil(window, "Setup should present a window.")
        guard let window else { return }

        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(
            window.styleMask.contains(.closable),
            "Closing without choosing would leave every provider disabled."
        )
        XCTAssertTrue(window.contentViewController is NSHostingController<FirstRunView>)

        window.close()
    }
}
