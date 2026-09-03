import Foundation

/// A published GitHub release that ships a DMG.
struct AppRelease: Sendable, Equatable {
    let tag: String
    let version: AppVersion
    let pageURL: URL
    let dmgURL: URL
    let publishedAt: Date?
}

/// Numeric part of a tag such as `v0.7-fork` or `v1.2.3`, compared component-wise.
/// A bare number with neither a `v` prefix nor a dot is not a version — that
/// keeps commit hashes like `1307d6c` from ever being read as one.
struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    let components: [Int]

    init?(tag: String) {
        var rest = Substring(tag)
        let hasPrefix = rest.first == "v" || rest.first == "V"
        if hasPrefix { rest = rest.dropFirst() }

        let numeric = rest.prefix { $0.isNumber || $0 == "." }
        guard let first = numeric.first, first.isNumber else { return nil }
        guard hasPrefix || numeric.contains(".") else { return nil }

        let parsed = numeric.split(separator: ".").compactMap { Int($0) }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Consistent with `<`: trailing zeros do not distinguish versions.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

struct GitHubReleaseResponse: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
    }

    let tag_name: String
    let html_url: URL
    let published_at: String?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [Asset]

    func release() -> AppRelease? {
        guard draft != true, prerelease != true,
              let version = AppVersion(tag: tag_name),
              let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            return nil
        }
        return AppRelease(
            tag: tag_name,
            version: version,
            pageURL: html_url,
            dmgURL: dmg.browser_download_url,
            publishedAt: published_at.flatMap { DateUtils.parseISO8601($0) }
        )
    }
}

protocol AppUpdateChecking: Sendable {
    func latestRelease() async throws -> AppRelease?
}

/// Asks GitHub for the newest published release of this fork.
struct AppUpdateChecker: AppUpdateChecking {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/alancwoo/AgentBar/releases/latest"
    )!

    private let session: URLSession
    private let url: URL

    init(session: URLSession = .shared, url: URL = AppUpdateChecker.latestReleaseURL) {
        self.session = session
        self.url = url
    }

    func latestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubReleaseResponse.self, from: data).release()
    }

    /// True when `release` is newer than the running build. A build with no
    /// tag (a local Debug build) never reports an update.
    static func isNewer(_ release: AppRelease, than currentTag: String?) -> Bool {
        guard let currentTag, let current = AppVersion(tag: currentTag) else { return false }
        return current < release.version
    }
}
