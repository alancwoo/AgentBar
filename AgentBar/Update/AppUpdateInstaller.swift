import Foundation
import AppKit

enum AppUpdateError: LocalizedError {
    case runningFromTranslocation
    case destinationNotWritable(URL)
    case mountFailed(String)
    case appNotFoundInImage
    case signatureRejected(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .runningFromTranslocation:
            return "Move AgentBar to Applications first, then update."
        case .destinationNotWritable(let url):
            return "Cannot write to \(url.deletingLastPathComponent().path)."
        case .mountFailed(let detail):
            return "Could not open the downloaded image: \(detail)"
        case .appNotFoundInImage:
            return "The downloaded image does not contain AgentBar."
        case .signatureRejected(let detail):
            return "The download failed verification: \(detail)"
        case .copyFailed(let detail):
            return "Could not replace the app: \(detail)"
        }
    }
}

/// Downloads a release DMG, verifies the app inside it, swaps it over the
/// running bundle and relaunches. The running process keeps its mapped
/// binary, so replacing the bundle on disk is safe until the relaunch.
struct AppUpdateInstaller {
    var bundleURL: URL = Bundle.main.bundleURL
    var fileManager: FileManager = .default
    var session: URLSession = .shared

    /// Team ID the replacement must be signed by — the same one as this build.
    var expectedTeamIdentifier: String? = AppUpdateInstaller.currentTeamIdentifier()

    static let appName = "AgentBar.app"

    func install(_ release: AppRelease, progress: @Sendable @escaping (Double) -> Void) async throws {
        try preflight()

        let dmgURL = try await download(release.dmgURL, progress: progress)
        defer { try? fileManager.removeItem(at: dmgURL) }

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("AgentBarUpdate-\(UUID().uuidString)", isDirectory: true)
        try mount(dmgURL, at: mountPoint)
        defer { detach(mountPoint) }

        let candidate = mountPoint.appendingPathComponent(Self.appName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw AppUpdateError.appNotFoundInImage
        }

        try verify(candidate)
        try replaceBundle(with: candidate)
    }

    func relaunch() {
        // A detached shell survives our exit and reopens the replaced bundle.
        let script = "sleep 0.8; /usr/bin/open -n \"\(bundleURL.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Steps

    func preflight() throws {
        if bundleURL.path.contains("/AppTranslocation/") {
            throw AppUpdateError.runningFromTranslocation
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path),
              fileManager.isWritableFile(atPath: bundleURL.path) else {
            throw AppUpdateError.destinationNotWritable(bundleURL)
        }
    }

    private func download(_ url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let (temporary, response) = try await session.download(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        progress(1)
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("AgentBar-\(UUID().uuidString).dmg")
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    private func mount(_ dmg: URL, at mountPoint: URL) throws {
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = Self.run(
            "/usr/bin/hdiutil",
            ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountPoint.path]
        )
        guard result.status == 0 else {
            throw AppUpdateError.mountFailed(result.output)
        }
    }

    private func detach(_ mountPoint: URL) {
        _ = Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        try? fileManager.removeItem(at: mountPoint)
    }

    /// Refuses anything that is not a valid, notarized bundle from our own team.
    func verify(_ app: URL) throws {
        let codesign = Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.status == 0 else {
            throw AppUpdateError.signatureRejected(codesign.output)
        }

        if let expected = expectedTeamIdentifier {
            let info = Self.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
            guard let team = Self.teamIdentifier(fromCodesignOutput: info.output),
                  team == expected else {
                throw AppUpdateError.signatureRejected("signed by a different team")
            }
        }

        let gatekeeper = Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else {
            throw AppUpdateError.signatureRejected("not accepted by Gatekeeper")
        }
    }

    private func replaceBundle(with candidate: URL) throws {
        let parent = bundleURL.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".AgentBar-update-\(UUID().uuidString).app")
        let retired = parent.appendingPathComponent(".AgentBar-previous-\(UUID().uuidString).app")

        // ditto preserves signatures and extended attributes; a plain copy can
        // leave the bundle unsigned in Gatekeeper's eyes.
        let copy = Self.run("/usr/bin/ditto", [candidate.path, staged.path])
        guard copy.status == 0 else {
            throw AppUpdateError.copyFailed(copy.output)
        }

        do {
            try fileManager.moveItem(at: bundleURL, to: retired)
            try fileManager.moveItem(at: staged, to: bundleURL)
        } catch {
            // Put the old bundle back if the swap failed halfway.
            if !fileManager.fileExists(atPath: bundleURL.path),
               fileManager.fileExists(atPath: retired.path) {
                try? fileManager.moveItem(at: retired, to: bundleURL)
            }
            try? fileManager.removeItem(at: staged)
            throw AppUpdateError.copyFailed(error.localizedDescription)
        }
        try? fileManager.removeItem(at: retired)
    }

    // MARK: - Helpers

    static func currentTeamIdentifier() -> String? {
        let info = run("/usr/bin/codesign", ["-dv", "--verbose=2", Bundle.main.bundlePath])
        return teamIdentifier(fromCodesignOutput: info.output)
    }

    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let value = line.dropFirst("TeamIdentifier=".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value == "not set" || value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
