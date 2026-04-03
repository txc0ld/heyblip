import SwiftUI

// MARK: - LocationSettings

/// Location precision, proximity alerts, breadcrumbs, and crowd pulse section.
struct LocationSettings: View {

    @Binding var locationSharing: String
    @Binding var proximityAlerts: Bool
    @Binding var breadcrumbs: Bool
    @Binding var crowdPulse: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Location", icon: "location.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsRow(title: "Default Sharing", theme: theme) {
                    Picker("Precision", selection: $locationSharing) {
                        Text("Precise").tag(LocationPrecision.precise.rawValue)
                        Text("Fuzzy").tag(LocationPrecision.fuzzy.rawValue)
                        Text("Off").tag(LocationPrecision.off.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Location sharing precision")
                }

                SettingsComponents.settingsToggleRow(
                    title: "Proximity Alerts",
                    subtitle: "Get notified when friends are nearby",
                    isOn: $proximityAlerts,
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: "Breadcrumb Trails",
                    subtitle: "Track friend movement (opt-in, auto-deleted)",
                    isOn: $breadcrumbs,
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: "Crowd Pulse",
                    subtitle: "Show crowd density heatmap",
                    isOn: $crowdPulse,
                    theme: theme
                )
            }
        }
    }
}

// MARK: - Preview

#Preview("Location Settings") {
    ZStack {
        GradientBackground()

        LocationSettings(
            locationSharing: .constant(LocationPrecision.fuzzy.rawValue),
            proximityAlerts: .constant(true),
            breadcrumbs: .constant(false),
            crowdPulse: .constant(true)
        )
        .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
