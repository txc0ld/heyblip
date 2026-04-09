import SwiftUI

// MARK: - SettingsComponents

/// Shared helper views used across all settings sub-sections.
@MainActor
enum SettingsComponents {

    /// A glass-backed group with a title bar (icon + label) and custom content.
    static func settingsGroup<Content: View>(
        title: String,
        icon: String,
        theme: Theme,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
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

    /// A horizontal row with a leading title and trailing content.
    static func settingsRow<Content: View>(
        title: String,
        theme: Theme,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)

            Spacer()

            trailing()
        }
        .frame(minHeight: BlipSizing.minTapTarget)
    }

    /// A toggle row with a title, subtitle, and binding.
    static func settingsToggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        theme: Theme
    ) -> some View {
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
        .accessibilityLabel(title)
    }

    /// An info row showing a label and its value.
    static func settingsInfoRow(
        title: String,
        value: String,
        theme: Theme
    ) -> some View {
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

    /// A small "Coming Soon" subheader used to group unavailable actions
    /// below working ones. Reduces visual weight on stubs so working
    /// features stand out.
    static func comingSoonHeader(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Divider()
                .opacity(0.15)

            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .medium))
                Text("COMING SOON")
                    .font(theme.typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.8)
            }
            .foregroundStyle(theme.colors.mutedText.opacity(0.7))
        }
        .padding(.top, BlipSpacing.xs)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Coming soon")
    }

    /// A non-interactive, de-emphasized row for unavailable actions.
    /// Uses caption-size title + muted text to drop visual weight below
    /// working rows. Preserves the label and a short subtitle so users
    /// can still see what's planned.
    static func settingsDisabledRow(
        title: String,
        subtitle: String,
        icon: String,
        theme: Theme,
        isDestructive: Bool = false
    ) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(
                        isDestructive
                            ? BlipColors.darkColors.statusRed.opacity(0.55)
                            : theme.colors.mutedText
                    )

                Text(subtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.65))
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.colors.mutedText.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

// MARK: - Preview

#Preview("Settings Components") {
    ZStack {
        GradientBackground()

        VStack(spacing: BlipSpacing.md) {
            SettingsComponents.settingsGroup(
                title: "Example",
                icon: "star.fill",
                theme: .shared
            ) {
                SettingsComponents.settingsInfoRow(
                    title: "Key",
                    value: "Value",
                    theme: .shared
                )
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
