import SwiftUI

// MARK: - TypingIndicator

/// Three glass dots with sequential scale pulse animation.
/// 0.4s duration per dot, 0.15s offset between dots.
struct TypingIndicator: View {

    @State private var animatingDot0 = false
    @State private var animatingDot1 = false
    @State private var animatingDot2 = false

    @Environment(\.colorScheme) private var colorScheme

    /// Dot diameter.
    private let dotSize: CGFloat = 8

    /// Spacing between dots.
    private let dotSpacing: CGFloat = 4

    /// Duration of one pulse cycle per dot.
    private let pulseDuration: Double = 0.4

    /// Delay offset between each dot.
    private let dotOffset: Double = 0.15

    var body: some View {
        HStack(spacing: dotSpacing) {
            dot(isAnimating: animatingDot0)
            dot(isAnimating: animatingDot1)
            dot(isAnimating: animatingDot2)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm + 2)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.1)
                        : Color.black.opacity(0.06),
                    lineWidth: BlipSizing.hairline
                )
        )
        .onAppear {
            startAnimation()
        }
        .accessibilityLabel("Someone is typing")
    }

    // MARK: - Dot

    private func dot(isAnimating: Bool) -> some View {
        Circle()
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(0.4)
                    : Color.black.opacity(0.3)
            )
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(isAnimating ? 1.3 : 0.7)
            .opacity(isAnimating ? 1.0 : 0.4)
    }

    // MARK: - Background

    @ViewBuilder
    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
            .fill(.ultraThinMaterial)
    }

    // MARK: - Animation

    private func startAnimation() {
        guard !SpringConstants.isReduceMotionEnabled else {
            // Reduced motion: static dots at medium opacity
            animatingDot0 = true
            animatingDot1 = true
            animatingDot2 = true
            return
        }

        // Sequential pulse with offset
        withAnimation(
            .easeInOut(duration: pulseDuration)
            .repeatForever(autoreverses: true)
        ) {
            animatingDot0 = true
        }

        withAnimation(
            .easeInOut(duration: pulseDuration)
            .repeatForever(autoreverses: true)
            .delay(dotOffset)
        ) {
            animatingDot1 = true
        }

        withAnimation(
            .easeInOut(duration: pulseDuration)
            .repeatForever(autoreverses: true)
            .delay(dotOffset * 2)
        ) {
            animatingDot2 = true
        }
    }
}

// MARK: - Preview

#Preview("Typing Indicator") {
    ZStack {
        GradientBackground()

        VStack(spacing: 20) {
            // In context: left-aligned like incoming message
            HStack {
                AvatarView(name: "Alice", size: 32, ringStyle: .friend)
                TypingIndicator()
                Spacer()
            }
            .padding(.horizontal)
        }
    }
    .environment(\.theme, Theme.shared)
}

#Preview("Typing Indicator - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        HStack {
            TypingIndicator()
            Spacer()
        }
        .padding()
    }
    .preferredColorScheme(.light)
    .environment(\.theme, Theme.resolved(for: .light))
}
