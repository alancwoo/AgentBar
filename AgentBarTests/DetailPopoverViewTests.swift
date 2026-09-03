import XCTest
import AppKit
import SwiftUI
@testable import AgentBar

@MainActor
final class DetailPopoverViewTests: XCTestCase {

    func testDetailPopoverScrollsWhenUsageRowsOverflow() {
        let viewModel = UsageViewModel(providers: [])
        viewModel.usageData = makeUsageRows(count: 36)

        let rendered = renderPopover(viewModel: viewModel)
        let scrollView = waitForScrollViewLayout(in: rendered.hostingView)

        XCTAssertNotNil(scrollView, "Expected a scroll view when usage data is present.")
        guard let scrollView else { return }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let viewportWidth = scrollView.contentView.bounds.width
        let documentWidth = scrollView.documentView?.bounds.width ?? 0

        XCTAssertGreaterThan(
            documentHeight,
            viewportHeight,
            "Expected overflow rows to exceed the viewport so content is scrollable."
        )
        XCTAssertGreaterThan(viewportWidth, 0, "Expected a non-zero scroll viewport width.")
        XCTAssertEqual(
            documentWidth,
            viewportWidth,
            accuracy: 2.0,
            "Expected usage rows to expand to the full scroll viewport width."
        )

        withExtendedLifetime(rendered.window) {}
    }

    func testDetailPopoverCapsScrollRegionSoFooterChromeAlwaysFits() {
        let viewModel = UsageViewModel(providers: [])
        viewModel.usageData = makeUsageRows(count: 36)

        let rendered = renderPopover(viewModel: viewModel)
        let scrollView = waitForScrollViewLayout(in: rendered.hostingView)

        XCTAssertNotNil(scrollView, "Expected a scroll view when usage data is present.")
        guard let scrollView else { return }

        XCTAssertGreaterThan(scrollView.contentView.bounds.height, 0)
        XCTAssertLessThanOrEqual(
            scrollView.contentView.bounds.height,
            DetailPopoverView.maxServiceListHeight + 1,
            "The list must stay capped so header/footer chrome always has room."
        )

        withExtendedLifetime(rendered.window) {}
    }

    func testEstimatedListHeightScalesWithRowCount() {
        let single = DetailPopoverView.estimatedListHeight(for: [
            UsageData.mock(service: .claude, fiveHourPct: 0.1, weeklyPct: 0.1)
        ])
        XCTAssertEqual(
            single,
            max(
                DetailPopoverView.serviceHeaderHeight + DetailPopoverView.windowRowHeight * 2,
                DetailPopoverView.minServiceListHeight
            ),
            "A lone row is still floored at the minimum list height."
        )

        let two = DetailPopoverView.estimatedListHeight(for: [
            UsageData.mock(service: .claude, fiveHourPct: 0.1, weeklyPct: 0.1),
            UsageData.mock(service: .codex, fiveHourPct: 0.1, weeklyPct: 0.1)
        ])
        let expectedRow = DetailPopoverView.serviceHeaderHeight
            + DetailPopoverView.windowRowHeight * 2
        XCTAssertEqual(two, expectedRow * 2 + DetailPopoverView.serviceRowSpacing)

        let withMonth = UsageData(
            service: .claude,
            fiveHourUsage: UsageMetric(used: 1, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: UsageMetric(used: 1, total: 100, unit: .percent, resetTime: nil),
            monthlyUsage: UsageMetric(used: 1, total: 100, unit: .percent, resetTime: nil),
            lastUpdated: Date(),
            isAvailable: true
        )
        XCTAssertEqual(
            DetailPopoverView.estimatedRowHeight(for: withMonth),
            DetailPopoverView.serviceHeaderHeight + DetailPopoverView.windowRowHeight * 3,
            "Each window adds a line, so a three-window service is taller."
        )

        XCTAssertEqual(
            DetailPopoverView.estimatedListHeight(for: makeUsageRows(count: 36)),
            DetailPopoverView.maxServiceListHeight,
            "The estimate is clamped by the same cap as the measured height."
        )
        XCTAssertEqual(
            DetailPopoverView.estimatedListHeight(for: []),
            DetailPopoverView.minServiceListHeight
        )
    }

    func testServiceListUsesEstimateUntilMeasured() {
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: 0, estimate: 210),
            210,
            "Before measurement the popover should open at its estimated height."
        )
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: 180, estimate: 210),
            180,
            "The measured height wins once it arrives."
        )
    }

    func testBuyMeACoffeeActionOpensExpectedURL() {
        let viewModel = UsageViewModel(providers: [])
        var openedURLs: [URL] = []

        let view = DetailPopoverView(viewModel: viewModel) { url in
            openedURLs.append(url)
        }
        view.triggerBMCForTesting()

        XCTAssertEqual(
            openedURLs.first?.absoluteString,
            "https://buymeacoffee.com/_scari",
            "Expected tapping Buy Me a Coffee to attempt opening the BMC support URL."
        )
    }

    func testSortedForDisplayOrdersByHighestUsageDescending() {
        let input = [
            UsageData.mock(service: .claude, fiveHourPct: 0.20, weeklyPct: 0.40),
            UsageData.mock(service: .codex, fiveHourPct: 0.90, weeklyPct: 0.10),
            UsageData.mock(service: .gemini, fiveHourPct: 0.50, weeklyPct: 0.60)
        ]

        let sorted = DetailPopoverView.sortedForDisplay(input)

        XCTAssertEqual(sorted.map(\.service), [.codex, .gemini, .claude])
    }

    func testSortedForDisplayUsesServiceOrderAsTieBreaker() {
        let input = [
            UsageData.mock(service: .zai, fiveHourPct: 0.50, weeklyPct: 0.50),
            UsageData.mock(service: .codex, fiveHourPct: 0.50, weeklyPct: 0.50),
            UsageData.mock(service: .claude, fiveHourPct: 0.50, weeklyPct: 0.50)
        ]

        let sorted = DetailPopoverView.sortedForDisplay(input)

        XCTAssertEqual(sorted.map(\.service), [.claude, .codex, .zai])
    }

    func testSortedForDisplayKeepsUnavailableRows() {
        let unavailable = UsageData(
            service: .claude,
            fiveHourUsage: UsageMetric(used: 1, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: false
        )
        let available = UsageData.mock(service: .codex, fiveHourPct: 0.30, weeklyPct: 0.30)

        let sorted = DetailPopoverView.sortedForDisplay([unavailable, available])

        XCTAssertEqual(sorted.count, 2)
        XCTAssertTrue(sorted.contains { $0.service == .claude && !$0.isAvailable })
    }

    func testResolvedVersionStringPrefersTagOverCommitHash() {
        let version = DetailPopoverView.resolvedVersionString(from: [
            "GitVersionTag": "v1.2.3",
            "GitCommitHash": "abc1234",
            "CFBundleShortVersionString": "1.0"
        ])

        XCTAssertEqual(version, "v1.2.3")
    }

    func testResolvedVersionStringUsesCommitHashWithoutTag() {
        let version = DetailPopoverView.resolvedVersionString(from: [
            "GitVersionTag": "   ",
            "GitCommitHash": "abc1234",
            "CFBundleShortVersionString": "1.0"
        ])

        XCTAssertEqual(version, "abc1234")
    }

    func testResolvedVersionStringFallsBackToBundleVersionWhenTagAndHashMissing() {
        let version = DetailPopoverView.resolvedVersionString(from: [
            "CFBundleShortVersionString": "1.0"
        ])

        XCTAssertEqual(version, "1.0")
    }

    func testResolvedVersionStringReturnsUnknownWhenAllValuesMissing() {
        XCTAssertEqual(DetailPopoverView.resolvedVersionString(from: nil), "unknown")
        XCTAssertEqual(DetailPopoverView.resolvedVersionString(from: [:]), "unknown")
    }

    func testServiceListHeightMatchesContentWhenItFits() {
        let contentHeight: CGFloat = 120
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: contentHeight),
            contentHeight,
            "A short service list should size the popover to its own content."
        )
    }

    func testServiceListHeightIsCappedForLongLists() {
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: 5_000),
            DetailPopoverView.maxServiceListHeight,
            "A long service list should scroll instead of growing the popover without bound."
        )
    }

    func testServiceListHeightUsesMinimumBeforeMeasurement() {
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: 0),
            DetailPopoverView.minServiceListHeight
        )
        XCTAssertEqual(
            DetailPopoverView.serviceListHeight(forContentHeight: 4),
            DetailPopoverView.minServiceListHeight
        )
    }

    func testChipsCoverEveryReportedWindowInBarOrder() {
        let data = UsageData(
            service: .claude,
            fiveHourUsage: UsageMetric(used: 10, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: UsageMetric(used: 20, total: 100, unit: .percent, resetTime: nil),
            monthlyUsage: UsageMetric(used: 30, total: 100, unit: .percent, resetTime: nil),
            lastUpdated: Date(),
            isAvailable: true
        )

        let chips = ServiceDetailRow.chips(for: data)
        XCTAssertEqual(chips.map(\.label), ["5h", "7d", "Mo"])
        XCTAssertEqual(chips.map(\.id), ["primary", "weekly", "monthly"])
    }

    func testChipsOmitWindowsTheServiceDoesNotReport() {
        let data = UsageData(
            service: .cursor,
            fiveHourUsage: UsageMetric(used: 10, total: 100, unit: .requests, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true
        )

        XCTAssertEqual(ServiceDetailRow.chips(for: data).count, 1)
    }

    func testWindowRowKeepsTheResetColumnWhenThereIsNoResetTime() {
        let noReset = UsageMetric(used: 1, total: 10, unit: .requests, resetTime: nil)
        XCTAssertEqual(
            UsageWindowRow.resetText(for: noReset),
            "",
            "An empty string keeps the column width so bars stay aligned."
        )

        // Exact durations are covered by the formatDuration tests; asserting a
        // literal here races the clock as the countdown ticks down.
        let future = UsageMetric(
            used: 1, total: 10, unit: .requests,
            resetTime: Date().addingTimeInterval(6540)
        )
        XCTAssertTrue(UsageWindowRow.resetText(for: future).hasPrefix("Resets in 1h4"))
    }

    func testMetricChipHidesElapsedTimersAndFormatsCompactly() {
        let expired = UsageMetric(
            used: 1, total: 10, unit: .requests,
            resetTime: Date().addingTimeInterval(-60)
        )
        XCTAssertNil(
            UsageWindowRow.remainingText(for: expired),
            "A reset time in the past should not render a countdown."
        )
        XCTAssertNil(
            UsageWindowRow.remainingText(
                for: UsageMetric(used: 1, total: 10, unit: .requests, resetTime: nil)
            )
        )

        XCTAssertEqual(UsageWindowRow.formatDuration(49 * 60), "49m")
        XCTAssertEqual(UsageWindowRow.formatDuration(6540), "1h49m")
        XCTAssertEqual(UsageWindowRow.formatDuration(285_000), "3d7h")
    }

    func testMetricChipTooltipCarriesExactCounts() {
        let tokens = UsageMetric(used: 4_200_000, total: 10_000_000, unit: .tokens, resetTime: nil)
        XCTAssertEqual(UsageWindowRow.detailText(label: "5h", metric: tokens), "5h: 4.2M of 10.0M")

        let percent = UsageMetric(used: 28, total: 100, unit: .percent, resetTime: nil)
        XCTAssertEqual(UsageWindowRow.detailText(label: "7d", metric: percent), "7d: 28% used")
    }

    func testRefreshLabelSwitchesToProgressWhileFetching() {
        XCTAssertEqual(
            DetailPopoverView.refreshLabel(isLoading: true, relativeTime: "52s ago"),
            "Refreshing…"
        )
        XCTAssertEqual(
            DetailPopoverView.refreshLabel(isLoading: false, relativeTime: "52s ago"),
            "52s ago"
        )
    }

    func testHeaderRowIsSeparatedBySpaceNotARule() {
        XCTAssertGreaterThanOrEqual(
            DetailPopoverView.headerSpacing,
            DetailPopoverView.sectionSpacing,
            "The action row has no rule under it, so it needs at least the section gap."
        )
    }

    func testFooterRulesUseSmallerGapThanTheMainRule() {
        XCTAssertLessThan(
            DetailPopoverView.footerSpacing,
            DetailPopoverView.sectionSpacing,
            "The smaller footer text should sit in a tighter band."
        )
        XCTAssertGreaterThan(DetailPopoverView.footerSpacing, 0)
        XCTAssertEqual(
            DetailPopoverView.contentPadding,
            14,
            "Edge padding is shared by all four sides so the first row is inset like the last."
        )
    }

    func testScrollViewOnlyAppearsWhenTheListWouldOverflow() {
        let sixServices = ServiceType.allCases.prefix(6).map {
            UsageData.mock(service: $0, fiveHourPct: 0.2, weeklyPct: 0.3)
        }
        XCTAssertFalse(
            DetailPopoverView.needsScrolling(for: Array(sixServices)),
            "Every supported provider still fits without scrolling."
        )
        XCTAssertTrue(DetailPopoverView.needsScrolling(for: makeUsageRows(count: 36)))
        XCTAssertFalse(DetailPopoverView.needsScrolling(for: []))
    }

    func testEveryProviderAtOnceFitsWithoutScrollingOrOversizing() {
        let services = ServiceType.allCases.map { service -> UsageData in
            UsageData.mock(service: service, fiveHourPct: 0.4, weeklyPct: 0.5)
        }

        XCTAssertEqual(services.count, 8, "All supported providers are covered.")
        XCTAssertFalse(
            DetailPopoverView.needsScrolling(for: services),
            "Showing every provider at once should not need a scroll view."
        )

        let listHeight = DetailPopoverView.estimatedListHeight(for: services)
        XCTAssertLessThan(
            listHeight,
            DetailPopoverView.maxServiceListHeight,
            "Eight providers must stay under the cap that forces scrolling."
        )

        // Chrome: edge padding twice, the action row, its gap, and the build line.
        let chrome = DetailPopoverView.contentPadding * 2
            + DetailPopoverView.headerSpacing
            + DetailPopoverView.sectionSpacing
        XCTAssertLessThan(
            listHeight + chrome,
            620,
            "The whole popover should stay comfortably on screen with every provider enabled."
        )
    }

    func testWindowRowColumnsAreFixedSoServicesAlign() {
        // Every column except the bar is a fixed width; the bar takes the rest,
        // which is what keeps rows lined up between services.
        let fixed = UsageWindowRow.dotSize
            + UsageWindowRow.labelWidth
            + UsageWindowRow.percentWidth
            + UsageWindowRow.resetWidth
        let available = DetailPopoverView.popoverWidth - DetailPopoverView.contentPadding * 2

        XCTAssertLessThan(
            fixed,
            available,
            "Fixed columns must leave room for the usage bar."
        )
        XCTAssertGreaterThan(
            available - fixed,
            60,
            "The bar needs enough width to read as a proportion."
        )
    }

    private func makeUsageRows(count: Int) -> [UsageData] {
        let services = ServiceType.allCases
        return (0..<count).map { index in
            UsageData.mock(service: services[index % services.count])
        }
    }

    private func renderPopover(
        viewModel: UsageViewModel,
        openExternalURL: @escaping (URL) -> Void = { _ in }
    ) -> (window: NSWindow, hostingView: NSHostingView<DetailPopoverView>) {
        let rootView = DetailPopoverView(viewModel: viewModel, openExternalURL: openExternalURL)
        let hostingView = NSHostingView(rootView: rootView)
        let frame = NSRect(x: 0, y: 0, width: DetailPopoverView.popoverWidth, height: 700)
        hostingView.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        return (window, hostingView)
    }

    private func waitForScrollViewLayout(
        in hostingView: NSView,
        timeout: TimeInterval = 1.0
    ) -> NSScrollView? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousSizes: (viewport: CGSize, document: CGSize)?

        while Date() < deadline {
            hostingView.layoutSubtreeIfNeeded()

            if let scrollView = findFirstScrollView(in: hostingView),
               let documentView = scrollView.documentView {
                let viewportSize = scrollView.contentView.bounds.size
                let documentSize = documentView.bounds.size

                if viewportSize.width > 0, viewportSize.height > 0,
                   documentSize.width > 0, documentSize.height > 0 {
                    if let previousSizes,
                       abs(previousSizes.viewport.width - viewportSize.width) < 0.5,
                       abs(previousSizes.viewport.height - viewportSize.height) < 0.5,
                       abs(previousSizes.document.width - documentSize.width) < 0.5,
                       abs(previousSizes.document.height - documentSize.height) < 0.5 {
                        return scrollView
                    }
                    previousSizes = (viewportSize, documentSize)
                }
            }

            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTFail("Timed out waiting for scroll view layout to stabilize with non-zero dimensions.")
        return nil
    }

    private func findFirstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for child in view.subviews {
            if let match = findFirstScrollView(in: child) {
                return match
            }
        }
        return nil
    }


}
