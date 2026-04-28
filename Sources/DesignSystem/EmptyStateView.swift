import SwiftUI

// MARK: - EmptyStateView

/// Reusable empty state with icon, title, subtitle, and optional CTA.
/// Centered, muted styling with personality.
///
/// Two scales:
/// - `.fullScreen` (default): 48pt icon, headline title, fills available
///   height. Use for tab-root empty states (no chats yet, no events found,
///   no friends yet) or full-sheet empty states.
/// - `.inline`: 32pt icon, body title, intrinsic height. Use for empty
///   states inside a `GlassCard`, section, or any container where the
///   surrounding layout shouldn't be pushed apart.
struct EmptyStateView: View {

    /// Visual scale for the empty state.
    enum Style: Sendable {
        case fullScreen
        case inline
    }

    let icon: String
    let title: String
    let subtitle: String
    let ctaTitle: String?
    let ctaAction: (() -> Void)?
    let style: Style

    @Environment(\.theme) private var theme

    init(
        icon: String,
        title: String,
        subtitle: String,
        ctaTitle: String? = nil,
        ctaAction: (() -> Void)? = nil,
        style: Style = .fullScreen
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.ctaTitle = ctaTitle
        self.ctaAction = ctaAction
        self.style = style
    }

    var body: some View {
        VStack(spacing: style == .fullScreen ? BlipSpacing.md : BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: style == .fullScreen ? 48 : 32))
                .foregroundStyle(theme.colors.mutedText)

            Text(title)
                .font(style == .fullScreen ? theme.typography.headline : theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .multilineTextAlignment(.center)

            // Skip the Text node entirely when subtitle is empty — section
            // empty states (FriendsListView per-section copy) only have a
            // title and would otherwise render a phantom blank line of
            // typography metrics.
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BlipSpacing.xl)
            }

            if let ctaTitle, let ctaAction {
                GlassButton(ctaTitle, style: .secondary, size: .small, action: ctaAction)
                    .padding(.top, BlipSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: style == .fullScreen ? .infinity : nil)
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
                    .font(theme.typography.title1)
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

#Preview("Empty - Chat List (full screen)") {
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
    .blipTheme()
}

#Preview("Empty - Chat List (light)") {
    ZStack {
        GradientBackground()
        EmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: "No conversations yet",
            subtitle: "Find people nearby to start chatting",
            ctaTitle: "Go to Nearby"
        ) {}
    }
    .preferredColorScheme(.light)
    .blipTheme()
}

#Preview("Empty - Inline (in GlassCard)") {
    ZStack {
        GradientBackground()
        VStack {
            GlassCard(thickness: .ultraThin) {
                EmptyStateView(
                    icon: "music.note",
                    title: "No acts scheduled",
                    subtitle: "Check back closer to gates open",
                    style: .inline
                )
                .padding(.vertical, BlipSpacing.lg)
            }
            .padding(BlipSpacing.md)
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Empty - Section title only") {
    ZStack {
        GradientBackground()
        EmptyStateView(
            icon: "wifi.slash",
            title: "No friends online right now",
            subtitle: ""
        )
    }
    .preferredColorScheme(.dark)
    .blipTheme()
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
    .blipTheme()
}
