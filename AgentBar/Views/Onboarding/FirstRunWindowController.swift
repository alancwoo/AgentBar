import Cocoa
import SwiftUI

@MainActor
final class FirstRunWindowController {
    static let shared = FirstRunWindowController()

    private var window: NSWindow?

    private init() {}

    /// Shows the setup window and reports the chosen settings once dismissed.
    func show(onFinish: @escaping (FirstRunSelection) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: FirstRunView { [weak self] selection in
                onFinish(selection)
                self?.close()
            }
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up AgentBar"
        // No close button: dismissing without choosing would leave every
        // provider off with no explanation.
        window.styleMask = [.titled]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
    }
}
