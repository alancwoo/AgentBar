#if AGENTBAR_NOTIFICATION_SOUNDS
import Foundation

actor CESPPackDownloadService {
    static let shared = CESPPackDownloadService()

    private static let packsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openpeon/packs")
    }()

    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    /// Registry-supplied names and manifest file paths are untrusted input.
    /// Only a single, plain path component is accepted as a pack directory name.
    static func sanitizedPackName(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafePathComponent(trimmed) else { return nil }
        return trimmed
    }

    /// Accepts only relative paths that stay inside the pack directory.
    /// Absolute paths, `~`, `.`/`..` components and empty segments are rejected.
    static func sanitizedRelativePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return nil
        }
        let components = trimmed.components(separatedBy: "/")
        guard components.allSatisfy({ isSafePathComponent($0) }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\\"),
              !component.contains("\0") else {
            return false
        }
        return true
    }

    func downloadPack(
        _ pack: CESPRegistryPack,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard let packName = Self.sanitizedPackName(pack.name) else {
            throw CESPRegistryError.downloadFailed("Unsafe pack name: \(pack.name)")
        }
        let packDir = Self.packsDirectory.appendingPathComponent(packName)

        // Download manifest
        let (manifestData, manifestResponse) = try await session.data(from: pack.manifestURL)
        guard let httpResponse = manifestResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw CESPRegistryError.downloadFailed("Failed to download manifest")
        }

        let manifest: CESPManifest
        do {
            manifest = try JSONDecoder().decode(CESPManifest.self, from: manifestData)
        } catch {
            throw CESPRegistryError.manifestParseFailed
        }

        // Collect all sound file paths
        var soundFiles: [String] = []
        if let categories = manifest.categories {
            for (_, category) in categories {
                soundFiles.append(contentsOf: category.sounds.map(\.file))
            }
        } else if let sounds = manifest.sounds {
            for (_, files) in sounds {
                soundFiles.append(contentsOf: files)
            }
        }

        // Create pack directory
        try fileManager.createDirectory(at: packDir, withIntermediateDirectories: true)

        // Write manifest
        try manifestData.write(to: packDir.appendingPathComponent("openpeon.json"))

        let totalFiles = soundFiles.count
        var completedFiles = 0

        // Download each sound file
        for soundFile in soundFiles {
            guard let relativePath = Self.sanitizedRelativePath(soundFile) else {
                try? fileManager.removeItem(at: packDir)
                throw CESPRegistryError.downloadFailed("Unsafe file path in manifest: \(soundFile)")
            }
            let fileURL = pack.baseContentURL.appendingPathComponent(relativePath)
            let localPath = packDir.appendingPathComponent(relativePath)

            // Create subdirectories if needed (e.g., sounds/)
            let parentDir = localPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            do {
                let (fileData, fileResponse) = try await session.data(from: fileURL)
                guard let httpResp = fileResponse as? HTTPURLResponse,
                      (200...299).contains(httpResp.statusCode) else {
                    throw CESPRegistryError.downloadFailed("Failed to download \(relativePath)")
                }
                try fileData.write(to: localPath)
            } catch {
                // Clean up partial download on failure
                try? fileManager.removeItem(at: packDir)
                throw CESPRegistryError.downloadFailed(relativePath)
            }

            completedFiles += 1
            if totalFiles > 0 {
                onProgress?(Double(completedFiles) / Double(totalFiles))
            }
        }

        // If no sound files but manifest downloaded, report complete
        if totalFiles == 0 {
            onProgress?(1.0)
        }

        return packDir.path
    }

    func isPackInstalled(_ name: String) -> Bool {
        let packDir = Self.packsDirectory.appendingPathComponent(name)
        let manifestPath = packDir.appendingPathComponent("openpeon.json").path
        return fileManager.fileExists(atPath: manifestPath)
    }

    func installedPackNames() -> [String] {
        let packsDir = Self.packsDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: packsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents.compactMap { url in
            let manifest = url.appendingPathComponent("openpeon.json")
            return fileManager.fileExists(atPath: manifest.path) ? url.lastPathComponent : nil
        }
    }

    func installedPackPath(_ name: String) -> String {
        Self.packsDirectory.appendingPathComponent(name).path
    }
}
#endif
