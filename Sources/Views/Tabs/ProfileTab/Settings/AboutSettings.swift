import SwiftUI

// MARK: - AboutSettings

/// Version, build, commit info, and legal links section.
struct AboutSettings: View {

    @State private var buildStringCopied = false

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "About", icon: "info.circle.fill", theme: theme) {
            VStack(spacing: BlipSpacing.md) {
                SettingsComponents.settingsInfoRow(title: "Version", value: BuildInfo.version, theme: theme)
                SettingsComponents.settingsInfoRow(title: "Build", value: BuildInfo.buildNumber, theme: theme)

                SettingsComponents.settingsInfoRow(title: "Commit", value: BuildInfo.gitHash, theme: theme)
                    .onTapGesture {
                        UIPasteboard.general.string = BuildInfo.fullBuildString
                        buildStringCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { buildStringCopied = false }
                    }
                    .overlay(alignment: .trailing) {
                        if buildStringCopied {
                            Text("Copied!")
                                .font(theme.typography.caption)
                                .foregroundStyle(.blipAccentPurple)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: buildStringCopied)

                SettingsComponents.settingsInfoRow(title: "Branch", value: BuildInfo.gitBranch, theme: theme)
                SettingsComponents.settingsInfoRow(title: "Built", value: BuildInfo.buildDate, theme: theme)

                disabledLinkRow(title: "Privacy Policy", subtitle: "Unavailable until hosted legal pages are published")
                disabledLinkRow(title: "Terms of Service", subtitle: "Unavailable until hosted legal pages are published")
                disabledLinkRow(title: "Open Source Licenses", subtitle: "Unavailable until the in-app acknowledgements screen is wired")
            }
        }
    }

    // MARK: - Private

    private func disabledLinkRow(title: String, subtitle: String) -> some View {
        Button(action: {}) {
            HStack {
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(title)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)

                    Text(subtitle)
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
        .accessibilityLabel("\(title) unavailable in this build")
    }
}

// MARK: - Preview

#Preview("About Settings") {
    ZStack {
        GradientBackground()

        AboutSettings()
            .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
