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
    @AppStorage(BuyMeACoffeeSettings.hideButtonKey) private var hideBuyMeACoffeeButton = false
    @StateObject private var listHeightModel = ServiceListHeightModel()
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
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("AgentBar")
                    .font(.headline)
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if viewModel.usageData.isEmpty {
                Text("No usage data available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                serviceList
            }

            if !hideBuyMeACoffeeButton {
                // Buy Me a Coffee
                Button(action: openBMC) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
            }

            // Footer
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let error = viewModel.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Last updated: \(relativeTimeString())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.versionString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: Self.popoverWidth)
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
        .frame(height: Self.serviceListHeight(forContentHeight: listHeightModel.contentHeight))
        .onPreferenceChange(ServiceListContentHeightKey.self) { [listHeightModel] height in
            Task { @MainActor in
                guard listHeightModel.contentHeight != height else { return }
                listHeightModel.contentHeight = height
            }
        }
    }

    static let popoverWidth: CGFloat = 320
    /// Cap so a long service list can never push the popover off-screen.
    static let maxServiceListHeight: CGFloat = 400
    static let minServiceListHeight: CGFloat = 44

    /// Clamps the measured list height into the popover's allowed range.
    /// Returns the minimum height before the first measurement arrives.
    static func serviceListHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return minServiceListHeight }
        return min(max(contentHeight, minServiceListHeight), maxServiceListHeight)
    }

    private func openSettings() {
        PopoverController.shared.hide()
        SettingsWindowController.shared.show()
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

    func isBMCButtonVisibleForTesting() -> Bool {
        !hideBuyMeACoffeeButton
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

    private func relativeTimeString() -> String {
        guard let latest = viewModel.usageData.map(\.lastUpdated).max() else {
            return "never"
        }
        let interval = Date().timeIntervalSince(latest)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        return "\(Int(interval / 60))m ago"
    }
}

struct ServiceDetailRow: View {
    let data: UsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(data.service.darkColor)
                    .frame(width: 8, height: 8)
                Text(data.service.rawValue)
                    .font(.subheadline.weight(.medium))
                if let planName = data.planName {
                    Text(planName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MiniBarView(data: data)
                    .frame(width: 60, height: 8)
            }

            MetricRow(label: data.service.fiveHourLabel, metric: data.fiveHourUsage)
            if let weekly = data.weeklyUsage {
                MetricRow(label: data.service.weeklyLabel, metric: weekly)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MetricRow: View {
    let label: String
    let metric: UsageMetric

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            if metric.unit == .percent {
                Text(formatValue(metric.used, unit: metric.unit))
                    .font(.caption.monospacedDigit())
            } else {
                Text(formatValue(metric.used, unit: metric.unit))
                    .font(.caption.monospacedDigit())
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatValue(metric.total, unit: metric.unit))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let reset = metric.resetTime {
                let remaining = reset.timeIntervalSinceNow
                if remaining > 0 {
                    Text(formatDuration(remaining))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(Int(metric.percentage * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(metric.percentage > 0.8 ? .red : .primary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            let days = hours / 24
            let remainHours = hours % 24
            return "\(days)d \(remainHours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatValue(_ value: Double, unit: UsageUnit) -> String {
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                if let weekly = data.weeklyUsage, weekly.percentage > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(data.service.lightColor)
                        .frame(width: geo.size.width * weekly.percentage)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(data.service.darkColor)
                    .frame(width: geo.size.width * data.fiveHourUsage.percentage)
            }
        }
    }
}
