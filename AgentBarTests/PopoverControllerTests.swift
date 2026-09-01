import XCTest
import AppKit
import SwiftUI
@testable import AgentBar

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testShowSetsShownStateAndConfiguresPopover() {
        let viewModel = UsageViewModel(providers: [])
        let (window, button) = makeButtonWindow()

        PopoverController.shared.show(relativeTo: button, viewModel: viewModel)

        let state = currentPopoverState()
        XCTAssertTrue(state.isShown)
        XCTAssertNotNil(state.popover)
        XCTAssertEqual(state.popover?.contentSize.width, DetailPopoverView.popoverWidth)
        XCTAssertGreaterThan(
            state.popover?.contentSize.height ?? 0,
            0,
            "Popover height should come from the SwiftUI content, not a fixed frame."
        )
        XCTAssertLessThanOrEqual(
            state.popover?.contentSize.height ?? .greatestFiniteMagnitude,
            DetailPopoverView.maxServiceListHeight + 300,
            "Popover should stay within the content cap plus header/footer chrome."
        )
        XCTAssertEqual(state.popover?.behavior, .transient)
        XCTAssertTrue(state.popover?.animates ?? false)
        XCTAssertTrue(state.popover?.contentViewController is NSHostingController<DetailPopoverView>)

        PopoverController.shared.hide()
        withExtendedLifetime(window) {}
    }

    func testToggleShowsThenHides() {
        let viewModel = UsageViewModel(providers: [])
        let (window, button) = makeButtonWindow()

        PopoverController.shared.toggle(relativeTo: button, viewModel: viewModel)
        XCTAssertTrue(currentPopoverState().isShown)

        PopoverController.shared.toggle(relativeTo: button, viewModel: viewModel)
        XCTAssertFalse(currentPopoverState().isShown)
        XCTAssertNil(currentPopoverState().popover)

        PopoverController.shared.hide()
        withExtendedLifetime(window) {}
    }

    private func makeButtonWindow() -> (NSWindow, NSButton) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let button = NSButton(title: "Toggle", target: nil, action: nil)
        button.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
        contentView.addSubview(button)

        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.contentView = contentView
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        return (window, button)
    }

    private func currentPopoverState() -> (popover: NSPopover?, isShown: Bool) {
        let mirror = Mirror(reflecting: PopoverController.shared)
        var popover: NSPopover?
        var isShown = false

        for child in mirror.children {
            if child.label == "popover" {
                popover = child.value as? NSPopover
            }
            if child.label == "isShown", let value = child.value as? Bool {
                isShown = value
            }
        }

        return (popover, isShown)
    }
}
