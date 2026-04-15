import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum SettingsL10n {
    static let title = String(localized: "settings.title", defaultValue: "Settings")
    static let signOutTitle = String(localized: "settings.sign_out.title", defaultValue: "Sign Out")
    static let signOutButton = String(localized: "settings.sign_out.button", defaultValue: "Sign Out")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let signOutMessage = String(localized: "settings.sign_out.message", defaultValue: "This clears the local identity on this device, wipes local data, and returns you to setup. Remote account restore is not available yet.")
    static let deleteAccountTitle = String(localized: "settings.delete_account.title", defaultValue: "Delete your account?")
    static let deleteButton = String(localized: "common.delete", defaultValue: "Delete")
    static let deleteAccountMessage = String(localized: "settings.delete_account.message", defaultValue: "This will permanently remove your account from HeyBlip servers and wipe this device after the server deletion succeeds.")
    static let deleteConfirmTitle = String(localized: "settings.delete_account.confirm_title", defaultValue: "Type DELETE to confirm")
    static let deleteConfirmPlaceholder = String(localized: "settings.delete_account.confirm_placeholder", defaultValue: "DELETE")
    static let deleteAccountButton = String(localized: "settings.delete_account.confirm_button", defaultValue: "Delete Account")
    static let deleteConfirmMessage = String(localized: "settings.delete_account.confirm_message", defaultValue: "Enter DELETE to confirm permanent account deletion.")
    static let actionFailedTitle = String(localized: "settings.account_action_failed.title", defaultValue: "Account Action Failed")
    static let ok = String(localized: "common.ok", defaultValue: "OK")
    static let unknownAccountError = String(localized: "settings.account_action_failed.unknown", defaultValue: "An unknown account error occurred.")
    static let failedLocalClear = String(localized: "settings.sign_out.failed_local_clear", defaultValue: "Failed to clear local account data.")
    static let profileUnavailable = String(localized: "settings.account_action_failed.profile_unavailable", defaultValue: "Profile data is not available yet.")
    static let deleteServerFailedFormat = String(localized: "settings.delete_account.server_failed_format", defaultValue: "Server deletion failed. Try again later. %@")
    static let localResetUnavailable = String(localized: "settings.delete_account.local_reset_unavailable", defaultValue: "Account was deleted on the server, but this build cannot reset local state automatically.")
    static let localResetFailed = String(localized: "settings.delete_account.local_reset_failed", defaultValue: "Account was deleted on the server, but local data cleanup failed.")
    static let exportSaved = String(localized: "settings.account_export.saved", defaultValue: "Account export saved")
    static let exportPasswordTitle = String(localized: "settings.account_export.password_title", defaultValue: "Encrypt Export")
    static let exportPasswordMessage = String(localized: "settings.account_export.password_message", defaultValue: "Enter a password to encrypt your account export. You will need this password to import the data later.")
    static let exportPasswordPlaceholder = String(localized: "settings.account_export.password_placeholder", defaultValue: "Password")
    static let exportPasswordConfirmPlaceholder = String(localized: "settings.account_export.password_confirm_placeholder", defaultValue: "Confirm Password")
    static let exportButton = String(localized: "settings.account_export.export_button", defaultValue: "Encrypt & Export")
    static let exportPasswordMismatch = String(localized: "settings.account_export.password_mismatch", defaultValue: "Passwords do not match.")
    static let exportPasswordTooShort = String(localized: "settings.account_export.password_too_short", defaultValue: "Password must be at least 8 characters.")

    static func deleteServerFailed(_ error: String) -> String {
        String(format: deleteServerFailedFormat, locale: Locale.current, error)
    }
}

// MARK: - SettingsView

/// App settings coordinator. All `@AppStorage` lives here and is passed
/// as `@Binding` to individual section views under `Settings/`.
struct SettingsView: View {

    var profileViewModel: ProfileViewModel? = nil
    var onSignOut: (() -> Bool)? = nil

    @AppStorage("appTheme") private var selectedTheme: AppTheme = .system
    @AppStorage("locationPrecision") private var locationSharing: String = LocationPrecision.fuzzy.rawValue
    @AppStorage("pushNotifications") private var notificationsEnabled: Bool = true
    @AppStorage("proximityAlerts") private var proximityAlerts: Bool = true
    @AppStorage("pttMode") private var pttModeRaw: String = PTTMode.holdToTalk.rawValue
    @AppStorage("autoJoinChannels") private var autoJoinChannels: Bool = true
    @AppStorage("crowdPulse") private var crowdPulseVisible: Bool = true
    @AppStorage("breadcrumbTrails") private var breadcrumbs: Bool = false
    @AppStorage("transportMode") private var transportModeRaw: String = TransportMode.allRadios.rawValue
    @State private var showSignOutConfirm: Bool = false
    @State private var showDeleteAccountConfirm: Bool = false
    @State private var showDeleteAccountTextPrompt: Bool = false
    @State private var deleteConfirmationText: String = ""
    @State private var isExportingAccountData = false
    @State private var isDeletingAccount = false
    @State private var exportFileURL: URL?
    @State private var actionErrorMessage: String?
    @State private var isHydratingPreferences = false
    @State private var showExportPasswordPrompt = false
    @State private var exportPassword: String = ""
    @State private var exportPasswordConfirm: String = ""

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            GradientBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BlipSpacing.lg) {
                    AppearanceSettings(appTheme: themeBinding)
                        .staggeredReveal(index: 0)

                    NetworkSettings(transportMode: $transportModeRaw)
                        .staggeredReveal(index: 1)

                    LocationSettings(
                        locationSharing: locationSharingBinding,
                        proximityAlerts: proximityAlertsBinding,
                        breadcrumbs: breadcrumbsBinding,
                        crowdPulse: crowdPulseBinding
                    )
                    .staggeredReveal(index: 2)

                    NotificationSettings(
                        pushNotifications: notificationsBinding,
                        autoJoinChannels: autoJoinChannelsBinding
                    )
                    .staggeredReveal(index: 3)

                    ChatSettings(pttMode: pttModeBinding)
                        .staggeredReveal(index: 4)

                    SecuritySettings()
                        .staggeredReveal(index: 5)

                    AboutSettings()
                        .staggeredReveal(index: 6)

                    AccountSettings(
                        showSignOutConfirm: $showSignOutConfirm,
                        isExporting: isExportingAccountData,
                        isDeleting: isDeletingAccount,
                        onExportData: startAccountExport,
                        onDeleteAccount: { showDeleteAccountConfirm = true }
                    )
                        .staggeredReveal(index: 7)

                    Spacer().frame(height: BlipSpacing.xxl)
                }
                .padding(BlipSpacing.md)
            }
        }
        .navigationTitle(SettingsL10n.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await profileViewModel?.loadProfile()
            hydrateFromPreferences()
        }
        .alert(SettingsL10n.signOutTitle, isPresented: $showSignOutConfirm) {
            Button(SettingsL10n.signOutButton, role: .destructive) {
                if let onSignOut, onSignOut() {
                    dismiss()
                } else if onSignOut == nil {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    dismiss()
                } else {
                    actionErrorMessage = SettingsL10n.failedLocalClear
                }
            }
            Button(SettingsL10n.cancel, role: .cancel) {}
        } message: {
            Text(SettingsL10n.signOutMessage)
        }
        .alert(SettingsL10n.deleteAccountTitle, isPresented: $showDeleteAccountConfirm) {
            Button(SettingsL10n.deleteButton, role: .destructive) {
                deleteConfirmationText = ""
                showDeleteAccountTextPrompt = true
            }
            Button(SettingsL10n.cancel, role: .cancel) {}
        } message: {
            Text(SettingsL10n.deleteAccountMessage)
        }
        .alert(SettingsL10n.deleteConfirmTitle, isPresented: $showDeleteAccountTextPrompt) {
            TextField(SettingsL10n.deleteConfirmPlaceholder, text: $deleteConfirmationText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button(SettingsL10n.deleteAccountButton, role: .destructive) {
                guard deleteConfirmationText.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" else {
                    actionErrorMessage = SettingsL10n.deleteConfirmMessage
                    return
                }
                Task { await deleteAccount() }
            }
            Button(SettingsL10n.cancel, role: .cancel) {
                deleteConfirmationText = ""
            }
        } message: {
            Text(SettingsL10n.deleteConfirmMessage)
        }
        .alert(SettingsL10n.actionFailedTitle, isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button(SettingsL10n.ok, role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? SettingsL10n.unknownAccountError)
        }
        .sheet(isPresented: Binding(
            get: { exportFileURL != nil },
            set: { if !$0 { exportFileURL = nil } }
        )) {
            if let exportFileURL {
                AccountExportShareSheet(fileURL: exportFileURL)
            }
        }
        .sheet(isPresented: $showExportPasswordPrompt) {
            ExportPasswordPrompt(
                password: $exportPassword,
                passwordConfirm: $exportPasswordConfirm,
                onExport: {
                    showExportPasswordPrompt = false
                    performEncryptedExport()
                },
                onCancel: {
                    showExportPasswordPrompt = false
                    exportPassword = ""
                    exportPasswordConfirm = ""
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Actions

    private func hydrateFromPreferences() {
        guard let preferences = profileViewModel?.preferences else { return }

        isHydratingPreferences = true
        selectedTheme = preferences.theme
        locationSharing = preferences.defaultLocationSharing.rawValue
        notificationsEnabled = preferences.notificationsEnabled
        proximityAlerts = preferences.proximityAlertsEnabled
        pttModeRaw = preferences.pttMode.rawValue
        autoJoinChannels = preferences.autoJoinNearbyChannels
        crowdPulseVisible = preferences.crowdPulseVisible
        breadcrumbs = preferences.breadcrumbsEnabled
        isHydratingPreferences = false
    }

    private func startAccountExport() {
        guard !isExportingAccountData else { return }

        exportPassword = ""
        exportPasswordConfirm = ""
        showExportPasswordPrompt = true
    }

    private func performEncryptedExport() {
        guard !isExportingAccountData else { return }

        let password = exportPassword
        let confirm = exportPasswordConfirm

        // Validate password length
        guard password.count >= 8 else {
            actionErrorMessage = SettingsL10n.exportPasswordTooShort
            return
        }

        // Validate passwords match
        guard password == confirm else {
            actionErrorMessage = SettingsL10n.exportPasswordMismatch
            return
        }

        Task {
            isExportingAccountData = true
            defer { isExportingAccountData = false }

            guard let profileViewModel else {
                actionErrorMessage = SettingsL10n.profileUnavailable
                return
            }

            do {
                let export = try await profileViewModel.exportAccountData(password: password)
                exportFileURL = export.url
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAccount() async {
        guard !isDeletingAccount else { return }

        isDeletingAccount = true
        defer {
            isDeletingAccount = false
            deleteConfirmationText = ""
        }

        guard let profileViewModel else {
            actionErrorMessage = SettingsL10n.profileUnavailable
            return
        }

        do {
            try await profileViewModel.deleteAccountRemotely()
        } catch {
            actionErrorMessage = SettingsL10n.deleteServerFailed(error.localizedDescription)
            return
        }

        guard let onSignOut else {
            actionErrorMessage = SettingsL10n.localResetUnavailable
            return
        }

        if onSignOut() {
            dismiss()
        } else {
            actionErrorMessage = SettingsL10n.localResetFailed
        }
    }

    // MARK: - Preference Bindings

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { profileViewModel?.preferences?.theme ?? selectedTheme },
            set: { newValue in
                selectedTheme = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(theme: newValue)
            }
        )
    }

    private var locationSharingBinding: Binding<String> {
        Binding(
            get: { profileViewModel?.preferences?.defaultLocationSharing.rawValue ?? locationSharing },
            set: { newValue in
                locationSharing = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(defaultLocationSharing: LocationPrecision(rawValue: newValue) ?? .off)
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { profileViewModel?.preferences?.notificationsEnabled ?? notificationsEnabled },
            set: { newValue in
                notificationsEnabled = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(notificationsEnabled: newValue)
            }
        )
    }

    private var proximityAlertsBinding: Binding<Bool> {
        Binding(
            get: { profileViewModel?.preferences?.proximityAlertsEnabled ?? proximityAlerts },
            set: { newValue in
                proximityAlerts = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(proximityAlertsEnabled: newValue)
            }
        )
    }

    private var breadcrumbsBinding: Binding<Bool> {
        Binding(
            get: { profileViewModel?.preferences?.breadcrumbsEnabled ?? breadcrumbs },
            set: { newValue in
                breadcrumbs = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(breadcrumbsEnabled: newValue)
            }
        )
    }

    private var crowdPulseBinding: Binding<Bool> {
        Binding(
            get: { profileViewModel?.preferences?.crowdPulseVisible ?? crowdPulseVisible },
            set: { newValue in
                crowdPulseVisible = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(crowdPulseVisible: newValue)
            }
        )
    }

    private var pttModeBinding: Binding<String> {
        Binding(
            get: { profileViewModel?.preferences?.pttMode.rawValue ?? pttModeRaw },
            set: { newValue in
                pttModeRaw = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(pttMode: PTTMode(rawValue: newValue) ?? .holdToTalk)
            }
        )
    }

    private var autoJoinChannelsBinding: Binding<Bool> {
        Binding(
            get: { profileViewModel?.preferences?.autoJoinNearbyChannels ?? autoJoinChannels },
            set: { newValue in
                autoJoinChannels = newValue
                guard !isHydratingPreferences else { return }
                profileViewModel?.updatePreferences(autoJoinNearbyChannels: newValue)
            }
        )
    }
}

// MARK: - Export Password Prompt

private struct ExportPasswordPrompt: View {

    @Binding var password: String
    @Binding var passwordConfirm: String
    let onExport: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    private var isValid: Bool {
        password.count >= 8 && password == passwordConfirm
    }

    private var validationMessage: String? {
        if password.isEmpty && passwordConfirm.isEmpty {
            return nil
        }
        if password.count < 8 {
            return SettingsL10n.exportPasswordTooShort
        }
        if !passwordConfirm.isEmpty && password != passwordConfirm {
            return SettingsL10n.exportPasswordMismatch
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BlipSpacing.lg) {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    Text(SettingsL10n.exportPasswordMessage)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.leading)
                }

                VStack(spacing: BlipSpacing.md) {
                    SecureField(SettingsL10n.exportPasswordPlaceholder, text: $password)
                        .textContentType(.newPassword)
                        .padding(BlipSpacing.sm)
                        .background(theme.colors.cardBG)
                        .cornerRadius(BlipSpacing.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: BlipSpacing.sm)
                                .stroke(theme.colors.border, lineWidth: 0.5)
                        )
                        .accessibilityLabel(SettingsL10n.exportPasswordPlaceholder)

                    SecureField(SettingsL10n.exportPasswordConfirmPlaceholder, text: $passwordConfirm)
                        .textContentType(.newPassword)
                        .padding(BlipSpacing.sm)
                        .background(theme.colors.cardBG)
                        .cornerRadius(BlipSpacing.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: BlipSpacing.sm)
                                .stroke(theme.colors.border, lineWidth: 0.5)
                        )
                        .accessibilityLabel(SettingsL10n.exportPasswordConfirmPlaceholder)
                }

                if let message = validationMessage {
                    Text(message)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onExport) {
                    Text(SettingsL10n.exportButton)
                        .font(theme.typography.body)
                        .frame(maxWidth: .infinity)
                        .padding(BlipSpacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blipAccentPurple)
                .disabled(!isValid)
                .accessibilityLabel(SettingsL10n.exportButton)

                Spacer()
            }
            .padding(BlipSpacing.lg)
            .navigationTitle(SettingsL10n.exportPasswordTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SettingsL10n.cancel, action: onCancel)
                }
            }
        }
    }
}

#Preview("Export Password Prompt") {
    ExportPasswordPrompt(
        password: .constant(""),
        passwordConfirm: .constant(""),
        onExport: {},
        onCancel: {}
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

#if canImport(UIKit)
private struct AccountExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct AccountExportShareSheet: View {
    let fileURL: URL

    var body: some View {
        VStack(spacing: BlipSpacing.md) {
            Text(SettingsL10n.exportSaved)
                .font(.headline)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
#endif

// MARK: - Preview

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Settings - Light") {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.light)
    .blipTheme()
}
