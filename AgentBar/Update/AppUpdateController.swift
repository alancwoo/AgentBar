import Foundation
import AppKit
import Combine

enum AppUpdateState: Equatable {
    case idle
    case available(AppRelease)
    case downloading(AppRelease)
    case installing(AppRelease)
    case failed(AppRelease, String)
}

/// Checks GitHub for a newer release on a schedule and drives the install.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    static let initialDelay: TimeInterval = 15
    static let checkInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let checker: any AppUpdateChecking
    private let currentTag: String?
    private var timer: AnyCancellable?
    private var installer: AppUpdateInstaller

    init(
        checker: any AppUpdateChecking = AppUpdateChecker(),
        currentTag: String? = Bundle.main.infoDictionary?["GitVersionTag"] as? String,
        installer: AppUpdateInstaller = AppUpdateInstaller()
    ) {
        self.checker = checker
        self.currentTag = currentTag
        self.installer = installer
    }

    func start() {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.initialDelay * 1_000_000_000))
            await checkNow()
        }
        timer = Timer.publish(every: Self.checkInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.checkNow() }
            }
    }

    func checkNow() async {
        lastCheckedAt = Date()
        guard let release = try? await checker.latestRelease() else { return }
        // Don't clobber an install that is in flight.
        switch state {
        case .downloading, .installing:
            return
        default:
            break
        }
        state = AppUpdateChecker.isNewer(release, than: currentTag) ? .available(release) : .idle
    }

    func install() {
        guard case .available(let release) = state else {
            if case .failed(let release, _) = state {
                state = .available(release)
                install()
            }
            return
        }

        state = .downloading(release)
        let installer = installer
        Task {
            do {
                try await installer.install(release) { _ in }
                state = .installing(release)
                installer.relaunch()
            } catch {
                state = .failed(release, error.localizedDescription)
            }
        }
    }

    func openReleasePage() {
        switch state {
        case .available(let release), .downloading(let release), .installing(let release), .failed(let release, _):
            NSWorkspace.shared.open(release.pageURL)
        case .idle:
            break
        }
    }

    #if DEBUG
    func setStateForTesting(_ state: AppUpdateState) {
        self.state = state
    }
    #endif
}
