import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let viewModel = UsageViewModel()
    private let notifyMonitor = AgentNotifyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        let needsFirstRun = FirstRunSettings.needsFirstRun() && !isRunningTests
        if needsFirstRun {
            // Providers default to enabled, so nothing should be tracked (or
            // asked for credentials) until the user has actually chosen.
            FirstRunSettings.seedDisabledProviders()
            viewModel.rebuildProviders()
        }

        statusBarController = StatusBarController(viewModel: viewModel)
        statusBarController?.setup()
        viewModel.startMonitoring()
        AgentNotifySettingsMigrator.migrateIfNeeded()
        notifyMonitor.start()
        AppUpdateController.shared.start()

        if needsFirstRun {
            FirstRunWindowController.shared.showApplyingChoices()
        } else {
            registerLoginItemIfNeeded()
        }
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Terminate this instance if another copy is already running.
    /// Returns `true` if this process should exit.
    private func terminateIfAlreadyRunning() -> Bool {
        // Skip during unit tests — test host shares the bundle identifier.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }

        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }

        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// On first launch, register as a login item when the default is enabled.
    private func registerLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "launchAtLogin"
        // Only act on first launch (key not yet written by user)
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(true, forKey: key)
        try? LoginItemManager.setEnabled(true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopMonitoring()
        notifyMonitor.stop()
    }
}
