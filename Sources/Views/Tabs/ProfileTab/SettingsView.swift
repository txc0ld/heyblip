import SwiftUI

// MARK: - SettingsView

/// App settings: theme, location, notifications, PTT mode,
/// recovery export, and about/legal sections.
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
                    appearanceSection
                        .staggeredReveal(index: 0)

                    networkSection
                        .staggeredReveal(index: 1)

                    locationSection
                        .staggeredReveal(index: 2)

                    notificationsSection
                        .staggeredReveal(index: 3)

                    chatSection
                        .staggeredReveal(index: 4)

                    securitySection
                        .staggeredReveal(index: 5)

                    aboutSection
                        .staggeredReveal(index: 6)

                    dangerZone
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

    // MARK: - Appearance

    private var appearanceSection: some View {
        settingsGroup(title: "Appearance", icon: "paintbrush.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsRow(title: "Theme") {
                    Picker("Theme", selection: themeBinding) {
                        ForEach(AppTheme.allCases, id: \.self) { themeOption in
                            Label(themeOption.label, systemImage: themeOption.icon)
                                .tag(themeOption)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        settingsGroup(title: "Network", icon: "network") {
            VStack(spacing: BlipSpacing.md) {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    Text("Transport Mode")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)

                    Picker("Transport Mode", selection: $transportModeRaw) {
                        ForEach(TransportMode.allCases, id: \.self) { mode in
                            Label(mode.label, systemImage: mode.icon)
                                .tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    let currentMode = TransportMode(rawValue: transportModeRaw) ?? .allRadios
                    Text(currentMode.caption)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        settingsGroup(title: "Location", icon: "location.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsRow(title: "Default Sharing") {
                    Picker("Precision", selection: locationSharingBinding) {
                        Text("Precise").tag(LocationPrecision.precise.rawValue)
                        Text("Fuzzy").tag(LocationPrecision.fuzzy.rawValue)
                        Text("Off").tag(LocationPrecision.off.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                settingsToggleRow(title: "Proximity Alerts", subtitle: "Get notified when friends are nearby", isOn: proximityAlertsBinding)

                settingsToggleRow(title: "Breadcrumb Trails", subtitle: "Track friend movement (opt-in, auto-deleted)", isOn: breadcrumbsBinding)

                settingsToggleRow(title: "Crowd Pulse", subtitle: "Show crowd density heatmap", isOn: crowdPulseBinding)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        settingsGroup(title: "Notifications", icon: "bell.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsToggleRow(title: "Push Notifications", subtitle: "Receive notifications for messages", isOn: notificationsBinding)

                settingsToggleRow(title: "Auto-Join Channels", subtitle: "Automatically join nearby location channels", isOn: autoJoinChannelsBinding)
            }
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        settingsGroup(title: "Chat", icon: "message.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsRow(title: "Push-to-Talk Mode") {
                    Picker("PTT Mode", selection: pttModeBinding) {
                        Text("Hold").tag(PTTMode.holdToTalk.rawValue)
                        Text("Toggle").tag(PTTMode.toggleTalk.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        settingsGroup(title: "Security", icon: "lock.fill") {
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

    // MARK: - About

    private var aboutSection: some View {
        settingsGroup(title: "About", icon: "info.circle.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsInfoRow(title: "Version", value: "1.0.0")
                settingsInfoRow(title: "Build", value: "2026.03.28")

                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Privacy Policy")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable until hosted legal pages are published")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Privacy policy unavailable in this build")

                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Terms of Service")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable until hosted legal pages are published")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Terms of service unavailable in this build")

                Button(action: {}) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Open Source Licenses")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Unavailable until the in-app acknowledgements screen is wired")
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Open source licenses unavailable in this build")
            }
        }
    }

    // MARK: - Account

    private var dangerZone: some View {
        settingsGroup(title: "Account", icon: "person.crop.circle") {
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

    // MARK: - Reusable Components

    private func settingsGroup<Content: View>(title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blipAccentPurple)

                    Text(title)
                        .font(theme.typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.colors.text)
                }

                content()
            }
        }
    }

    private func settingsRow<Content: View>(title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)

            Spacer()

            trailing()
        }
        .frame(minHeight: BlipSizing.minTapTarget)
    }

    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                Text(title)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)

                Text(subtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
        .tint(.blipAccentPurple)
        .frame(minHeight: BlipSizing.minTapTarget)
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }

    private func settingsInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)

            Spacer()

            Text(value)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
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
