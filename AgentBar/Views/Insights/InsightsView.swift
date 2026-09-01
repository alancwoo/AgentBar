import SwiftUI

struct InsightsView: View {
    @StateObject private var viewModel: UsageHistoryViewModel
    @State private var isShowingCycleHelp = false
    private let heatmapTileSize: CGFloat = 12
    private let heatmapTileSpacing: CGFloat = 3
    private let heatmapRows = 7

    private var heatmapGridHeight: CGFloat {
        let rows = CGFloat(heatmapRows)
        return (rows * heatmapTileSize) + ((rows - 1) * heatmapTileSpacing)
    }

    init(viewModel: UsageHistoryViewModel = UsageHistoryViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlsSection

                if viewModel.servicePanels.isEmpty {
                    Text("No usage recorded yet. Keep AgentBar running and this fills in as your agents are used.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    legend

                    ForEach(viewModel.servicePanels) { panel in
                        servicePanelSection(panel)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            Task { await viewModel.refresh() }
        }
    }

    static let chartExplanation = "Left: one tile per day, shaded by that day's peak usage. Right: the same daily peaks as a line. Consistency tiles are one per completed reset cycle."

    static func helpText(for window: UsageHistoryWindow) -> String {
        "\(windowExplanation(for: window))\n\n\(chartExplanation)"
    }

    /// The two windows are named differently per service (5h/1d/monthly vs
    /// 7d/MCP), so the picker names the cycle length rather than the raw
    /// "primary"/"secondary" field names.
    static func windowExplanation(for window: UsageHistoryWindow) -> String {
        switch window {
        case .primary:
            return "Short cycle: the rate limit that refills fastest — 5h for Claude Code, Codex and Z.ai, 1 day for Gemini, monthly for Copilot and Cursor."
        case .secondary:
            return "Long cycle: the slower rolling limit — 7d for Claude Code and Codex, monthly MCP for Z.ai. Services without one fall back to their short cycle."
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.selectedWindow) {
                Text("Short cycle").tag(UsageHistoryWindow.primary)
                Text("Long cycle").tag(UsageHistoryWindow.secondary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            // `.help` alone does not reliably register a tooltip on a bare
            // Image, so the explanation is a hover popover instead.
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isShowingCycleHelp = hovering
                }
                .popover(isPresented: $isShowingCycleHelp, arrowEdge: .bottom) {
                    Text(Self.helpText(for: viewModel.selectedWindow))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 320, alignment: .leading)
                        .padding(12)
                }
                .help(Self.helpText(for: viewModel.selectedWindow))

            Spacer()

            Text("Last 12 weeks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func servicePanelSection(_ panel: UsageHistoryServicePanel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(panel.service.darkColor)
                    .frame(width: 8, height: 8)
                Text(panel.service.rawValue)
                    .font(.headline)
                Text(panelWindowTitle(panel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            chartsSection(panel)
            dailySummarySection(panel)

            if panel.isSevenDayCycleAvailable {
                cycleConsistencySection(panel)
            }

            Divider()
        }
    }

    /// Both charts start with a title on the same line and share one height,
    /// so the two columns read as a single row.
    private func chartsSection(_ panel: UsageHistoryServicePanel) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                chartTitle("Daily usage")
                heatmapSection(panel)
            }

            VStack(alignment: .leading, spacing: 4) {
                chartTitle("Daily peak usage")
                trendChartSection(panel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chartTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(height: 12, alignment: .leading)
    }

    private func heatmapSection(_ panel: UsageHistoryServicePanel) -> some View {
        let groups = groupedHeatmapCells(panel.heatmapCells)
        return HStack(alignment: .top, spacing: 6) {
            weekdayAxis

            HStack(alignment: .top, spacing: heatmapTileSpacing) {
                ForEach(groups.indices, id: \.self) { weekIndex in
                    VStack(spacing: heatmapTileSpacing) {
                        ForEach(groups[weekIndex]) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tileColor(level: cell.level, service: panel.service))
                                .frame(width: heatmapTileSize, height: heatmapTileSize)
                                .help(dayTooltip(for: cell))
                        }
                    }
                }
            }
        }
    }

    private func cycleConsistencySection(_ panel: UsageHistoryServicePanel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cycle consistency")
                .font(.subheadline.weight(.semibold))

            if panel.cycleCells.isEmpty {
                Text("Not enough completed cycles yet.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(panel.cycleCells) { cell in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(tileColor(level: cell.level, service: panel.service))
                            .frame(width: 16, height: 16)
                            .help(cycleTooltip(for: cell))
                    }
                }

                cycleSummarySection(panel.cycleSummary)
            }
        }
    }

    private func trendChartSection(_ panel: UsageHistoryServicePanel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            UsageTrendLineChartView(
                points: panel.trendPoints,
                service: panel.service
            )
            .frame(maxWidth: .infinity)
            .frame(height: heatmapGridHeight)

            HStack(spacing: 6) {
                Text(panel.trendPoints.first.map { dateString($0.date) } ?? "-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(panel.trendPoints.last.map { dateString($0.date) } ?? "-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let latestValue = panel.trendPoints.last?.value {
                Text("Latest: \(formatUsageValue(latestValue, unit: panel.trendUnit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailySummarySection(_ panel: UsageHistoryServicePanel) -> some View {
        HStack(spacing: 14) {
            summaryItem(title: "Active Days", value: "\(panel.usageFrequencyDays)")
            summaryItem(title: "Limit Hit Days", value: "\(panel.dailySummary.limitHitDays)")
            summaryItem(title: "Near Limit Days", value: "\(panel.dailySummary.nearLimitDays)")
            summaryItem(
                title: "Avg Daily Peak",
                value: percentString(panel.dailySummary.averageDailyPeakRatio)
            )
            summaryItem(
                title: "Last Hit Date",
                value: panel.dailySummary.lastHitDate.map(dateString) ?? "-"
            )
        }
    }

    private func cycleSummarySection(_ summary: UsageHistoryCycleSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                summaryItem(
                    title: "Cycle Completion Rate",
                    value: percentString(summary.completionRate)
                )
                summaryItem(
                    title: "Completed Cycles",
                    value: "\(summary.completedCycles) / \(summary.totalClosedCycles)"
                )
                summaryItem(
                    title: "Avg Days to 80%",
                    value: summary.averageDaysTo80.map { formatOneDecimal($0) } ?? "-"
                )
            }

            HStack(spacing: 14) {
                summaryItem(
                    title: "Avg Days to 100%",
                    value: summary.averageDaysTo100.map { formatOneDecimal($0) } ?? "-"
                )
                summaryItem(
                    title: "Current Completion Streak",
                    value: "\(summary.currentCompletionStreak)"
                )
                summaryItem(
                    title: "Avg High-Band Hours",
                    value: formatOneDecimal(summary.averageHighBandHours)
                )
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(tileColor(level: level, service: viewModel.servicePanels.first?.service))
                    .frame(width: 12, height: 12)
            }

            Text("More")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Sunday-first initials, matching the calendar the view model builds the
    /// grid with. Every row is labelled, and each label is exactly one tile tall
    /// so it lines up with the squares beside it.
    static let weekdayInitials = ["S", "M", "T", "W", "T", "F", "S"]

    private var weekdayAxis: some View {
        VStack(spacing: heatmapTileSpacing) {
            ForEach(Array(Self.weekdayInitials.enumerated()), id: \.offset) { _, initial in
                Text(initial)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: heatmapTileSize, alignment: .center)
            }
        }
    }

    private func panelWindowTitle(_ panel: UsageHistoryServicePanel) -> String {
        switch panel.displayWindow {
        case .primary:
            if viewModel.selectedWindow == .secondary && !panel.isSecondaryAvailable {
                return "\(panel.service.fiveHourLabel) (secondary unavailable)"
            }
            return panel.service.fiveHourLabel
        case .secondary:
            return panel.service.weeklyLabel
        }
    }

    private func groupedHeatmapCells(_ cells: [UsageHistoryHeatmapCell]) -> [[UsageHistoryHeatmapCell]] {
        guard !cells.isEmpty else { return [] }
        let weekCount = max(1, viewModel.selectedRangeWeeks)
        var groups: [[UsageHistoryHeatmapCell]] = Array(repeating: [], count: weekCount)

        for (index, cell) in cells.enumerated() {
            let weekIndex = min(index / 7, weekCount - 1)
            groups[weekIndex].append(cell)
        }
        return groups
    }

    private func tileColor(level: Int, service: ServiceType?) -> Color {
        let base = service?.darkColor ?? .accentColor
        switch level {
        case 0:
            return Color.gray.opacity(0.15)
        case 1:
            return base.opacity(0.25)
        case 2:
            return base.opacity(0.45)
        case 3:
            return base.opacity(0.7)
        default:
            return base.opacity(1)
        }
    }

    private func summaryItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func dayTooltip(for cell: UsageHistoryHeatmapCell) -> String {
        "\(dateString(cell.date))\nPeak: \(percentString(cell.peakRatio))\nAverage: \(percentString(cell.averageRatio))\nSamples: \(cell.sampleCount)"
    }

    private func cycleTooltip(for cell: UsageHistoryCycleCell) -> String {
        let daysTo80 = cell.daysTo80.map(String.init) ?? "-"
        let daysTo100 = cell.daysTo100.map(String.init) ?? "-"
        return """
        \(dateString(cell.cycleStart)) ~ \(dateString(cell.cycleEnd))
        Peak: \(percentString(cell.peakRatio))
        Reached 80%: \(cell.reached80 ? "Yes" : "No")
        Reached 100%: \(cell.reached100 ? "Yes" : "No")
        Days to 80%: \(daysTo80)
        Days to 100%: \(daysTo100)
        High-band hours: \(formatOneDecimal(cell.highBandHours))
        """
    }

    private func percentString(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func formatUsageValue(_ value: Double, unit: UsageUnit?) -> String {
        switch unit {
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.1fM tokens", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.0fK tokens", value / 1_000)
            }
            return String(format: "%.0f tokens", value)
        case .requests:
            return String(format: "%.0f req", value)
        case .dollars:
            return String(format: "$%.2f", value)
        case .percent:
            return String(format: "%.0f%%", value)
        case nil:
            return String(format: "%.0f", value)
        }
    }
}

private struct UsageTrendLineChartView: View {
    let points: [UsageHistoryTrendPoint]
    let service: ServiceType

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local)
            let maxValue = max(points.map(\.value).max() ?? 0, 1)
            let normalizedPoints = normalizedPathPoints(in: rect, maxValue: maxValue)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.08))

                if normalizedPoints.count >= 2 {
                    Path { path in
                        guard let first = normalizedPoints.first else { return }
                        path.move(to: first)
                        for point in normalizedPoints.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(service.darkColor, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

                    Path { path in
                        guard let first = normalizedPoints.first,
                              let last = normalizedPoints.last else { return }
                        path.move(to: CGPoint(x: first.x, y: rect.maxY))
                        path.addLine(to: first)
                        for point in normalizedPoints.dropFirst() {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                        path.closeSubpath()
                    }
                    .fill(service.lightColor.opacity(0.25))
                } else {
                    Text("No trend data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func normalizedPathPoints(in rect: CGRect, maxValue: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }

        let count = points.count
        return points.enumerated().map { index, point in
            let xRatio = count > 1 ? Double(index) / Double(count - 1) : 0
            let x = rect.minX + (rect.width * xRatio)
            let yRatio = min(max(point.value / maxValue, 0), 1)
            let y = rect.maxY - (rect.height * yRatio)
            return CGPoint(x: x, y: y)
        }
    }
}
