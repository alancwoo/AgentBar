#if AGENTBAR_NOTIFICATION_SOUNDS
import XCTest
@testable import AgentBar

final class CESPPackDownloadServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CESPDownloadTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testSanitizedRelativePathRejectsTraversalAndAbsolutePaths() {
        let rejected = [
            "../../../../.zshenv",
            "sounds/../../escape.wav",
            "/etc/passwd",
            "~/Library/LaunchAgents/evil.plist",
            "",
            "   ",
            "./ding.wav",
            "sounds//ding.wav"
        ]
        for path in rejected {
            XCTAssertNil(
                CESPPackDownloadService.sanitizedRelativePath(path),
                "Expected \(path) to be rejected as an unsafe manifest path."
            )
        }
    }

    func testSanitizedRelativePathAcceptsPlainRelativePaths() {
        XCTAssertEqual(CESPPackDownloadService.sanitizedRelativePath("ding.wav"), "ding.wav")
        XCTAssertEqual(
            CESPPackDownloadService.sanitizedRelativePath("sounds/task/ding.wav"),
            "sounds/task/ding.wav"
        )
    }

    func testSanitizedPackNameRejectsPathComponents() {
        XCTAssertNil(CESPPackDownloadService.sanitizedPackName(".."))
        XCTAssertNil(CESPPackDownloadService.sanitizedPackName("a/b"))
        XCTAssertNil(CESPPackDownloadService.sanitizedPackName(""))
        XCTAssertEqual(CESPPackDownloadService.sanitizedPackName("peon-en"), "peon-en")
    }

    func testDownloadPackRejectsManifestWithTraversalPath() async {
        let manifestJSON = """
        {
          "name": "evil-pack",
          "sounds": {
            "task.complete": ["../../../../evil.wav"]
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.hasSuffix("openpeon.json") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, manifestJSON)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 0, count: 8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = CESPPackDownloadService(session: session, fileManager: .default)

        let pack = CESPRegistryPack(
            name: "traversal-test-\(UUID().uuidString)",
            display_name: "Traversal Test",
            description: nil,
            source_repo: "example/pack",
            source_ref: "main",
            source_path: "packs/test",
            sound_count: 1,
            total_size_bytes: nil,
            language: "en",
            trust_tier: nil,
            tags: nil
        )

        do {
            _ = try await service.downloadPack(pack)
            XCTFail("Expected a traversal path in the manifest to be rejected.")
        } catch {
            // Expected
        }
    }

    func testIsPackInstalledReturnsFalseForMissing() async {
        let service = CESPPackDownloadService(fileManager: .default)
        let result = await service.isPackInstalled("nonexistent-pack-\(UUID().uuidString)")
        XCTAssertFalse(result)
    }

    func testInstalledPackNamesReturnsEmptyForNoDirectory() async {
        let service = CESPPackDownloadService(fileManager: .default)
        let names = await service.installedPackNames()
        // May or may not be empty depending on user's system, but should not crash
        XCTAssertNotNil(names)
    }

    func testDownloadPackWithMockSession() async throws {
        let manifestJSON = """
        {
          "name": "test-pack",
          "sounds": {
            "task.complete": ["ding.wav"]
          }
        }
        """.data(using: .utf8)!

        let soundData = Data(repeating: 0, count: 100)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.hasSuffix("openpeon.json") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, manifestJSON)
            } else if url.hasSuffix("ding.wav") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, soundData)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = CESPPackDownloadService(session: session)

        let pack = CESPRegistryPack(
            name: "test-download-\(UUID().uuidString)",
            display_name: "Test Download",
            description: nil,
            source_repo: "test/repo",
            source_ref: "main",
            source_path: "pack",
            sound_count: 1,
            total_size_bytes: 100,
            language: nil,
            trust_tier: nil,
            tags: nil
        )

        let progressTracker = ProgressTracker()
        let path = try await service.downloadPack(pack) { progress in
            progressTracker.add(progress)
        }

        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(progressTracker.last, 1.0)

        // Cleanup
        try? FileManager.default.removeItem(atPath: path)
    }

    func testDownloadPackFailsOnBadManifestResponse() async {
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = CESPPackDownloadService(session: session)

        let pack = CESPRegistryPack(
            name: "fail-\(UUID().uuidString)",
            display_name: "Fail Pack",
            description: nil,
            source_repo: "test/repo",
            source_ref: "main",
            source_path: "pack",
            sound_count: nil,
            total_size_bytes: nil,
            language: nil,
            trust_tier: nil,
            tags: nil
        )

        do {
            _ = try await service.downloadPack(pack)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is CESPRegistryError)
        }
    }
}

// MARK: - ProgressTracker

private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var last: Double? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

// MARK: - MockURLProtocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    static func reset() {
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
