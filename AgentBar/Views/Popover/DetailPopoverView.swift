import SwiftUI

/// Height of the service list content, reported from the list itself so the
/// popover can size itself to its contents instead of a fixed height.
private struct ServiceListContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
final class ServiceListHeightModel: ObservableObject {
    @Published var contentHeight: CGFloat = 0
}

struct DetailPopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject private var updates = AppUpdateController.shared
    @StateObject private var listHeightModel = ServiceListHeightModel()
    @State private var isHoveringRefresh = false
    private var displayUsageData: [UsageData] {
        Self.sortedForDisplay(viewModel.usageData)
    }

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow
                .padding(.bottom, Self.headerSpacing)

            if viewModel.usageData.isEmpty {
                Text("No usage data available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                serviceList
            }

        }
        .padding(Self.contentPadding)
        .frame(width: Self.popoverWidth)
    }

    /// Edge padding and the gap under the action row. The popover carries no
    /// rules — bands are separated by space alone.
    static let contentPadding: CGFloat = 14
    static let headerSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 12

    /// Status on the left, actions on the right.
    private var actionRow: some View {
        HStack(spacing: 10) {
                if let error = viewModel.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    refreshButton
                }

                Spacer(minLength: 8)

                actionButton(
                    systemImage: "chart.xyaxis.line",
                    help: "Insights",
                    action: openInsights
                )
                actionButton(
                    systemImage: "gearshape",
                    help: "Settings",
                    action: openSettings
                )
                actionButton(
                    systemImage: "power",
                    help: "Quit AgentBar",
                    action: quit
                )
        }
    }

    /// Doubles as the freshness indicator and a manual refresh trigger.
    private var refreshButton: some View {
        Button {
            Task { await viewModel.fetchAllUsage() }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text(Self.refreshLabel(
                        isLoading: viewModel.isLoading,
                        relativeTime: relativeTimeString(now: context.date)
                    ))
                }
            }
            .font(.caption)
            .foregroundStyle(isHoveringRefresh ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHoveringRefresh ? Color.primary.opacity(0.08) : Color.clear)
                    // Inflated rather than padded, so the chip cannot change
                    // the row's height or its gap to the rule above.
                    .padding(.horizontal, -5)
                    .padding(.vertical, -3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
        .onHover { hovering in
            isHoveringRefresh = hovering
        }
        .help("Refresh now")
    }

    static func refreshLabel(isLoading: Bool, relativeTime: String) -> String {
        isLoading ? "Refreshing…" : relativeTime
    }

    private func actionButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        ActionIconButton(systemImage: systemImage, help: help, action: action)
    }

    /// Service rows grow with their content. A scroll view only appears once the
    /// list would outgrow `maxServiceListHeight`, so the common case is a plain
    /// stack that sizes itself exactly.
    @ViewBuilder
    private var serviceList: some View {
        if Self.needsScrolling(for: displayUsageData) {
            scrollingServiceList
        } else {
            serviceRows
        }
    }

    private var serviceRows: some View {
        VStack(alignment: .leading, spacing: Self.serviceRowSpacing) {
            ForEach(displayUsageData) { data in
                ServiceDetailRow(data: data, health: viewModel.serviceHealth[data.service])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrollingServiceList: some View {
        ScrollView {
            serviceRows
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ServiceListContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .frame(maxWidth: .infinity)
        .frame(
            height: Self.serviceListHeight(
                forContentHeight: listHeightModel.contentHeight,
                estimate: Self.estimatedListHeight(for: displayUsageData)
            )
        )
        .onPreferenceChange(ServiceListContentHeightKey.self) { [listHeightModel] height in
            Task { @MainActor in
                guard listHeightModel.contentHeight != height else { return }
                listHeightModel.contentHeight = height
            }
        }
    }

    /// Decided from the row estimate, which is deterministic from the data.
    static func needsScrolling(for services: [UsageData]) -> Bool {
        estimatedListHeight(for: services) >= maxServiceListHeight
    }

    static let popoverWidth: CGFloat = 360
    /// Cap so a long service list can never push the popover off-screen. Sized
    /// to fit every supported provider at once now that each usage window takes
    /// its own line.
    static let maxServiceListHeight: CGFloat = 520
    static let minServiceListHeight: CGFloat = 44
    static let serviceRowSpacing: CGFloat = 12
    /// Approximate rendered heights, used only for the first layout pass.
    static let serviceHeaderHeight: CGFloat = 20
    static let windowRowHeight: CGFloat = 17

    static func estimatedRowHeight(for data: UsageData) -> CGFloat {
        let windows = CGFloat(ServiceDetailRow.chips(for: data).count)
        return serviceHeaderHeight + windows * windowRowHeight
    }

    /// Clamps the measured list height into the popover's allowed range.
    /// Until the first measurement arrives it uses `estimate`, so the popover
    /// opens at roughly its final height instead of snapping open.
    static func serviceListHeight(
        forContentHeight contentHeight: CGFloat,
        estimate: CGFloat = minServiceListHeight
    ) -> CGFloat {
        guard contentHeight > 0 else {
            return min(max(estimate, minServiceListHeight), maxServiceListHeight)
        }
        return min(max(contentHeight, minServiceListHeight), maxServiceListHeight)
    }

    /// Row-count based guess at the list height, before SwiftUI reports the real one.
    static func estimatedListHeight(for services: [UsageData]) -> CGFloat {
        guard !services.isEmpty else { return minServiceListHeight }
        let rows = services.reduce(CGFloat.zero) { $0 + estimatedRowHeight(for: $1) }
        let spacing = CGFloat(services.count - 1) * serviceRowSpacing
        return min(max(rows + spacing, minServiceListHeight), maxServiceListHeight)
    }

    private func openSettings() {
        PopoverController.shared.hide()
        SettingsWindowController.shared.show()
    }

    private func openInsights() {
        PopoverController.shared.hide()
        InsightsWindowController.shared.show()
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    static func sortedForDisplay(_ usageData: [UsageData]) -> [UsageData] {
        let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .grok, .opencode, .zai]
        return usageData.sorted { lhs, rhs in
            let lhsScore = max(lhs.fiveHourUsage.percentage, lhs.weeklyUsage?.percentage ?? 0)
            let rhsScore = max(rhs.fiveHourUsage.percentage, rhs.weeklyUsage?.percentage ?? 0)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            let lhsRank = serviceOrder.firstIndex(of: lhs.service) ?? serviceOrder.count
            let rhsRank = serviceOrder.firstIndex(of: rhs.service) ?? serviceOrder.count
            return lhsRank < rhsRank
        }
    }

    static func resolvedVersionString(from info: [String: Any]?) -> String {
        if let tag = normalizedString(info?["GitVersionTag"] as? String) {
            return tag
        }
        if let hash = normalizedString(info?["GitCommitHash"] as? String) {
            return hash
        }
        if let shortVersion = normalizedString(info?["CFBundleShortVersionString"] as? String) {
            return shortVersion
        }
        return "unknown"
    }

    private static func normalizedString(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    static let versionString = resolvedVersionString(from: Bundle.main.infoDictionary)

    private func relativeTimeString(now: Date = Date()) -> String {
        guard let latest = viewModel.usageData.map(\.lastUpdated).max() else {
            return "never"
        }
        let interval = now.timeIntervalSince(latest)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        return "\(Int(interval / 60))m ago"
    }
}

struct ServiceDetailRow: View {
    let data: UsageData
    var health: ServiceHealth? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(data.service.rawValue)
                    .font(.subheadline.weight(.medium))
                if let planName = data.planName {
                    Text(planName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let health {
                    ServiceHealthBadge(health: health, service: data.service)
                }
            }

            // One line per usage window, in fixed columns so every service
            // lines up down the popover.
            ForEach(Self.chips(for: data)) { chip in
                UsageWindowRow(chip: chip)
            }
        }
    }
}

extension ServiceDetailRow {
    struct Chip: Identifiable {
        let id: String
        let color: Color
        let label: String
        let metric: UsageMetric
    }

    static func chips(for data: UsageData) -> [Chip] {
        var result = [
            Chip(
                id: "primary",
                color: data.service.darkColor,
                label: data.service.fiveHourLabel,
                metric: data.fiveHourUsage
            )
        ]
        if let weekly = data.weeklyUsage {
            result.append(
                Chip(
                    id: "weekly",
                    color: data.service.lightColor,
                    label: data.service.weeklyLabel,
                    metric: weekly
                )
            )
        }
        if let monthly = data.monthlyUsage {
            result.append(
                Chip(
                    id: "monthly",
                    color: data.service.monthColor,
                    label: data.service.monthlyLabel,
                    metric: monthly
                )
            )
        }
        return result
    }
}

/// Footer icon that goes solid (full-contrast label colour — white on a dark
/// popover) while the pointer is over it.
struct ActionIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help)
    }
}

/// Bottom strip shown only when a newer release exists: one click downloads,
/// verifies, swaps the bundle and relaunches.
struct UpdateBanner: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(Self.text(for: controller.state))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch controller.state {
            case .available:
                Button("Install") { controller.install() }
                    .controlSize(.small)
            case .failed:
                Button("Retry") { controller.install() }
                    .controlSize(.small)
                Button("Open page") { controller.openReleasePage() }
                    .controlSize(.small)
            case .downloading, .installing:
                ProgressView()
                    .controlSize(.small)
            case .idle:
                EmptyView()
            }
        }
        .font(.caption)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    static func text(for state: AppUpdateState) -> String {
        switch state {
        case .idle: return ""
        case .available(let release): return "\(release.tag) is available"
        case .downloading(let release): return "Downloading \(release.tag)…"
        case .installing(let release): return "Installing \(release.tag), relaunching…"
        case .failed(_, let message): return "Update failed: \(message)"
        }
    }
}

/// Outcome of the last update check, for Settings → About. Shows nothing
/// until a check has run; offers Install right there when one is available.
struct UpdateStatusRow: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        if let text = Self.text(for: controller) {
            HStack(spacing: 8) {
                if controller.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if case .available = controller.state {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                switch controller.state {
                case .available:
                    Button("Install") { controller.install() }
                case .failed:
                    Button("Retry") { controller.install() }
                    Button("Open page") { controller.openReleasePage() }
                case .downloading, .installing:
                    ProgressView()
                        .controlSize(.small)
                case .idle:
                    EmptyView()
                }
            }
            .font(.callout)
        }
    }

    static func text(for controller: AppUpdateController) -> String? {
        if controller.isChecking { return "Checking…" }
        switch controller.state {
        case .available(let release): return "\(release.tag) is available"
        case .downloading(let release): return "Downloading \(release.tag)…"
        case .installing(let release): return "Installing \(release.tag), relaunching…"
        case .failed(_, let message): return "Update failed: \(message)"
        case .idle:
            guard let checked = controller.lastCheckedAt else { return nil }
            if controller.lastCheckFailed {
                return "Couldn't reach GitHub to check for updates."
            }
            return "You're up to date · checked \(Self.relative(checked))"
        }
    }

    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

/// Status-page health, right-aligned on the service header. Click to open the
/// page itself.
struct ServiceHealthBadge: View {
    let health: ServiceHealth
    let service: ServiceType

    var body: some View {
        Button {
            if let url = StatusPageRegistry.source(for: service)?.pageURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(health.label)
                .font(.caption2)
                .foregroundStyle(Self.color(for: health))
        }
        .buttonStyle(.plain)
        .help("\(service.rawValue) status: \(health.label). Click to open the status page.")
    }

    static func color(for health: ServiceHealth) -> Color {
        switch health {
        case .operational: return .green
        case .maintenance: return .blue
        case .degraded: return .yellow
        case .partialOutage: return .orange
        case .majorOutage: return .red
        }
    }
}

/// One usage window: colour key, label, percentage, its own bar, and the time
/// left in the cycle. Column widths are fixed so rows align across services.
struct UsageWindowRow: View {
    let chip: ServiceDetailRow.Chip

    static let dotSize: CGFloat = 6
    static let labelWidth: CGFloat = 24
    static let percentWidth: CGFloat = 32
    static let resetIconWidth: CGFloat = 12
    static let resetTimeWidth: CGFloat = 42
    static let barHeight: CGFloat = 6

    /// Total width of the reset column, kept even when a window has no reset
    /// time so the bars stay aligned.
    static var resetWidth: CGFloat { resetIconWidth + 3 + resetTimeWidth }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(chip.color)
                .frame(width: Self.dotSize, height: Self.dotSize)

            Text(chip.label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)

            Text("\(Int(chip.metric.percentage * 100))%")
                .monospacedDigit()
                .foregroundStyle(chip.metric.percentage > 0.8 ? .red : .primary)
                .frame(width: Self.percentWidth, alignment: .trailing)

            UsageTrackBar(ratio: chip.metric.percentage, color: chip.color)
                .frame(height: Self.barHeight)
                .frame(maxWidth: .infinity)

            resetColumn
        }
        .font(.caption2)
        .lineLimit(1)
        .help(Self.detailText(label: chip.label, metric: chip.metric))
    }

    /// Time left, right-aligned so the column reads as a table, then an
    /// hourglass that fills as the window runs down.
    @ViewBuilder
    private var resetColumn: some View {
        if let remaining = Self.remainingText(for: chip.metric) {
            HStack(spacing: 3) {
                Text(remaining)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.resetTimeWidth, alignment: .trailing)
                Image(systemName: Self.hourglassSymbol(
                    remaining: chip.metric.resetTime.map { $0.timeIntervalSinceNow } ?? 0,
                    windowLength: Self.windowLength(forLabel: chip.label)
                ))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: Self.resetIconWidth)
            }
            .help("Resets in \(remaining)")
        } else {
            Color.clear
                .frame(width: Self.resetWidth, height: 1)
        }
    }

    /// Nominal length of a window by its label, for the hourglass fill.
    static func windowLength(forLabel label: String) -> TimeInterval? {
        switch label {
        case "5h": return 5 * 3600
        case "1d": return 24 * 3600
        case "7d": return 7 * 24 * 3600
        case "Mo", "MCP": return 30 * 24 * 3600
        default: return nil
        }
    }

    /// Top-heavy early in the window, empty-topped late; plain when unknown.
    static func hourglassSymbol(remaining: TimeInterval, windowLength: TimeInterval?) -> String {
        guard let windowLength, windowLength > 0 else { return "hourglass" }
        let elapsedFraction = 1 - min(max(remaining / windowLength, 0), 1)
        if elapsedFraction < 1.0 / 3.0 { return "hourglass.tophalf.filled" }
        if elapsedFraction < 2.0 / 3.0 { return "hourglass" }
        return "hourglass.bottomhalf.filled"
    }

    /// Time until this window resets, or nil once it has passed.
    static func remainingText(for metric: UsageMetric) -> String? {
        guard let reset = metric.resetTime else { return nil }
        let remaining = reset.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return formatDuration(remaining)
    }

    /// Exact counts live in the tooltip so the row itself stays readable.
    static func detailText(label: String, metric: UsageMetric) -> String {
        switch metric.unit {
        case .percent:
            return "\(label): \(Int(metric.percentage * 100))% used"
        default:
            return "\(label): \(formatValue(metric.used, unit: metric.unit)) of \(formatValue(metric.total, unit: metric.unit))"
        }
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            let days = hours / 24
            let remainHours = hours % 24
            return "\(days)d\(remainHours)h"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    static func formatValue(_ value: Double, unit: UsageUnit) -> String {
        switch unit {
        case .dollars:
            return String(format: "$%.2f", value)
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.1fM", value / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "%.0fK", value / 1_000)
            }
            return String(format: "%.0f", value)
        case .requests:
            return String(format: "%.0f", value)
        case .percent:
            return String(format: "%.0f%%", value)
        }
    }
}

/// A single filled track.
struct UsageTrackBar: View {
    let ratio: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.2))
                if ratio > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * ratio))
                }
            }
        }
    }
}
