import SwiftUI

// MARK: - PulseGlow

/// A breathing glow animation for active/recording states.
/// Displays a sinusoidal opacity oscillation on an accent-colored circle.
/// Respects Reduce Motion by falling back to a static 0.5 opacity circle.
struct PulseGlow: View {

    // MARK: - Configuration

    /// The glow color. Defaults to accent purple.
    private let color: Color

    /// The diameter of the glow circle.
    private let size: CGFloat

    /// Duration for one full breathing cycle in seconds.
    private let cycleDuration: Double

    // MARK: - State

    @State private var phase: Double = 0

    // MARK: - Reduce Motion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    init(
        color: Color = Color("AccentPurple"),
        size: CGFloat = 60,
        cycleDuration: Double = 2.0
    ) {
        self.color = color
        self.size = size
        self.cycleDuration = cycleDuration
    }

    // MARK: - Body

    var body: some View {
        if reduceMotion {
            staticGlow
        } else {
            animatedGlow
        }
    }

    // MARK: - Subviews

    private var staticGlow: some View {
        Circle()
            .fill(color.opacity(0.5))
            .frame(width: size, height: size)
    }

    private var animatedGlow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let normalizedPhase = elapsed / cycleDuration
            // Sinusoidal oscillation: maps to 0.3 → 0.8 → 0.3
            let sineValue = sin(normalizedPhase * .pi * 2)
            let opacity = 0.55 + 0.25 * sineValue

            Circle()
                .fill(color.opacity(opacity))
                .frame(width: size, height: size)
                .blur(radius: size * 0.15)
        }
    }
}

// MARK: - Preview

#Preview("Pulse Glow") {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 40) {
            PulseGlow(color: Color("AccentPurple"), size: 80)
            PulseGlow(color: .cyan, size: 50, cycleDuration: 3.0)
            PulseGlow(color: .red, size: 40, cycleDuration: 1.5)
        }
    }
    .preferredColorScheme(.dark)
}
