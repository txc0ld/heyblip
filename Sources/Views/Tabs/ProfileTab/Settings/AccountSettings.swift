import SwiftUI

private enum AccountSettingsL10n {
    static let title = String(localized: "settings.account.title", defaultValue: "Account")
    static let signOut = String(localized: "settings.account.sign_out.title", defaultValue: "Sign Out")
    static let signOutSubtitle = String(localized: "settings.account.sign_out.subtitle", defaultValue: "Clear local session and return to setup")
    static let signOutAccessibility = String(localized: "settings.account.sign_out.accessibility_label", defaultValue: "Sign out")
    static let exportData = String(localized: "settings.account.export.title", defaultValue: "Export My Data")
    static let exportPreparing = String(localized: "settings.account.export.preparing", defaultValue: "Preparing your JSON export...")
    static let exportSubtitle = String(localized: "settings.account.export.subtitle", defaultValue: "Create a password-encrypted archive of profile, messages, friends, and saved events")
    static let exportAccessibility = String(localized: "settings.account.export.accessibility_label", defaultValue: "Export my data")
    static let deleteAccount = String(localized: "settings.account.delete.title", defaultValue: "Delete Account & Data")
    static let deleteProgress = String(localized: "settings.account.delete.progress", defaultValue: "Deleting your account...")
    static let deleteSubtitle = String(localized: "settings.account.delete.subtitle", defaultValue: "Permanently remove your Blip account from the server and this device")
    static let deleteAccessibility = String(localized: "settings.account.delete.accessibility_label", defaultValue: "Delete account and data")
}

// MARK: - AccountSettings

/// Sign out, export data, and delete account section.
struct AccountSettings: View {

    @Binding var showSignOutConfirm: Bool
    let isExporting: Bool
    let isDeleting: Bool
    let onExportData: () -> Void
    let onDeleteAccount: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: AccountSettingsL10n.title, icon: "person.crop.circle", theme: theme) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                actionRow(
                    title: AccountSettingsL10n.signOut,
                    subtitle: AccountSettingsL10n.signOutSubtitle,
                    icon: "rectangle.portrait.and.arrow.right"
                ) {
                    showSignOutConfirm = true
                }
                .accessibilityLabel(AccountSettingsL10n.signOutAccessibility)

                Divider()
                    .opacity(0.15)

                actionRow(
                    title: AccountSettingsL10n.exportData,
                    subtitle: isExporting
                        ? AccountSettingsL10n.exportPreparing
                        : AccountSettingsL10n.exportSubtitle,
                    icon: "square.and.arrow.up",
                    showsProgress: isExporting,
                    isDisabled: isExporting || isDeleting,
                    action: onExportData
                )
                .accessibilityLabel(AccountSettingsL10n.exportAccessibility)

                actionRow(
                    title: AccountSettingsL10n.deleteAccount,
                    subtitle: isDeleting
                        ? AccountSettingsL10n.deleteProgress
                        : AccountSettingsL10n.deleteSubtitle,
                    icon: "trash",
                    isDestructive: true,
                    showsProgress: isDeleting,
                    isDisabled: isExporting || isDeleting,
                    action: onDeleteAccount
                )
                .accessibilityLabel(AccountSettingsL10n.deleteAccessibility)
            }
        }
    }

    private func actionRow(
        title: String,
        subtitle: String,
        icon: String,
        isDestructive: Bool = false,
        showsProgress: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: BlipSpacing.sm) {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(title)
                        .font(theme.typography.body)
                        .foregroundStyle(
                            isDestructive ? theme.colors.statusRed : theme.colors.text
                        )

                    Text(subtitle)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if showsProgress {
                    ProgressView()
                        .tint(isDestructive ? theme.colors.statusRed : .blipAccentPurple)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(
                            isDestructive ? theme.colors.statusRed : theme.colors.mutedText
                        )
                }
            }
            .frame(minHeight: BlipSizing.minTapTarget)
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Preview

#Preview("Account Settings") {
    ZStack {
        GradientBackground()

        AccountSettings(
            showSignOutConfirm: .constant(false),
            isExporting: false,
            isDeleting: false,
            onExportData: {},
            onDeleteAccount: {}
        )
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
