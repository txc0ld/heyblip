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
