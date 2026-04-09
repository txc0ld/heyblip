import SwiftUI

// MARK: - AccountSettings

/// Sign out, export data, and delete account section.
struct AccountSettings: View {

    @Binding var showSignOutConfirm: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Account", icon: "person.crop.circle", theme: theme) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                // Working action — Sign Out stays prominent.
                Button(action: { showSignOutConfirm = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Sign Out")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Clear local session and return to setup")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign out")

                // Unavailable actions grouped under a de-emphasized heading so
                // working features read as shipped. TODO: BDEV-136 — wire
                // account data export (JSON) and remote account deletion.
                SettingsComponents.comingSoonHeader(theme: theme)

                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    SettingsComponents.settingsDisabledRow(
                        title: "Export My Data",
                        subtitle: "Unavailable in this build until account export is wired",
                        icon: "square.and.arrow.up",
                        theme: theme
                    )

                    SettingsComponents.settingsDisabledRow(
                        title: "Delete Account & Data",
                        subtitle: "Unavailable until remote deletion is wired end to end",
                        icon: "trash",
                        theme: theme,
                        isDestructive: true
                    )
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Account Settings") {
    ZStack {
        GradientBackground()

        AccountSettings(showSignOutConfirm: .constant(false))
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
