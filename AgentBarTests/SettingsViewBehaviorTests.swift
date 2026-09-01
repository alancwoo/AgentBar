import XCTest
import AppKit
import SwiftUI
@testable import AgentBar

@MainActor
final class SettingsViewBehaviorTests: XCTestCase {
    func testCanSaveTokenAllowsMaskedPrefixWhenContainsRealCharacters() {
        XCTAssertTrue(SettingsView.canSaveToken("***real-token***"))
        XCTAssertTrue(SettingsView.canSaveToken("  token-with-space-trim  "))
    }

    func testTokenSaveAlertIDIncludesFailureMessage() {
        let saved = SettingsView.TokenSaveAlert.saved
        let failed = SettingsView.TokenSaveAlert.saveFailed("Keychain unavailable")

        XCTAssertEqual(saved.id, "saved")
        XCTAssertEqual(failed.id, "saveFailed:Keychain unavailable")
    }

    func testSettingsViewBodyBuildsWithoutCrashing() {
        let view = SettingsView(keychainSaveAction: { _, _ in })
        let body = view.body
        let mirror = Mirror(reflecting: body)

        XCTAssertFalse(
            mirror.children.isEmpty,
            "Expected SettingsView.body to build a non-empty view hierarchy."
        )
    }

    func testSettingsLayoutKeepsTabBarClearOfTitleBar() {
        XCTAssertGreaterThanOrEqual(
            SettingsLayout.tabBarTopPadding,
            8,
            "Tab control should not sit flush against the window title bar."
        )
        XCTAssertEqual(
            SettingsLayout.windowHeight,
            SettingsLayout.contentHeight + SettingsLayout.tabBarTopPadding + SettingsLayout.contentBottomPadding
        )
        XCTAssertEqual(
            SettingsLayout.windowWidth,
            SettingsLayout.contentWidth + SettingsLayout.contentHorizontalPadding * 2
        )
    }

    func testSettingsTabSupportsHistoryCase() {
        XCTAssertEqual(SettingsTab.history, .history)
    }

    func testCopilotLegacyManualPATMigrationEnablesFlagWhenSavedTokenExists() {
        let suiteName = "SettingsViewBehaviorTests.CopilotMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        var loadCallCount = 0
        CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: defaults) { account in
            loadCallCount += 1
            XCTAssertEqual(account, ServiceType.copilot.keychainAccount)
            return "ghp_legacy"
        }

        XCTAssertTrue(CopilotCredentialSettings.isManualPATEnabled(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: CopilotCredentialSettings.legacyManualPATMigrationCheckedKey))

        CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: defaults) { _ in
            loadCallCount += 1
            return nil
        }
        XCTAssertEqual(loadCallCount, 1, "Migration should check Keychain only once.")
    }

    func testCopilotLegacyManualPATMigrationMarksCheckedWhenNoSavedToken() {
        let suiteName = "SettingsViewBehaviorTests.CopilotMigrationNoToken.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: defaults) { _ in nil }

        XCTAssertFalse(CopilotCredentialSettings.isManualPATEnabled(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: CopilotCredentialSettings.legacyManualPATMigrationCheckedKey))
    }
}
