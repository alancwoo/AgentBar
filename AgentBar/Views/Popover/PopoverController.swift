import Cocoa
import SwiftUI

@MainActor
final class PopoverController {
    static let shared = PopoverController()

    private var popover: NSPopover?
    private var isShown = false

    private init() {}

    func toggle(relativeTo button: NSButton, viewModel: UsageViewModel) {
        if isShown {
            hide()
        } else {
            show(relativeTo: button, viewModel: viewModel)
        }
    }

    func show(relativeTo button: NSButton, viewModel: UsageViewModel) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let hostingController = NSHostingController(
            rootView: DetailPopoverView(viewModel: viewModel)
        )
        // Let the popover follow the SwiftUI content's own height instead of a
        // fixed frame, so a short service list produces a short popover.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = hostingController.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.delegate = PopoverDelegateHandler.shared
        self.popover = popover
        isShown = true

        // Clear first responder so no button shows a focus ring on open.
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    func hide() {
        popover?.performClose(nil)
        popover = nil
        isShown = false
    }
}

// Simple delegate to track popover closure
@MainActor
private final class PopoverDelegateHandler: NSObject, NSPopoverDelegate {
    static let shared = PopoverDelegateHandler()

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            PopoverController.shared.hide()
        }
    }
}
