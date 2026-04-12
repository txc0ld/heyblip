import SwiftUI

// MARK: - SecuritySettings

/// Recovery kit export section (currently disabled).
struct SecuritySettings: View {

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Security", icon: "lock.fill", theme: theme) {
            // The entire section is currently planned work — lead with the
            // "Coming Soon" header so the card doesn't read as a shipped
            // feature. TODO: BDEV-136 — wire recovery kit export with
            // password-protected file.
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                SettingsComponents.comingSoonHeader(theme: theme)

                SettingsComponents.settingsDisabledRow(
                    title: "Recovery Kit Export",
                    subtitle: "Unavailable in this build until file export is wired",
                    icon: "square.and.arrow.up",
                    theme: theme
                )
            }
        }
    }
}

// MARK: - Preview

#Preview("Security Settings") {
    ZStack {
        GradientBackground()

        SecuritySettings()
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
