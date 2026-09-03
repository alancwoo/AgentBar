import XCTest
@testable import AgentBar

final class FirstRunSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FirstRunSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstRunIsNeededUntilSetupCompletes() {
        XCTAssertTrue(FirstRunSettings.needsFirstRun(in: defaults))

        FirstRunSettings.apply(.default, in: defaults)

        XCTAssertFalse(
            FirstRunSettings.needsFirstRun(in: defaults),
            "Setup should only be shown once."
        )
    }

    func testExistingInstallsSkipSetupAndAreMarkedComplete() {
        // A previous version always writes launchAtLogin on first launch.
        defaults.set(true, forKey: "launchAtLogin")

        XCTAssertFalse(
            FirstRunSettings.needsFirstRun(in: defaults),
            "Upgrading users must not have their providers reset."
        )
        XCTAssertTrue(
            defaults.bool(forKey: FirstRunSettings.completedKey),
            "The check should record itself so it is not repeated."
        )
    }

    func testAnEnabledProviderAlsoCountsAsAnExistingInstall() {
        defaults.set(true, forKey: ServiceType.claude.enabledDefaultsKey)

        XCTAssertTrue(FirstRunSettings.hasExistingConfiguration(in: defaults))
        XCTAssertFalse(FirstRunSettings.needsFirstRun(in: defaults))
    }

    func testCleanDomainCountsAsAFreshInstall() {
        XCTAssertFalse(FirstRunSettings.hasExistingConfiguration(in: defaults))
        XCTAssertTrue(FirstRunSettings.needsFirstRun(in: defaults))
    }

    func testSeedingDisablesEveryProvider() {
        // Providers default to enabled when their key is absent.
        for service in FirstRunSettings.selectableServices {
            XCTAssertTrue(defaults.bool(forKey: service.enabledDefaultsKey, defaultValue: true))
        }

        FirstRunSettings.seedDisabledProviders(in: defaults)

        for service in FirstRunSettings.selectableServices {
            XCTAssertFalse(
                defaults.bool(forKey: service.enabledDefaultsKey, defaultValue: true),
                "\(service.rawValue) should be off until the user opts in."
            )
        }
    }

    func testApplyWritesOnlyTheChosenServices() {
        let selection = FirstRunSelection(
            services: [.claude, .cursor],
            launchAtLogin: false,
            refreshInterval: 120,
            appearance: .labeled
        )

        FirstRunSettings.apply(selection, in: defaults)

        XCTAssertTrue(defaults.bool(forKey: ServiceType.claude.enabledDefaultsKey))
        XCTAssertTrue(defaults.bool(forKey: ServiceType.cursor.enabledDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: ServiceType.codex.enabledDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: ServiceType.gemini.enabledDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: ServiceType.copilot.enabledDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: ServiceType.zai.enabledDefaultsKey))

        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(defaults.double(forKey: "refreshInterval"), 120)
        XCTAssertEqual(
            defaults.string(forKey: StatusBarAppearance.defaultsKey),
            StatusBarAppearance.labeled.rawValue
        )
    }

    func testDefaultSelectionMatchesTheDocumentedDefaults() {
        XCTAssertTrue(FirstRunSelection.default.launchAtLogin)
        XCTAssertEqual(FirstRunSelection.default.refreshInterval, 60)
        XCTAssertEqual(FirstRunSelection.default.appearance, .compact)
        XCTAssertTrue(FirstRunSelection.default.services.isEmpty)
    }

    func testSelectableServicesExcludeNotificationOnlySources() {
        XCTAssertEqual(FirstRunSettings.selectableServices.count, 6)
        XCTAssertFalse(
            FirstRunSettings.selectableServices.contains(.opencode),
            "OpenCode has no usage provider — it only feeds notifications."
        )
    }
}
