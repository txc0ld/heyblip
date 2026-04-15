import SwiftUI

private enum AboutSettingsL10n {
    static let title = String(localized: "settings.about.title", defaultValue: "About")
    static let version = String(localized: "settings.about.version", defaultValue: "Version")
    static let build = String(localized: "settings.about.build", defaultValue: "Build")
    static let commit = String(localized: "settings.about.commit", defaultValue: "Commit")
    static let copied = String(localized: "common.copied", defaultValue: "Copied!")
    static let branch = String(localized: "settings.about.branch", defaultValue: "Branch")
    static let built = String(localized: "settings.about.built", defaultValue: "Built")
    static let privacyPolicy = String(localized: "settings.about.privacy_policy", defaultValue: "Privacy Policy")
    static let legalUnavailable = String(localized: "settings.about.legal_unavailable", defaultValue: "Unavailable until hosted legal pages are published")
    static let termsOfService = String(localized: "settings.about.terms", defaultValue: "Terms of Service")
    static let openSourceLicenses = String(localized: "settings.about.open_source", defaultValue: "Open Source Licenses")
    static let acknowledgementsUnavailable = String(localized: "settings.about.open_source_unavailable", defaultValue: "Unavailable until the in-app acknowledgements screen is wired")
}

// MARK: - AboutSettings

/// Version, build, commit info, and legal links section.
struct AboutSettings: View {

    @State private var buildStringCopied = false

    @Environment(\.theme) private var theme

    var body: some View {
        SettingsComponents.settingsGroup(title: AboutSettingsL10n.title, icon: "info.circle.fill", theme: theme) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                SettingsComponents.settingsInfoRow(title: AboutSettingsL10n.version, value: BuildInfo.version, theme: theme)
                SettingsComponents.settingsInfoRow(title: AboutSettingsL10n.build, value: BuildInfo.buildNumber, theme: theme)

                SettingsComponents.settingsInfoRow(title: AboutSettingsL10n.commit, value: BuildInfo.gitHash, theme: theme)
                    .onTapGesture {
                        UIPasteboard.general.string = BuildInfo.fullBuildString
                        buildStringCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { buildStringCopied = false }
                    }
                    .overlay(alignment: .trailing) {
                        if buildStringCopied {
                            Text(AboutSettingsL10n.copied)
                                .font(theme.typography.caption)
                                .foregroundStyle(.blipAccentPurple)
                                .transition(.opacity)
                        }
                    }
                    .animation(SpringConstants.gentleAnimation, value: buildStringCopied)

                SettingsComponents.settingsInfoRow(title: AboutSettingsL10n.branch, value: BuildInfo.gitBranch, theme: theme)
                SettingsComponents.settingsInfoRow(title: AboutSettingsL10n.built, value: BuildInfo.buildDate, theme: theme)

                // Legal links grouped under a de-emphasized heading below the
                // working build info. TODO: BDEV-136 — wire to hosted legal
                // pages and acknowledgements screen.
                SettingsComponents.comingSoonHeader(theme: theme)

                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    SettingsComponents.settingsDisabledRow(
                        title: AboutSettingsL10n.privacyPolicy,
                        subtitle: AboutSettingsL10n.legalUnavailable,
                        icon: "arrow.up.right",
                        theme: theme
                    )

                    SettingsComponents.settingsDisabledRow(
                        title: AboutSettingsL10n.termsOfService,
                        subtitle: AboutSettingsL10n.legalUnavailable,
                        icon: "arrow.up.right",
                        theme: theme
                    )

                    SettingsComponents.settingsDisabledRow(
                        title: AboutSettingsL10n.openSourceLicenses,
                        subtitle: AboutSettingsL10n.acknowledgementsUnavailable,
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
