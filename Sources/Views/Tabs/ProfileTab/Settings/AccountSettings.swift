import SwiftUI

// MARK: - AccountSettings

/// Sign out, export data, and delete account section.
struct AccountSettings: View {

    @Binding var showSignOutConfirm: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Account", icon: "person.crop.circle", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                // Sign Out
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

                Divider().opacity(0.15)

                // Export My Data
                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Export My Data")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable in this build until account export is wired")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Export my data as JSON")

                Divider().opacity(0.15)

                // Delete Account
                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Delete Account & Data")
                                .font(theme.typography.body)
                                .foregroundStyle(BlipColors.darkColors.statusRed)

                            Text("Unavailable until remote deletion is wired end to end")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Delete account unavailable in this build")
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
