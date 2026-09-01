import Cocoa
import SwiftUI
import Combine

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StackedBarView>?
    private var cancellables: Set<AnyCancellable> = []
    private var setupRetryCount = 0
    private let maxSetupRetries = 10

    private let viewModel: UsageViewModel
    private let defaults: UserDefaults
    private var appearance: StatusBarAppearance

    init(viewModel: UsageViewModel, defaults: UserDefaults = .standard) {
        self.viewModel = viewModel
        self.defaults = defaults
        self.appearance = StatusBarAppearance.resolve(from: defaults)
    }

    func setup() {
        appearance = StatusBarAppearance.resolve(from: defaults)

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: appearance.statusItemLength)
        } else {
            statusItem?.length = appearance.statusItemLength
        }

        guard let button = statusItem?.button else {
            retrySetup()
            return
        }

        setupRetryCount = 0
        hostingView?.removeFromSuperview()

        let barView = StackedBarView(
            services: viewModel.usageData,
            hasError: viewModel.lastError != nil,
            appearance: appearance
        )
        let hosting = NSHostingView(rootView: barView)
        hosting.frame = button.bounds.insetBy(dx: 3, dy: 0)
        hosting.autoresizingMask = [.width, .height]
        button.addSubview(hosting)
        self.hostingView = hosting

        if cancellables.isEmpty {
            // Observe ViewModel changes
            viewModel.$usageData
                .combineLatest(viewModel.$lastError)
                .receive(on: RunLoop.main)
                .sink { [weak self] data, error in
                    guard let self else { return }
                    self.hostingView?.rootView = StackedBarView(
                        services: data,
                        hasError: error != nil,
                        appearance: self.appearance
                    )
                }
                .store(in: &cancellables)

            NotificationCenter.default
                .publisher(for: .statusBarAppearanceChanged)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.applyAppearance()
                }
                .store(in: &cancellables)
        }

        // Click action — toggle popover
        button.target = self
        button.action = #selector(statusItemClicked)
    }

    /// Re-reads the menu bar style setting and resizes/redraws the status item.
    func applyAppearance() {
        appearance = StatusBarAppearance.resolve(from: defaults)
        statusItem?.length = appearance.statusItemLength
        hostingView?.rootView = StackedBarView(
            services: viewModel.usageData,
            hasError: viewModel.lastError != nil,
            appearance: appearance
        )
    }

    #if DEBUG
    var currentAppearanceForTesting: StatusBarAppearance {
        appearance
    }
    #endif

    private func retrySetup() {
        guard setupRetryCount < maxSetupRetries else { return }
        setupRetryCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setup()
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        PopoverController.shared.toggle(relativeTo: button, viewModel: viewModel)
    }
}
