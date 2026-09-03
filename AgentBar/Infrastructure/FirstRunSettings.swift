import Foundation

/// Choices captured by the first-launch setup window.
struct FirstRunSelection: Sendable, Equatable {
    var services: Set<ServiceType>
    var launchAtLogin: Bool
    var refreshInterval: Double
    var appearance: StatusBarAppearance

    static let `default` = FirstRunSelection(
        services: [],
        launchAtLogin: true,
        refreshInterval: 60,
        appearance: .compact
    )
}

enum FirstRunSettings {
    static let completedKey = "firstRunSetupCompleted"

    /// Providers a user can track. `.opencode` only feeds notifications.
    static let selectableServices: [ServiceType] = [
        .claude, .codex, .gemini, .copilot, .cursor, .zai
    ]

    static func needsFirstRun(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: completedKey, defaultValue: false) {
            return false
        }

        // An install that already carries settings predates this window. Showing
        // setup there would disable providers the user had deliberately enabled.
        if hasExistingConfiguration(in: defaults) {
            defaults.set(true, forKey: completedKey)
            return false
        }

        return true
    }

    /// True when any AgentBar preference has already been written, which only
    /// happens after a previous version has run.
    static func hasExistingConfiguration(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: "launchAtLogin") != nil {
            return true
        }
        return selectableServices.contains {
            defaults.object(forKey: $0.enabledDefaultsKey) != nil
        }
    }

    /// Every provider defaults to enabled, so first launch would otherwise track
    /// services the user does not have — and prompt for their credentials.
    /// Turning them all off up front leaves the setup window in charge.
    static func seedDisabledProviders(in defaults: UserDefaults = .standard) {
        for service in selectableServices {
            defaults.set(false, forKey: service.enabledDefaultsKey)
        }
    }

    static func apply(_ selection: FirstRunSelection, in defaults: UserDefaults = .standard) {
        for service in selectableServices {
            defaults.set(selection.services.contains(service), forKey: service.enabledDefaultsKey)
        }
        defaults.set(selection.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(selection.refreshInterval, forKey: "refreshInterval")
        defaults.set(selection.appearance.rawValue, forKey: StatusBarAppearance.defaultsKey)
        defaults.set(true, forKey: completedKey)
    }
}

/// Looks for locally configured assistants so the setup window can pre-tick
/// the ones the user actually has.
enum ProviderDetection {
    static func detect() async -> Set<ServiceType> {
        let providers: [any UsageProviderProtocol] = [
            ClaudeUsageProvider(),
            CodexUsageProvider(),
            GeminiUsageProvider(),
            CopilotUsageProvider(),
            CursorUsageProvider(),
            ZaiUsageProvider()
        ]

        return await withTaskGroup(of: ServiceType?.self) { group in
            for provider in providers {
                group.addTask {
                    await provider.isConfigured() ? provider.serviceType : nil
                }
            }

            var detected: Set<ServiceType> = []
            for await service in group {
                if let service {
                    detected.insert(service)
                }
            }
            return detected
        }
    }
}
