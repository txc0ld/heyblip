import SwiftUI

// MARK: - ChatSettings

/// Push-to-talk mode picker section.
struct ChatSettings: View {

    @Binding var pttMode: String

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "Chat", icon: "message.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsRow(title: "Push-to-Talk Mode", theme: theme) {
                    Picker("PTT Mode", selection: $pttMode) {
                        Text("Hold").tag(PTTMode.holdToTalk.rawValue)
                        Text("Toggle").tag(PTTMode.toggleTalk.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Push-to-Talk mode")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Chat Settings") {
    ZStack {
        GradientBackground()

        ChatSettings(pttMode: .constant(PTTMode.holdToTalk.rawValue))
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
