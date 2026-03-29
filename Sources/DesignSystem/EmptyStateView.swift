import SwiftUI

// MARK: - EmptyStateView

/// Reusable empty state with icon, title, subtitle, and optional CTA.
/// Centered, muted styling with personality.
struct EmptyStateView: View {

    let icon: String
    let title: String
    let subtitle: String
    let ctaTitle: String?
    let ctaAction: (() -> Void)?

    @Environment(\.theme) private var theme

    init(
        icon: String,
        title: String,
        subtitle: String,
        ctaTitle: String? = nil,
        ctaAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.ctaTitle = ctaTitle
        self.ctaAction = ctaAction
    }

    var body: some View {
        VStack(spacing: BlipSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)

            Text(title)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(subtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BlipSpacing.xl)

            if let ctaTitle, let ctaAction {
                GlassButton(ctaTitle, style: .secondary, size: .small, action: ctaAction)
                    .padding(.top, BlipSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ErrorStateView

/// Reusable error state with amber warning icon and retry button.
/// Calm glass card — never red banner, never alarming.
struct ErrorStateView: View {

    let title: String
    let subtitle: String
    let retryAction: (() -> Void)?

    @Environment(\.theme) private var theme

    init(
        title: String = "Something went wrong",
        subtitle: String = "Pull down to retry",
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.retryAction = retryAction
    }

    var body: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(BlipColors.adaptive.statusAmber)

                Text(title)
                    .font(theme.typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                Text(subtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)

                if let retryAction {
                    GlassButton("Try Again", icon: "arrow.clockwise", style: .secondary, size: .small, action: retryAction)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview("Empty - Chat List") {
    ZStack {
        GradientBackground()
        EmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: "No conversations yet",
            subtitle: "Find people nearby to start chatting",
            ctaTitle: "Go to Nearby"
        ) {}
    }
    .preferredColorScheme(.dark)
    .festiChatTheme()
}

#Preview("Empty - Nearby") {
    ZStack {
        GradientBackground()
        EmptyStateView(
            icon: "antenna.radiowaves.left.and.right",
            title: "Scanning for people...",
            subtitle: "Make sure Bluetooth is on",
            ctaTitle: "Open Settings"
        ) {}
    }
    .preferredColorScheme(.dark)
    .festiChatTheme()
}

#Preview("Error State") {
    ZStack {
        GradientBackground()
        VStack {
            Spacer()
            ErrorStateView(
                title: "Connection lost",
                subtitle: "Check your Bluetooth settings"
            ) {}
            .padding(BlipSpacing.md)
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
    .festiChatTheme()
}
