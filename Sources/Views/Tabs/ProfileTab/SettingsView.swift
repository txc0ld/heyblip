import SwiftUI

// MARK: - SettingsView

/// App settings coordinator. All `@AppStorage` lives here and is passed
/// as `@Binding` to individual section views under `Settings/`.
struct SettingsView: View {

    var profileViewModel: ProfileViewModel? = nil
    var onSignOut: (() -> Void)? = nil

    @AppStorage("appTheme") private var selectedTheme: AppTheme = .system
    @AppStorage("locationPrecision") private var locationSharing: String = LocationPrecision.fuzzy.rawValue
    @AppStorage("pushNotifications") private var notificationsEnabled: Bool = true
    @AppStorage("proximityAlerts") private var proximityAlerts: Bool = true
    @AppStorage("pttMode") private var pttModeRaw: String = PTTMode.holdToTalk.rawValue
    @AppStorage("autoJoinChannels") private var autoJoinChannels: Bool = true
    @AppStorage("crowdPulse") private var crowdPulseVisible: Bool = true
    @AppStorage("breadcrumbTrails") private var breadcrumbs: Bool = false
    @AppStorage("transportMode") private var transportModeRaw: String = TransportMode.allRadios.rawValue
    @State private var showExportRecovery: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showSignOutConfirm: Bool = false
    @State private var isHydratingPreferences = false

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

                    AccountSettings(showSignOutConfirm: $showSignOutConfirm)
                        .staggeredReveal(index: 7)

                    Spacer().frame(height: BlipSpacing.xxl)
                }
                .padding(BlipSpacing.md)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await profileViewModel?.loadProfile()
            hydrateFromPreferences()
        }
        .alert("Recovery Kit Export Unavailable", isPresented: $showExportRecovery) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Recovery-kit export is disabled in this build until file export and password flow are wired end to end.")
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                if let onSignOut {
                    onSignOut()
                    dismiss()
                } else {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the local identity on this device, wipes local data, and returns you to setup. Remote account restore is not available yet.")
        }
        .alert("Account Deletion Unavailable", isPresented: $showDeleteConfirm) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remote account deletion is not wired in this build. Local sign-out above is the only supported reset path.")
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
