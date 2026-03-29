import SwiftUI

// MARK: - WelcomeStep

/// Onboarding step 1: "Chat at festivals, even without signal."
/// Animated gradient hero with a continue button.
struct WelcomeStep: View {

    /// Called when the user taps "Continue".
    var onContinue: () -> Void = {}

    @State private var heroVisible = false
    @State private var textVisible = false
    @State private var buttonVisible = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero illustration
            heroSection
                .opacity(heroVisible ? 1.0 : 0.0)
                .offset(y: heroVisible ? 0 : 20)

            Spacer()
                .frame(height: BlipSpacing.xxl)

            // Text content
            VStack(spacing: BlipSpacing.md) {
                Text("Chat at festivals,\neven without signal.")
                    .font(theme.typography.largeTitle)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Blip uses Bluetooth to connect you with people nearby. No WiFi or cell signal needed.")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(textVisible ? 1.0 : 0.0)
            .offset(y: textVisible ? 0 : 15)
            .padding(.horizontal, BlipSpacing.xl)

            Spacer()

            // Continue button
            GlassButton("Continue", icon: "arrow.right") {
                onContinue()
            }
            .fullWidth()
            .opacity(buttonVisible ? 1.0 : 0.0)
            .offset(y: buttonVisible ? 0 : 10)
            .padding(.horizontal, BlipSpacing.lg)
            .padding(.bottom, BlipSpacing.xl)
        }
        .onAppear {
            animateEntrance()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack {
            // Gradient orb background
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.blipAccentPurple.opacity(0.25),
                            Color.blipAccentPurple.opacity(0.05),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)

            // Central icon cluster
            VStack(spacing: BlipSpacing.md) {
                ZStack {
                    // Mesh connection lines (decorative)
                    ForEach(0..<3, id: \.self) { index in
                        let angle = Angle.degrees(Double(index) * 120 - 60)
                        let radius: CGFloat = 50
                        Circle()
                            .fill(Color.blipAccentPurple.opacity(0.5))
                            .frame(width: 12, height: 12)
                            .offset(
                                x: cos(angle.radians) * radius,
                                y: sin(angle.radians) * radius
                            )
                    }

                    // Central chat bubble
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 48, weight: .medium))
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
            }
        }
    }

    // MARK: - Animation

    private func animateEntrance() {
        let animation = SpringConstants.isReduceMotionEnabled
            ? Animation.easeIn(duration: 0.3)
            : SpringConstants.pageEntranceAnimation

        withAnimation(animation) {
            heroVisible = true
        }
        withAnimation(animation.delay(0.1)) {
            textVisible = true
        }
        withAnimation(animation.delay(0.2)) {
            buttonVisible = true
        }
    }
}

// MARK: - Preview

#Preview("Welcome Step") {
    ZStack {
        GradientBackground()
            .ignoresSafeArea()
        WelcomeStep()
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Welcome Step - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        WelcomeStep()
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}
