import SwiftUI

// MARK: - SettingsView

/// App settings: theme, location, notifications, PTT mode,
/// recovery export, and about/legal sections.
struct SettingsView: View {

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

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

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
        .alert("Export Recovery Kit", isPresented: $showExportRecovery) {
            Button("Export") {
                // Export encrypted keypair backup
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create a password-protected backup of your encryption keys. Keep it safe -- you'll need it to recover your identity on a new device.")
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                // Clear session and return to onboarding
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your local session. You can sign back in with your email to restore your account.")
        }
        .alert("Delete Account", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                // Delete account
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your keys and all local data. Friends will see you as a new user if you re-register. This cannot be undone.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        settingsGroup(title: "Appearance", icon: "paintbrush.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsRow(title: "Theme") {
                    Picker("Theme", selection: $selectedTheme) {
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
                    Picker("Precision", selection: $locationSharing) {
                        Text("Precise").tag(LocationPrecision.precise.rawValue)
                        Text("Fuzzy").tag(LocationPrecision.fuzzy.rawValue)
                        Text("Off").tag(LocationPrecision.off.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                settingsToggleRow(title: "Proximity Alerts", subtitle: "Get notified when friends are nearby", isOn: $proximityAlerts)

                settingsToggleRow(title: "Breadcrumb Trails", subtitle: "Track friend movement (opt-in, auto-deleted)", isOn: $breadcrumbs)

                settingsToggleRow(title: "Crowd Pulse", subtitle: "Show crowd density heatmap", isOn: $crowdPulseVisible)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        settingsGroup(title: "Notifications", icon: "bell.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsToggleRow(title: "Push Notifications", subtitle: "Receive notifications for messages", isOn: $notificationsEnabled)

                settingsToggleRow(title: "Auto-Join Channels", subtitle: "Automatically join nearby location channels", isOn: $autoJoinChannels)
            }
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        settingsGroup(title: "Chat", icon: "message.fill") {
            VStack(spacing: BlipSpacing.md) {
                settingsRow(title: "Push-to-Talk Mode") {
                    Picker("PTT Mode", selection: $pttModeRaw) {
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
                Button(action: { showExportRecovery = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Export Recovery Kit")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Encrypted backup of your encryption keys")
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
                        Text("Privacy Policy")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)

                Button(action: {}) {
                    HStack {
                        Text("Terms of Service")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)

                Button(action: {}) {
                    HStack {
                        Text("Open Source Licenses")
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
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
                Button(action: { exportUserData() }) {
                    HStack {
                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Export My Data")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.colors.text)

                            Text("Export profile as JSON to Files")
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
                .accessibilityLabel("Export my data as JSON")

                Divider().opacity(0.15)

                // Delete Account
                Button(action: { showDeleteConfirm = true }) {
                    HStack {
                        Text("Delete Account & Data")
                            .font(theme.typography.body)
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete account and all data")
            }
        }
    }

    // MARK: - Actions

    private func exportUserData() {
        // Export user profile as JSON via share sheet
        // Will be wired to real SwiftData user in Part C
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
