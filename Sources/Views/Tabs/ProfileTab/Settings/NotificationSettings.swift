import SwiftUI

// MARK: - NotificationSettings

/// Push notifications and auto-join channels section.
struct NotificationSettings: View {

    @Binding var pushNotifications: Bool
    @Binding var autoJoinChannels: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Notifications", icon: "bell.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsToggleRow(
                    title: "Push Notifications",
                    subtitle: "Receive notifications for messages",
                    isOn: $pushNotifications,
                    theme: theme
                )

                SettingsComponents.settingsToggleRow(
                    title: "Auto-Join Channels",
                    subtitle: "Automatically join nearby location channels",
                    isOn: $autoJoinChannels,
                    theme: theme
                )
            }
        }
    }
}

// MARK: - Preview

#Preview("Notification Settings") {
    ZStack {
        GradientBackground()

        NotificationSettings(
            pushNotifications: .constant(true),
            autoJoinChannels: .constant(true)
        )
        .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
