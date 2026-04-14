import SwiftUI

private enum WelcomeStepL10n {
    static let title = String(localized: "onboarding.welcome.title", defaultValue: "Chat at events,\neven without signal.")
    static let subtitle = String(localized: "onboarding.welcome.subtitle", defaultValue: "HeyBlip uses Bluetooth to connect you with people nearby. No WiFi or cell signal needed.")
    static let continueButton = String(localized: "common.continue", defaultValue: "Continue")
    static let devBypass = String(localized: "onboarding.welcome.dev_bypass.title", defaultValue: "Dev Bypass")
    static let code = String(localized: "common.code", defaultValue: "Code")
    static let submit = String(localized: "common.submit", defaultValue: "Submit")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let bypassMessage = String(localized: "onboarding.welcome.dev_bypass.message", defaultValue: "Enter bypass code to skip onboarding")
}

// MARK: - WelcomeStep

/// Onboarding step 1: "Chat at events, even without signal."
/// Animated gradient hero with a continue button.
/// Long-press the hero illustration to enter the dev bypass code (000000).
struct WelcomeStep: View {

    /// Called when the user taps "Continue".
    var onContinue: () -> Void = {}

    /// Called when the user enters the correct bypass code (skips all onboarding).
    var onBypass: () -> Void = {}

    @State private var heroVisible = false
    @State private var textVisible = false
    @State private var buttonVisible = false
    @State private var showBypass = false
    @State private var bypassCode = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero illustration — long-press for dev bypass
            heroSection
                .opacity(heroVisible ? 1.0 : 0.0)
                .offset(y: heroVisible ? 0 : 20)
                .onLongPressGesture(minimumDuration: 1.0) {
                    showBypass = true
                }

            Spacer()
                .frame(height: BlipSpacing.xxl)

            // Text content
            VStack(spacing: BlipSpacing.md) {
                Text(WelcomeStepL10n.title)
                    .font(theme.typography.largeTitle)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(WelcomeStepL10n.subtitle)
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
            GlassButton(WelcomeStepL10n.continueButton, icon: "arrow.right") {
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
        .alert(WelcomeStepL10n.devBypass, isPresented: $showBypass) {
            TextField(WelcomeStepL10n.code, text: $bypassCode)
                .keyboardType(.numberPad)
            Button(WelcomeStepL10n.submit) {
                if bypassCode == "000000" {
                    bypassCode = ""
                    onBypass()
                }
                bypassCode = ""
            }
            Button(WelcomeStepL10n.cancel, role: .cancel) { bypassCode = "" }
        } message: {
            Text(WelcomeStepL10n.bypassMessage)
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
