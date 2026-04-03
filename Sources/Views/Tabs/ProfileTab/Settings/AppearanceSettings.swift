import SwiftUI

// MARK: - AppearanceSettings

/// Theme picker section for settings.
struct AppearanceSettings: View {

    @Binding var appTheme: AppTheme

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Appearance", icon: "paintbrush.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsRow(title: "Theme", theme: theme) {
                    Picker("Theme", selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { themeOption in
                            Label(themeOption.label, systemImage: themeOption.icon)
                                .tag(themeOption)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Theme")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Appearance Settings") {
    ZStack {
        GradientBackground()

        AppearanceSettings(appTheme: .constant(.system))
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
