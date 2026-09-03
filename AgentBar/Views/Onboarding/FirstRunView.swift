import SwiftUI

struct FirstRunView: View {
    @State private var selection = FirstRunSelection.default
    @State private var detected: Set<ServiceType> = []
    @State private var isDetecting = true

    private let onFinish: (FirstRunSelection) -> Void

    init(onFinish: @escaping (FirstRunSelection) -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 20) {
                servicesSection
                styleSection
                preferencesSection
            }

            Spacer(minLength: 12)

            Divider().padding(.vertical, 14)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 640)
        .task {
            detected = await ProviderDetection.detect()
            selection.services = detected
            isDetecting = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Welcome to AgentBar")
                .font(.title2.weight(.semibold))
            Text("Pick what to track. Everything here can be changed later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Assistants")
                Spacer()
                if isDetecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(allSelected ? "Deselect all" : "Enable all") {
                        selection.services = allSelected
                            ? []
                            : Set(FirstRunSettings.selectableServices)
                    }
                    .buttonStyle(.link)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(FirstRunSettings.selectableServices, id: \.self) { service in
                    serviceRow(service)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )

            Text("Ticked ones were found on this Mac. Tracking a service reads its local logs or credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func serviceRow(_ service: ServiceType) -> some View {
        Toggle(isOn: binding(for: service)) {
            HStack(spacing: 8) {
                Circle()
                    .fill(service.darkColor)
                    .frame(width: 8, height: 8)
                Text(service.rawValue)
                if detected.contains(service) {
                    Text("detected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var allSelected: Bool {
        selection.services.count == FirstRunSettings.selectableServices.count
    }

    private func binding(for service: ServiceType) -> Binding<Bool> {
        Binding(
            get: { selection.services.contains(service) },
            set: { isOn in
                if isOn {
                    selection.services.insert(service)
                } else {
                    selection.services.remove(service)
                }
            }
        )
    }

    // MARK: - Menu bar style

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Menu bar style")

            HStack(spacing: 12) {
                ForEach(StatusBarAppearance.allCases, id: \.rawValue) { appearance in
                    styleCard(appearance)
                }
            }
        }
    }

    private func styleCard(_ appearance: StatusBarAppearance) -> some View {
        let isSelected = selection.appearance == appearance
        return Button {
            selection.appearance = appearance
        } label: {
            VStack(spacing: 10) {
                // A live preview of the real menu bar view, not a static image.
                StackedBarView(services: Self.previewServices, appearance: appearance)
                    .frame(
                        width: StatusBarDisplayPlanner.statusItemLength(
                            for: appearance,
                            serviceCount: Self.previewServices.count
                        ),
                        height: 22
                    )
                    .frame(height: 40)

                Text(appearance.displayName)
                    .font(.callout)
                Text(appearance.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static let previewServices: [UsageData] = [
        preview(.claude, five: 0.62, weekly: 0.28),
        preview(.codex, five: 0.35, weekly: 0.50),
        preview(.cursor, five: 0.88, weekly: nil)
    ]

    private static func preview(_ service: ServiceType, five: Double, weekly: Double?) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(used: five * 100, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: weekly.map {
                UsageMetric(used: $0 * 100, total: 100, unit: .percent, resetTime: nil)
            },
            lastUpdated: Date(),
            isAvailable: true
        )
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Preferences")

            Toggle("Launch at login", isOn: $selection.launchAtLogin)

            Picker("Refresh every", selection: $selection.refreshInterval) {
                Text("30 seconds").tag(30.0)
                Text("60 seconds").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
            }
            .frame(maxWidth: 260)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selection.services.count) of \(FirstRunSettings.selectableServices.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") {
                onFinish(selection)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    #if DEBUG
    func selectionForTesting() -> FirstRunSelection { selection }
    #endif
}
