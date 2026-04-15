import SwiftUI

private enum RegistrationBannerL10n {
    static let message = String(localized: "common.registration_banner.message", defaultValue: "Account not synced to server")
    static let retryButton = String(localized: "common.registration_banner.retry", defaultValue: "Retry")
    static let retryHint = String(localized: "common.registration_banner.retry_hint", defaultValue: "Retry server registration")
    static let retrying = String(localized: "common.registration_banner.retrying", defaultValue: "Syncing...")
}

// MARK: - RegistrationBanner

/// Persistent glass capsule banner shown when the local profile has not been
/// confirmed on the auth server. Includes a retry button that triggers
/// `AppCoordinator.retryRegistration()`.
struct RegistrationBanner: View {

    let coordinator: AppCoordinator

    @State private var isRetrying = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.blipWarmCoral)

            Text(isRetrying ? RegistrationBannerL10n.retrying : RegistrationBannerL10n.message)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                .foregroundStyle(theme.colors.text)

            Spacer()

            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await coordinator.retryRegistration()
                    isRetrying = false
                }
            } label: {
                Text(RegistrationBannerL10n.retryButton)
                    .font(.custom(BlipFontName.semiBold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Color.blipAccentPurple)
            }
            .disabled(isRetrying)
            .accessibilityLabel(RegistrationBannerL10n.retryHint)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(
                    Color.blipWarmCoral.opacity(0.3),
                    lineWidth: BlipSizing.hairline
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .transition(
            SpringConstants.isReduceMotionEnabled
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                )
        )
    }
}

// MARK: - Preview

#Preview("Registration Banner") {
    ZStack {
        GradientBackground()
        VStack {
            RegistrationBanner(coordinator: AppCoordinator())
                .padding(.horizontal, BlipSpacing.md)
            Spacer()
        }
        .padding(.top, BlipSpacing.lg)
    }
    .environment(\.theme, Theme.shared)
}
