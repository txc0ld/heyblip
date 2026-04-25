import SwiftUI
import SwiftData

// MARK: - L10n

private enum NotificationsSettingsL10n {
    static let title = String(
        localized: "settings.notifications.title",
        defaultValue: "Notifications"
    )
    static let typesSection = String(
        localized: "settings.notifications.types.title",
        defaultValue: "Notification types"
    )
    static let dmsTitle = String(
        localized: "settings.notifications.types.dms.title",
        defaultValue: "Direct messages"
    )
    static let dmsSubtitle = String(
        localized: "settings.notifications.types.dms.subtitle",
        defaultValue: "Notify me when someone sends me a DM"
    )
    static let friendRequestsTitle = String(
        localized: "settings.notifications.types.friend_requests.title",
        defaultValue: "Friend requests"
    )
    static let friendRequestsSubtitle = String(
        localized: "settings.notifications.types.friend_requests.subtitle",
        defaultValue: "Notify me when someone sends or accepts a request"
    )
    static let groupMentionsTitle = String(
        localized: "settings.notifications.types.group_mentions.title",
        defaultValue: "Group mentions"
    )
    static let groupMentionsSubtitle = String(
        localized: "settings.notifications.types.group_mentions.subtitle",
        defaultValue: "Notify me only when I'm mentioned in a group"
    )
    static let voiceNotesTitle = String(
        localized: "settings.notifications.types.voice_notes.title",
        defaultValue: "Voice notes"
    )
    static let voiceNotesSubtitle = String(
        localized: "settings.notifications.types.voice_notes.subtitle",
        defaultValue: "Notify me when I receive a voice note"
    )

    static let quietHoursSection = String(
        localized: "settings.notifications.quiet_hours.title",
        defaultValue: "Quiet hours"
    )
    static let quietHoursEnabled = String(
        localized: "settings.notifications.quiet_hours.enabled",
        defaultValue: "Enable quiet hours"
    )
    static let quietHoursEnabledSubtitle = String(
        localized: "settings.notifications.quiet_hours.enabled.subtitle",
        defaultValue: "Silence non-SOS notifications inside this window"
    )
    static let quietHoursStart = String(
        localized: "settings.notifications.quiet_hours.start",
        defaultValue: "Start"
    )
    static let quietHoursEnd = String(
        localized: "settings.notifications.quiet_hours.end",
        defaultValue: "End"
    )

    static let mutedChannelsSection = String(
        localized: "settings.notifications.muted_channels.title",
        defaultValue: "Muted channels"
    )
    static let mutedChannelsEmpty = String(
        localized: "settings.notifications.muted_channels.empty",
        defaultValue: "No muted channels"
    )

    static let mutedFriendsSection = String(
        localized: "settings.notifications.muted_friends.title",
        defaultValue: "Muted friends"
    )
    static let mutedFriendsEmpty = String(
        localized: "settings.notifications.muted_friends.empty",
        defaultValue: "No muted friends"
    )

    static let unmute = String(
        localized: "settings.notifications.unmute",
        defaultValue: "Unmute"
    )
    static let indefiniteCaption = String(
        localized: "settings.notifications.muted.indefinite",
        defaultValue: "Muted indefinitely"
    )
    static let untilCaptionFormat = String(
        localized: "settings.notifications.muted.until_format",
        defaultValue: "Muted until %@"
    )

    static let sosFooter = String(
        localized: "settings.notifications.sos_footer",
        defaultValue: "SOS alerts are always delivered, regardless of these settings."
    )

    static func untilCaption(_ date: String) -> String {
        String(format: untilCaptionFormat, locale: Locale.current, date)
    }
}

// MARK: - View

/// Per-type, quiet-hours, and muted-entity controls for push notifications.
/// The global on/off toggle still lives in `NotificationSettings` — this view
/// is additive and layers finer-grained controls below it.
struct NotificationsSettingsView: View {

    // Query the live mute rows so toggling mutes elsewhere in the app
    // updates this list without a manual refresh.
    @Query(sort: \ChannelMute.createdAt, order: .reverse)
    private var channelMutes: [ChannelMute]

    @Query(sort: \FriendMute.createdAt, order: .reverse)
    private var friendMutes: [FriendMute]

    @Query private var channels: [Channel]
    @Query private var friends: [Friend]

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    private let prefsService = NotificationPreferencesService.shared

    // Local state for the UI; on appear we hydrate from the service.
    @State private var dmsEnabled: Bool = true
    @State private var friendRequestsEnabled: Bool = true
    @State private var groupMentionsEnabled: Bool = true
    @State private var voiceNotesEnabled: Bool = true

    @State private var quietHoursEnabled: Bool = false
    @State private var quietHoursStart: Date = Self.defaultQuietStart
    @State private var quietHoursEnd: Date = Self.defaultQuietEnd

    @State private var hasHydrated: Bool = false

    private static let defaultQuietStart: Date = {
        Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    }()
    private static let defaultQuietEnd: Date = {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }()

    private static let untilDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: Body

    var body: some View {
        ZStack {
            GradientBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: BlipSpacing.lg) {
                    notificationTypesSection
                        .staggeredReveal(index: 0)

                    quietHoursSection
                        .staggeredReveal(index: 1)

                    mutedChannelsSection
                        .staggeredReveal(index: 2)

                    mutedFriendsSection
                        .staggeredReveal(index: 3)

                    sosFooter
                        .staggeredReveal(index: 4)

                    Spacer().frame(height: BlipSpacing.xxl)
                }
                .padding(BlipSpacing.md)
            }
        }
        .navigationTitle(NotificationsSettingsL10n.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // One-time hydration from the service's current preferences so
            // the toggles reflect persisted state on first appear.
            guard !hasHydrated else { return }
            prefsService.configure(modelContext: modelContext)
            let prefs = prefsService.currentPreferences()
            dmsEnabled = prefs.notificationsDMsEnabled
            friendRequestsEnabled = prefs.notificationsFriendRequestsEnabled
            groupMentionsEnabled = prefs.notificationsGroupMentionsEnabled
            voiceNotesEnabled = prefs.notificationsVoiceNotesEnabled

            if let startUtc = prefs.quietHoursStartUtc,
               let endUtc = prefs.quietHoursEndUtc {
                quietHoursEnabled = true
                quietHoursStart = Self.localDate(fromUtcMinutes: startUtc)
                quietHoursEnd = Self.localDate(fromUtcMinutes: endUtc)
            } else {
                quietHoursEnabled = false
            }
            hasHydrated = true
        }
    }

    // MARK: Sections

    private var notificationTypesSection: some View {
        SettingsComponents.settingsGroup(
            title: NotificationsSettingsL10n.typesSection,
            icon: "bell.badge.fill",
            theme: theme
        ) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsToggleRow(
                    title: NotificationsSettingsL10n.dmsTitle,
                    subtitle: NotificationsSettingsL10n.dmsSubtitle,
                    isOn: Binding(
                        get: { dmsEnabled },
                        set: { newValue in
                            dmsEnabled = newValue
                            Task { await prefsService.updateDMsEnabled(newValue) }
                        }
                    ),
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: NotificationsSettingsL10n.friendRequestsTitle,
                    subtitle: NotificationsSettingsL10n.friendRequestsSubtitle,
                    isOn: Binding(
                        get: { friendRequestsEnabled },
                        set: { newValue in
                            friendRequestsEnabled = newValue
                            Task { await prefsService.updateFriendRequestsEnabled(newValue) }
                        }
                    ),
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: NotificationsSettingsL10n.groupMentionsTitle,
                    subtitle: NotificationsSettingsL10n.groupMentionsSubtitle,
                    isOn: Binding(
                        get: { groupMentionsEnabled },
                        set: { newValue in
                            groupMentionsEnabled = newValue
                            Task { await prefsService.updateGroupMentionsEnabled(newValue) }
                        }
                    ),
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: NotificationsSettingsL10n.voiceNotesTitle,
                    subtitle: NotificationsSettingsL10n.voiceNotesSubtitle,
                    isOn: Binding(
                        get: { voiceNotesEnabled },
                        set: { newValue in
                            voiceNotesEnabled = newValue
                            Task { await prefsService.updateVoiceNotesEnabled(newValue) }
                        }
                    ),
                    theme: theme
                )
            }
        }
    }

    private var quietHoursSection: some View {
        SettingsComponents.settingsGroup(
            title: NotificationsSettingsL10n.quietHoursSection,
            icon: "moon.zzz.fill",
            theme: theme
        ) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsToggleRow(
                    title: NotificationsSettingsL10n.quietHoursEnabled,
                    subtitle: NotificationsSettingsL10n.quietHoursEnabledSubtitle,
                    isOn: Binding(
                        get: { quietHoursEnabled },
                        set: { newValue in
                            quietHoursEnabled = newValue
                            pushQuietHours()
                        }
                    ),
                    theme: theme
                )

                if quietHoursEnabled {
                    DatePicker(
                        NotificationsSettingsL10n.quietHoursStart,
                        selection: Binding(
                            get: { quietHoursStart },
                            set: { newValue in
                                quietHoursStart = newValue
                                pushQuietHours()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .tint(.blipAccentPurple)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(NotificationsSettingsL10n.quietHoursStart)

                    DatePicker(
                        NotificationsSettingsL10n.quietHoursEnd,
                        selection: Binding(
                            get: { quietHoursEnd },
                            set: { newValue in
                                quietHoursEnd = newValue
                                pushQuietHours()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .tint(.blipAccentPurple)
                    .frame(minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(NotificationsSettingsL10n.quietHoursEnd)
                }
            }
        }
    }

    private var mutedChannelsSection: some View {
        SettingsComponents.settingsGroup(
            title: NotificationsSettingsL10n.mutedChannelsSection,
            icon: "speaker.slash.fill",
            theme: theme
        ) {
            let activeMutes = channelMutes.filter { $0.isActive }
            if activeMutes.isEmpty {
                emptyRow(text: NotificationsSettingsL10n.mutedChannelsEmpty)
            } else {
                VStack(spacing: BlipSpacing.sm) {
                    ForEach(activeMutes) { mute in
                        muteRow(
                            title: channelName(for: mute.channelID),
                            subtitle: untilCaption(mute.until),
                            onUnmute: {
                                Task { await prefsService.unmuteChannel(mute.channelID) }
                            }
                        )
                    }
                }
            }
        }
    }

    private var mutedFriendsSection: some View {
        SettingsComponents.settingsGroup(
            title: NotificationsSettingsL10n.mutedFriendsSection,
            icon: "person.crop.circle.badge.minus",
            theme: theme
        ) {
            let activeMutes = friendMutes.filter { $0.isActive }
            if activeMutes.isEmpty {
                emptyRow(text: NotificationsSettingsL10n.mutedFriendsEmpty)
            } else {
                VStack(spacing: BlipSpacing.sm) {
                    ForEach(activeMutes) { mute in
                        muteRow(
                            title: friendDisplayName(for: mute.peerIdHex),
                            subtitle: untilCaption(mute.until),
                            onUnmute: {
                                Task { await prefsService.unmuteFriend(peerIdHex: mute.peerIdHex) }
                            }
                        )
                    }
                }
            }
        }
    }

    private var sosFooter: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)

            Text(NotificationsSettingsL10n.sosFooter)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BlipSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    // MARK: Row helpers

    private func emptyRow(text: String) -> some View {
        Text(text)
            .font(theme.typography.caption)
            .foregroundStyle(theme.colors.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, BlipSpacing.xs)
    }

    private func muteRow(
        title: String,
        subtitle: String,
        onUnmute: @escaping () -> Void
    ) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                Text(title)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(1)

                Text(subtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }

            Spacer()

            Button(action: onUnmute) {
                Text(NotificationsSettingsL10n.unmute)
                    .font(theme.typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blipAccentPurple)
            }
            .buttonStyle(.plain)
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel("\(NotificationsSettingsL10n.unmute) \(title)")
        }
        .frame(minHeight: BlipSizing.minTapTarget)
    }

    // MARK: Lookups

    private func channelName(for channelID: UUID) -> String {
        if let match = channels.first(where: { $0.id == channelID }),
           let name = match.name, !name.isEmpty {
            return name
        }
        return channelID.uuidString.prefix(8).lowercased() + "…"
    }

    private func friendDisplayName(for peerIdHex: String) -> String {
        // We don't store peerIdHex directly on User/Friend yet — until that
        // lookup lands, show a redacted hex so the user can still identify
        // the mute without leaking the full identifier to accessibility tools.
        _ = friends // silence unused warning; wiring ready for the lookup.
        return DebugLogger.redactHex(peerIdHex)
    }

    private func untilCaption(_ until: Date?) -> String {
        guard let until else { return NotificationsSettingsL10n.indefiniteCaption }
        return NotificationsSettingsL10n.untilCaption(
            Self.untilDateFormatter.string(from: until)
        )
    }

    // MARK: Quiet hours helpers

    private func pushQuietHours() {
        guard quietHoursEnabled else {
            Task { await prefsService.updateQuietHours(startUtc: nil, endUtc: nil) }
            return
        }
        let startUtc = Self.utcMinutes(from: quietHoursStart)
        let endUtc = Self.utcMinutes(from: quietHoursEnd)
        Task { await prefsService.updateQuietHours(startUtc: startUtc, endUtc: endUtc) }
    }

    /// Converts a local `Date` (we only care about its hour/minute) to a
    /// minute-of-day in UTC (0..<1440). This is what the server stores so
    /// two devices in different timezones can agree on the window.
    private static func utcMinutes(from localDate: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: localDate)
        let localMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let offsetMinutes = TimeZone.current.secondsFromGMT(for: localDate) / 60
        var utcMinutes = (localMinutes - offsetMinutes) % 1440
        if utcMinutes < 0 { utcMinutes += 1440 }
        return utcMinutes
    }

    /// Inverse of `utcMinutes(from:)` — builds a `Date` (today, in the
    /// user's local timezone) whose hour/minute represents the provided
    /// UTC minute-of-day in the user's current timezone.
    private static func localDate(fromUtcMinutes utcMinutes: Int) -> Date {
        let offsetMinutes = TimeZone.current.secondsFromGMT(for: Date()) / 60
        var localMinutes = (utcMinutes + offsetMinutes) % 1440
        if localMinutes < 0 { localMinutes += 1440 }
        let hour = localMinutes / 60
        let minute = localMinutes % 60
        return Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()
    }
}

// MARK: - Preview

@MainActor
private let previewContainer: ModelContainer = {
    // Force-try is scoped to #Preview builds only; preview failure should be
    // visible immediately rather than silently show an empty view.
    do {
        return try BlipSchema.createPreviewContainer()
    } catch {
        fatalError("Preview container failed: \(error)")
    }
}()

#Preview("Notifications Settings") {
    NavigationStack {
        NotificationsSettingsView()
    }
    .modelContainer(previewContainer)
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Notifications Settings - Light") {
    NavigationStack {
        NotificationsSettingsView()
    }
    .modelContainer(previewContainer)
    .preferredColorScheme(.light)
    .blipTheme()
}
