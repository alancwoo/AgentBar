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
    @StateObject private var listHeightModel = ServiceListHeightModel()
    @State private var isHoveringRefresh = false
    private let openExternalURL: (URL) -> Void
    private var displayUsageData: [UsageData] {
        Self.sortedForDisplay(viewModel.usageData)
    }

    init(
        viewModel: UsageViewModel,
        openExternalURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.viewModel = viewModel
        self.openExternalURL = openExternalURL
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

            Divider()
                .padding(.top, Self.sectionSpacing)
                .padding(.bottom, Self.footerSpacing)

            buildRow
        }
        .padding(Self.contentPadding)
        .frame(width: Self.popoverWidth)
    }

    /// Edge padding, the gap that separates the action row from the services
    /// (no rule there), and the gaps above and below the single footer rule.
    static let contentPadding: CGFloat = 14
    static let headerSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let footerSpacing: CGFloat = 8

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

    private var buildRow: some View {
        HStack(spacing: 6) {
            Text("AgentBar \(Self.versionString)")
            Spacer(minLength: 8)
            Button(action: openBMC) {
                Text("Buy me a Coffee")
                    .underline()
            }
            .buttonStyle(.plain)
            .help("Support AgentBar")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func actionButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        ActionIconButton(systemImage: systemImage, help: help, action: action)
    }

    /// Service rows grow with their content and only scroll once they would
    /// make the popover taller than `maxServiceListHeight`.
    private var serviceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(displayUsageData) { data in
                    ServiceDetailRow(data: data)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Wide enough for two "Resets in …" chips on one line.
    static let popoverWidth: CGFloat = 360
    /// Cap so a long service list can never push the popover off-screen.
    static let maxServiceListHeight: CGFloat = 400
    static let minServiceListHeight: CGFloat = 44
    static let serviceRowSpacing: CGFloat = 12
    /// Approximate rendered heights, used only for the first layout pass.
    static let serviceRowHeight: CGFloat = 38
    static let extraChipRowHeight: CGFloat = 16

    static func estimatedRowHeight(for data: UsageData) -> CGFloat {
        let chipRows = ServiceDetailRow.chipRows(for: data).count
        return serviceRowHeight + CGFloat(max(0, chipRows - 1)) * extraChipRowHeight
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

    private func openBMC() {
        openExternalURL(Self.bmcSupportURL)
    }

    private static let bmcSupportURL = URL(string: "https://buymeacoffee.com/_scari")!

    static func sortedForDisplay(_ usageData: [UsageData]) -> [UsageData] {
        let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai]
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

    #if DEBUG
    func triggerBMCForTesting() {
        openBMC()
    }
    #endif

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

    private static let versionString = resolvedVersionString(from: Bundle.main.infoDictionary)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(data.service.rawValue)
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
                if let planName = data.planName {
                    Text(planName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 10)
                MiniBarView(data: data)
                    .frame(height: MiniBarView.height(for: data))
                    .frame(minWidth: 90, maxWidth: .infinity)
            }

            // Legend: the dot colour maps each window to its bar track.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Self.chipRows(for: data).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(row) { chip in
                            MetricChip(
                                color: chip.color,
                                label: chip.label,
                                metric: chip.metric
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
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

    /// Two chips is all that fits on one popover-width line, so a third window
    /// wraps rather than being clipped.
    static let maxChipsPerRow = 2

    static func chipRows(for data: UsageData) -> [[Chip]] {
        let all = chips(for: data)
        guard all.count > maxChipsPerRow else { return [all] }
        return stride(from: 0, to: all.count, by: maxChipsPerRow).map {
            Array(all[$0..<min($0 + maxChipsPerRow, all.count)])
        }
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

/// One window of a service: colour key, name, usage and time left in its cycle.
struct MetricChip: View {
    let color: Color
    let label: String
    let metric: UsageMetric

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(Int(metric.percentage * 100))%")
                .monospacedDigit()
                .foregroundStyle(metric.percentage > 0.8 ? .red : .primary)
            if let remaining = Self.remainingText(for: metric) {
                Text(Self.resetText(remaining: remaining))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
        .help(Self.detailText(label: label, metric: metric))
    }

    static func resetText(remaining: String) -> String {
        "· Resets in \(remaining)"
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

struct MiniBarView: View {
    let data: UsageData

    static let trackHeight: CGFloat = 3
    static let trackSpacing: CGFloat = 1.5

    /// Height needed for one track per window this service reports.
    static func height(for data: UsageData) -> CGFloat {
        let tracks = CGFloat(windowCount(for: data))
        return tracks * trackHeight + max(0, tracks - 1) * trackSpacing
    }

    static func windowCount(for data: UsageData) -> Int {
        1 + (data.weeklyUsage == nil ? 0 : 1) + (data.monthlyUsage == nil ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: Self.trackSpacing) {
            track(ratio: data.fiveHourUsage.percentage, color: data.service.darkColor)
            if let weekly = data.weeklyUsage {
                track(ratio: weekly.percentage, color: data.service.lightColor)
            }
            if let monthly = data.monthlyUsage {
                track(ratio: monthly.percentage, color: data.service.monthColor)
            }
        }
    }

    private func track(ratio: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(Color.gray.opacity(0.2))
                if ratio > 0 {
                    RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * ratio))
                }
            }
        }
        .frame(height: Self.trackHeight)
    }
}
