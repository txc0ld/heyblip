import SwiftUI

// MARK: - NetworkSettings

/// Transport mode picker section for settings.
struct NetworkSettings: View {

    @Binding var transportMode: String

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Network", icon: "network", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    Text("Transport Mode")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)

                    Picker("Transport Mode", selection: $transportMode) {
                        ForEach(TransportMode.allCases, id: \.self) { mode in
                            Label(mode.label, systemImage: mode.icon)
                                .tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    let currentMode = TransportMode(rawValue: transportMode) ?? .allRadios
                    Text(currentMode.caption)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Network Settings") {
    ZStack {
        GradientBackground()

        NetworkSettings(transportMode: .constant(TransportMode.allRadios.rawValue))
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
