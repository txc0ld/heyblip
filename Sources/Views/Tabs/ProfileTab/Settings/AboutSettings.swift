import SwiftUI

// MARK: - AboutSettings

/// Version, build, commit info, and legal links section.
struct AboutSettings: View {

    @State private var buildStringCopied = false

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: "About", icon: "info.circle.fill", theme: theme) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
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

                // Legal links grouped under a de-emphasized heading below the
                // working build info. TODO: BDEV-136 — wire to hosted legal
                // pages and acknowledgements screen.
                SettingsComponents.comingSoonHeader(theme: theme)

                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    SettingsComponents.settingsDisabledRow(
                        title: "Privacy Policy",
                        subtitle: "Unavailable until hosted legal pages are published",
                        icon: "arrow.up.right",
                        theme: theme
                    )

                    SettingsComponents.settingsDisabledRow(
                        title: "Terms of Service",
                        subtitle: "Unavailable until hosted legal pages are published",
                        icon: "arrow.up.right",
                        theme: theme
                    )

                    SettingsComponents.settingsDisabledRow(
                        title: "Open Source Licenses",
                        subtitle: "Unavailable until the in-app acknowledgements screen is wired",
                        icon: "arrow.up.right",
                        theme: theme
                    )
                }
            }
        }
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
