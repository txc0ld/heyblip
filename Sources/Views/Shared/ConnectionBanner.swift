import SwiftUI

private enum ConnectionBannerL10n {
    static let previewShowBanner = "Show Banner"

    static func bannerText(peerCount: Int) -> String {
        if peerCount == 1 {
            return String(localized: "common.connection_banner.single", defaultValue: "Connected to 1 person nearby")
        }
        return String(
            format: String(localized: "common.connection_banner.multiple", defaultValue: "Connected to %d people nearby"),
            locale: Locale.current,
            peerCount
        )
    }
}

// MARK: - ConnectionBanner

/// Glass capsule banner showing "Connected to X people nearby".
/// Slides down from the top on mesh connection, auto-dismisses after 3 seconds.
struct ConnectionBanner: View {

    /// Number of connected peers to display.
    let peerCount: Int

    /// Whether the banner is currently visible.
    @Binding var isVisible: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    /// Auto-dismiss duration in seconds.
    private let dismissDelay: TimeInterval = 3.0

    var body: some View {
        if isVisible {
            bannerContent
                .transition(bannerTransition)
                .task {
                    do {
                        try await Task.sleep(for: .seconds(dismissDelay))
                    } catch {
                        return
                    }
                    withAnimation(SpringConstants.accessiblePageEntrance) {
                        isVisible = false
                    }
                }
        }
    }

    // MARK: - Content

    private var bannerContent: some View {
        HStack(spacing: BlipSpacing.sm) {
            // Mesh health indicator with breathing ring
            BreathingRing(
                ringCount: min(max(peerCount / 3, 1), 5),
                baseSize: 12,
                color: statusColor,
                cycleDuration: 3.0,
                ringSpacing: 0.3
            )
            .frame(width: 16, height: 16)

            Text(bannerText)
                .font(.custom(BlipFontName.medium, size: 14, relativeTo: .footnote))
                .foregroundStyle(theme.colors.text)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm + 2)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.15)
                        : Color.black.opacity(0.1),
                    lineWidth: BlipSizing.hairline
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    /// Connected: mint. Disconnected/reconnecting: warmCoral.
    private var statusColor: Color {
        peerCount > 0 ? Color.blipMint : Color.blipWarmCoral
    }

    // MARK: - Helpers

    private var bannerText: String {
        ConnectionBannerL10n.bannerText(peerCount: peerCount)
    }

    private var bannerTransition: AnyTransition {
        if SpringConstants.isReduceMotionEnabled {
            return .opacity
        } else {
            return .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        }
    }

}

// MARK: - ConnectionBanner Modifier

/// Attaches a connection banner overlay to a view.
struct ConnectionBannerModifier: ViewModifier {
    let peerCount: Int
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ConnectionBanner(peerCount: peerCount, isVisible: $isVisible)
                    .padding(.top, BlipSpacing.sm)
            }
    }
}

extension View {
    /// Shows a connection banner overlay.
    func connectionBanner(peerCount: Int, isVisible: Binding<Bool>) -> some View {
        modifier(ConnectionBannerModifier(peerCount: peerCount, isVisible: isVisible))
    }
}

// MARK: - Preview

#Preview("Connection Banner") {
    struct BannerPreview: View {
        @State private var isVisible = true
        var body: some View {
            ZStack {
                GradientBackground()
                VStack {
                    ConnectionBanner(peerCount: 12, isVisible: $isVisible)
                    Spacer()
                    GlassButton(ConnectionBannerL10n.previewShowBanner) {
                        withAnimation(SpringConstants.accessiblePageEntrance) {
                            isVisible = true
                        }
                    }
                }
                .padding()
            }
            .environment(\.theme, Theme.shared)
        }
    }
    return BannerPreview()
}
