import Cocoa
import SwiftUI

@MainActor
final class InsightsWindowController {
    static let shared = InsightsWindowController()

    static let contentWidth: CGFloat = 720
    static let contentHeight: CGFloat = 620

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: InsightsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "AgentBar Insights"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(
            NSSize(width: Self.contentWidth, height: Self.contentHeight)
        )
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
