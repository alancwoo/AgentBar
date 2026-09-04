import XCTest
@testable import AgentBar

final class AppUpdateTests: XCTestCase {
    func testVersionParsesTheNumericCoreOfATag() {
        XCTAssertEqual(AppVersion(tag: "v0.7-fork")?.components, [0, 7])
        XCTAssertEqual(AppVersion(tag: "v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion(tag: "0.10")?.components, [0, 10])
        XCTAssertNil(AppVersion(tag: "abc1234"), "A commit hash has no version.")
        XCTAssertNil(AppVersion(tag: ""))
    }

    func testVersionComparesComponentWise() throws {
        let v07 = try XCTUnwrap(AppVersion(tag: "v0.7-fork"))
        let v08 = try XCTUnwrap(AppVersion(tag: "v0.8-fork"))
        let v010 = try XCTUnwrap(AppVersion(tag: "v0.10"))
        let v1 = try XCTUnwrap(AppVersion(tag: "v1"))

        XCTAssertLessThan(v07, v08)
        XCTAssertLessThan(v08, v010, "0.10 is newer than 0.8, not older.")
        XCTAssertLessThan(v010, v1)
        XCTAssertEqual(try XCTUnwrap(AppVersion(tag: "v1.0")), v1, "Missing components count as zero.")
    }

    func testReleaseResponseNeedsADmgAndSkipsDraftsAndPrereleases() throws {
        let json = """
        {"tag_name":"v0.8-fork","html_url":"https://github.com/alancwoo/AgentBar/releases/tag/v0.8-fork",
         "published_at":"2026-09-03T13:08:55Z","draft":false,"prerelease":false,
         "assets":[{"name":"AgentBar.dmg","browser_download_url":"https://github.com/alancwoo/AgentBar/releases/download/v0.8-fork/AgentBar.dmg"}]}
        """
        let release = try XCTUnwrap(
            JSONDecoder().decode(GitHubReleaseResponse.self, from: Data(json.utf8)).release()
        )
        XCTAssertEqual(release.tag, "v0.8-fork")
        XCTAssertEqual(release.version.components, [0, 8])
        XCTAssertEqual(release.dmgURL.lastPathComponent, "AgentBar.dmg")
        XCTAssertNotNil(release.publishedAt)

        let noDmg = """
        {"tag_name":"v0.9","html_url":"https://x","assets":[{"name":"Source.zip","browser_download_url":"https://x/s.zip"}]}
        """
        XCTAssertNil(try JSONDecoder().decode(GitHubReleaseResponse.self, from: Data(noDmg.utf8)).release())

        let prerelease = """
        {"tag_name":"v0.9","html_url":"https://x","prerelease":true,"assets":[{"name":"AgentBar.dmg","browser_download_url":"https://x/a.dmg"}]}
        """
        XCTAssertNil(try JSONDecoder().decode(GitHubReleaseResponse.self, from: Data(prerelease.utf8)).release())
    }

    func testNewerOnlyWhenTheRunningBuildHasAnOlderTag() {
        let release = AppRelease(
            tag: "v0.8-fork", version: AppVersion(tag: "v0.8-fork")!,
            pageURL: URL(string: "https://x")!, dmgURL: URL(string: "https://x/a.dmg")!, publishedAt: nil
        )
        XCTAssertTrue(AppUpdateChecker.isNewer(release, than: "v0.7-fork"))
        XCTAssertFalse(AppUpdateChecker.isNewer(release, than: "v0.8-fork"))
        XCTAssertFalse(AppUpdateChecker.isNewer(release, than: "v0.9-fork"))
        XCTAssertFalse(
            AppUpdateChecker.isNewer(release, than: nil),
            "An untagged (local) build should never nag about updates."
        )
        XCTAssertFalse(AppUpdateChecker.isNewer(release, than: "1307d6c"))
    }

    func testTeamIdentifierIsReadFromCodesignOutput() {
        let output = """
        Executable=/Applications/AgentBar.app/Contents/MacOS/AgentBar
        Identifier=com.agentbar.app
        Authority=Developer ID Application: Alan Woo (U2X6XGCCXR)
        TeamIdentifier=U2X6XGCCXR
        """
        XCTAssertEqual(AppUpdateInstaller.teamIdentifier(fromCodesignOutput: output), "U2X6XGCCXR")
        XCTAssertNil(AppUpdateInstaller.teamIdentifier(fromCodesignOutput: "TeamIdentifier=not set"))
        XCTAssertNil(AppUpdateInstaller.teamIdentifier(fromCodesignOutput: "Identifier=x"))
    }

    func testPreflightRefusesTranslocatedAndUnwritableLocations() {
        var translocated = AppUpdateInstaller()
        translocated.bundleURL = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/AgentBar.app")
        XCTAssertThrowsError(try translocated.preflight()) { error in
            guard case AppUpdateError.runningFromTranslocation = error else {
                return XCTFail("Expected translocation error, got \\(error)")
            }
        }

        var readOnly = AppUpdateInstaller()
        readOnly.bundleURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        XCTAssertThrowsError(try readOnly.preflight())
    }

    @MainActor
    func testControllerReportsAvailableOnlyForNewerReleases() async {
        let newer = AppRelease(
            tag: "v0.8-fork", version: AppVersion(tag: "v0.8-fork")!,
            pageURL: URL(string: "https://x")!, dmgURL: URL(string: "https://x/a.dmg")!, publishedAt: nil
        )
        let controller = AppUpdateController(checker: StubChecker(release: newer), currentTag: "v0.7-fork")
        await controller.checkNow()
        XCTAssertEqual(controller.state, .available(newer))

        let current = AppUpdateController(checker: StubChecker(release: newer), currentTag: "v0.8-fork")
        await current.checkNow()
        XCTAssertEqual(current.state, .idle)
    }

    @MainActor
    func testStatusRowReportsUpToDateOnlyAfterASuccessfulCheck() async {
        let newer = AppRelease(
            tag: "v0.8-fork", version: AppVersion(tag: "v0.8-fork")!,
            pageURL: URL(string: "https://x")!, dmgURL: URL(string: "https://x/a.dmg")!, publishedAt: nil
        )
        let fresh = AppUpdateController(checker: StubChecker(release: newer), currentTag: "v0.8-fork")
        XCTAssertNil(UpdateStatusRow.text(for: fresh), "Nothing to say before the first check.")

        await fresh.checkNow()
        XCTAssertTrue(UpdateStatusRow.text(for: fresh)?.hasPrefix("You're up to date") ?? false)
        XCTAssertFalse(fresh.lastCheckFailed)

        let outdated = AppUpdateController(checker: StubChecker(release: newer), currentTag: "v0.7-fork")
        await outdated.checkNow()
        XCTAssertEqual(UpdateStatusRow.text(for: outdated), "v0.8-fork is available")
    }

    @MainActor
    func testStatusRowSaysWhenGitHubWasUnreachable() async {
        let controller = AppUpdateController(checker: FailingChecker(), currentTag: "v0.8-fork")
        await controller.checkNow()

        XCTAssertTrue(controller.lastCheckFailed)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            UpdateStatusRow.text(for: controller),
            "Couldn't reach GitHub to check for updates.",
            "A failed check must not masquerade as up to date."
        )
    }

    @MainActor
    func testBannerTextPerState() {
        let release = AppRelease(
            tag: "v0.8-fork", version: AppVersion(tag: "v0.8-fork")!,
            pageURL: URL(string: "https://x")!, dmgURL: URL(string: "https://x/a.dmg")!, publishedAt: nil
        )
        XCTAssertEqual(UpdateBanner.text(for: .available(release)), "v0.8-fork is available")
        XCTAssertEqual(UpdateBanner.text(for: .downloading(release)), "Downloading v0.8-fork…")
        XCTAssertTrue(UpdateBanner.text(for: .failed(release, "boom")).contains("boom"))
        XCTAssertEqual(UpdateBanner.text(for: .idle), "")
    }
}

private struct FailingChecker: AppUpdateChecking {
    func latestRelease() async throws -> AppRelease? { throw APIError.invalidResponse }
}

private struct StubChecker: AppUpdateChecking {
    let release: AppRelease?
    func latestRelease() async throws -> AppRelease? { release }
}
