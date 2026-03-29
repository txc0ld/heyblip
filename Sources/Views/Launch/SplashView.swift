import SwiftUI

// MARK: - SplashView

/// Animated logo reveal with accent purple gradient.
/// Fades to onboarding or main view after the animation completes.
struct SplashView: View {

    @State private var logoOpacity: Double = 0.0
    @State private var logoScale: CGFloat = 0.8
    @State private var taglineOpacity: Double = 0.0
    @State private var isFinished = false

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
                // Logo icon with accent gradient
                ZStack {
                    // Glow behind logo
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.blipAccentPurple.opacity(0.3),
                                    Color.blipAccentPurple.opacity(0.0)
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)
                        .opacity(logoOpacity)

                    // Logo symbol
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.blipAccentPurple,
                                    Color(red: 0.55, green: 0.15, blue: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // App name
                Text("Blip")
                    .font(.custom(BlipFontName.bold, size: 38, relativeTo: .largeTitle))
                    .foregroundStyle(theme.colors.text)
                    .opacity(logoOpacity)
                    .scaleEffect(logoScale)

                // Tagline
                Text("Chat at festivals, even without signal.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .opacity(taglineOpacity)
            }
        }
        .onAppear {
            startAnimation()
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

        // Transition after hold
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) {
            isFinished = true
            onComplete()
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
