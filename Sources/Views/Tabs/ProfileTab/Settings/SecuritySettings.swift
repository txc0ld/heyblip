import SwiftUI

// MARK: - SecuritySettings

/// Recovery kit export section (currently disabled).
struct SecuritySettings: View {

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Security", icon: "lock.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Recovery Kit Export")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable in this build until file export is wired")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }

                        Spacer()

                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Export recovery kit")
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
