import XCTest
@testable import AgentBar

final class ServiceStatusMonitorTests: XCTestCase {
    func testStatuspageStringsMapToHealth() {
        XCTAssertEqual(ServiceHealth(statuspageComponentStatus: "operational"), .operational)
        XCTAssertEqual(ServiceHealth(statuspageComponentStatus: "degraded_performance"), .degraded)
        XCTAssertEqual(ServiceHealth(statuspageComponentStatus: "partial_outage"), .partialOutage)
        XCTAssertEqual(ServiceHealth(statuspageComponentStatus: "MAJOR_OUTAGE"), .majorOutage)
        XCTAssertEqual(ServiceHealth(statuspageComponentStatus: "under_maintenance"), .maintenance)
        XCTAssertNil(ServiceHealth(statuspageComponentStatus: "something_new"))
    }

    func testHealthOrdersFromBestToWorst() {
        XCTAssertLessThan(ServiceHealth.operational, .degraded)
        XCTAssertLessThan(ServiceHealth.degraded, .partialOutage)
        XCTAssertLessThan(ServiceHealth.partialOutage, .majorOutage)
        XCTAssertEqual(ServiceHealth.operational.label, "OK")
        XCTAssertEqual(ServiceHealth.partialOutage.label, "Partial Outage")
    }

    func testWorstMatchingComponentWins() throws {
        // Captured from www.githubstatus.com during a real incident.
        let json = """
        {"components":[
          {"name":"Git Operations","status":"operational"},
          {"name":"Copilot","status":"operational"},
          {"name":"Copilot AI Model Providers","status":"degraded_performance"}
        ]}
        """
        let response = try JSONDecoder().decode(
            StatuspageComponentsResponse.self,
            from: Data(json.utf8)
        )
        let source = try XCTUnwrap(StatusPageRegistry.source(for: .copilot))

        XCTAssertEqual(
            response.health(for: source),
            .degraded,
            "Copilot depends on its model providers, so their degradation is Copilot's."
        )
    }

    func testExactMatchIgnoresUnrelatedComponents() throws {
        // Captured from status.claude.com during a real incident.
        let json = """
        {"components":[
          {"name":"claude.ai","status":"partial_outage"},
          {"name":"Claude Console (platform.claude.com)","status":"operational"},
          {"name":"Claude API (api.anthropic.com)","status":"partial_outage"},
          {"name":"Claude Code","status":"operational"}
        ]}
        """
        let response = try JSONDecoder().decode(
            StatuspageComponentsResponse.self,
            from: Data(json.utf8)
        )
        let source = try XCTUnwrap(StatusPageRegistry.source(for: .claude))

        XCTAssertEqual(
            response.health(for: source),
            .operational,
            "Only the Claude Code component should drive the Claude Code badge."
        )
    }

    func testNoMatchingComponentYieldsNoHealth() throws {
        let json = """
        {"components":[{"name":"Website","status":"operational"}]}
        """
        let response = try JSONDecoder().decode(
            StatuspageComponentsResponse.self,
            from: Data(json.utf8)
        )
        let source = try XCTUnwrap(StatusPageRegistry.source(for: .cursor))

        XCTAssertNil(response.health(for: source), "Better no badge than a made-up OK.")
    }

    func testServicesWithoutAStatusPageHaveNoSource() {
        XCTAssertNil(StatusPageRegistry.source(for: .gemini))
        XCTAssertNil(StatusPageRegistry.source(for: .zai))
        XCTAssertNil(StatusPageRegistry.source(for: .grok))
        XCTAssertNotNil(StatusPageRegistry.source(for: .claude))
        XCTAssertNotNil(StatusPageRegistry.source(for: .codex))
    }

    func testComponentsURLIsTheStatuspageV2Endpoint() throws {
        let source = try XCTUnwrap(StatusPageRegistry.source(for: .codex))
        XCTAssertEqual(
            source.componentsURL.absoluteString,
            "https://status.openai.com/api/v2/components.json"
        )
    }

    func testMonitorCachesEachPageWithinTTL() async throws {
        StatusMockURLProtocol.reset()
        let requestCount = RequestCounter()
        StatusMockURLProtocol.onRequest = { _ in requestCount.increment() }
        StatusMockURLProtocol.stubData = Data("""
        {"components":[{"name":"Claude Code","status":"partial_outage"}]}
        """.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusMockURLProtocol.self]
        let monitor = ServiceStatusMonitor(session: URLSession(configuration: config))

        let first = await monitor.health(for: [.claude])
        let second = await monitor.health(for: [.claude])

        XCTAssertEqual(first[.claude], .partialOutage)
        XCTAssertEqual(second[.claude], .partialOutage)
        XCTAssertEqual(
            requestCount.value,
            1,
            "A second poll inside the TTL must reuse the cached page."
        )
        StatusMockURLProtocol.reset()
    }

    @MainActor
    func testViewModelPublishesHealthAlongsideUsage() async {
        let provider = MockUsageProvider(
            serviceType: .claude,
            result: .success(UsageData.mock(service: .claude, fiveHourPct: 0.2))
        )
        let monitor = StubStatusMonitor(health: [.claude: .degraded])
        let vm = UsageViewModel(providers: [provider], statusMonitor: monitor)

        await vm.fetchAllUsage()

        XCTAssertEqual(vm.serviceHealth[.claude], .degraded)
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private struct StubStatusMonitor: ServiceStatusMonitoring {
    let health: [ServiceType: ServiceHealth]

    func health(for services: [ServiceType]) async -> [ServiceType: ServiceHealth] {
        health.filter { services.contains($0.key) }
    }
}

private final class StatusMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stubData: Data = Data()
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?

    static func reset() {
        stubData = Data()
        onRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StatusMockURLProtocol.onRequest?(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StatusMockURLProtocol.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
