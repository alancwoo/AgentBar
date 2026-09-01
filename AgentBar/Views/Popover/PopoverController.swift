import Cocoa
import SwiftUI

@MainActor
final class PopoverController {
    static let shared = PopoverController()

    private var popover: NSPopover?
    private var isShown = false
    private var outsideClickMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

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

        startDismissMonitors()

        // Clear first responder so no button shows a focus ring on open.
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    /// `.transient` only reacts to interaction inside this app, so clicks in
    /// another app (or switching apps) are watched explicitly.
    private func startDismissMonitors() {
        stopDismissMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard activated?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func stopDismissMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
    }

    func hide() {
        stopDismissMonitors()
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
