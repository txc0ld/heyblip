import SwiftUI

private enum SplashViewL10n {
    static let tagline = String(localized: "launch.splash.tagline", defaultValue: "Chat at events, even without signal.")
}

// MARK: - SplashView

/// Animated logo reveal with accent purple gradient.
/// Fades to onboarding or main view after the animation completes.
struct SplashView: View {

    @State private var logoOpacity: Double = 0.0
    @State private var logoScale: CGFloat = 0.8
    @State private var taglineOpacity: Double = 0.0

    /// Called when the splash animation completes.
    var onComplete: () -> Void = {}

    @Environment(\.theme) private var theme

    /// Total duration before transitioning (animation + hold).
    private let totalDuration: Double = 2.2

    var body: some View {
        ZStack {
            GradientBackground()
                .ignoresSafeArea()

            VStack(spacing: BlipSpacing.lg) {
                // Blip splash logo
                Image("BlipSplash")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                // Tagline
                Text(SplashViewL10n.tagline)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .opacity(taglineOpacity)
            }
        }
        .onAppear {
            startAnimation()
        }
        .task {
            do {
                try await Task.sleep(for: .seconds(totalDuration))
            } catch {
                return
            }
            onComplete()
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        if SpringConstants.isReduceMotionEnabled {
            // Reduced motion: simple fade
            withAnimation(.easeIn(duration: 0.4)) {
                logoOpacity = 1.0
                logoScale = 1.0
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.3)) {
                taglineOpacity = 1.0
            }
        } else {
            // Full motion: spring scale + fade
            withAnimation(SpringConstants.pageEntranceAnimation) {
                logoOpacity = 1.0
                logoScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.4)) {
                taglineOpacity = 1.0
            }
        }
    }
}

// MARK: - Preview

#Preview("Splash View") {
    SplashView()
        .environment(\.theme, Theme.shared)
}

#Preview("Splash View - Light") {
    SplashView()
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}
