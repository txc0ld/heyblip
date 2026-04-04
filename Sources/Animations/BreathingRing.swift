import SwiftUI

// MARK: - BreathingRing

/// Concentric rings that expand and contract like breathing.
/// Ring count indicates mesh health (more rings = stronger connectivity).
/// Uses Canvas + TimelineView for performance.
/// Respects Reduce Motion by rendering static rings.
struct BreathingRing: View {

    // MARK: - Configuration

    /// Number of concentric rings to display (1-5). Indicates mesh strength.
    private let ringCount: Int

    /// Base diameter for the innermost ring.
    private let baseSize: CGFloat

    /// Ring color. Defaults to accent purple.
    private let color: Color

    /// Duration of one full breathing cycle in seconds.
    private let cycleDuration: Double

    /// Spacing between rings as a fraction of baseSize.
    private let ringSpacing: CGFloat

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    init(
        ringCount: Int = 3,
        baseSize: CGFloat = 40,
        color: Color = Color("AccentPurple"),
        cycleDuration: Double = 3.0,
        ringSpacing: CGFloat = 0.35
    ) {
        self.ringCount = max(1, min(ringCount, 5))
        self.baseSize = baseSize
        self.color = color
        self.cycleDuration = cycleDuration
        self.ringSpacing = ringSpacing
    }

    // MARK: - Body

    var body: some View {
        if reduceMotion {
            staticRings
        } else {
            animatedRings
        }
    }

    // MARK: - Static Rings (Reduce Motion)

    private var staticRings: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            drawRings(in: &context, center: center, breathScale: 1.0)
        }
        .frame(width: totalSize, height: totalSize)
    }

    // MARK: - Animated Rings

    private var animatedRings: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let normalizedPhase = elapsed / cycleDuration
            // Breathing: scale oscillates between 0.85 and 1.15
            let breathScale = 1.0 + 0.15 * sin(normalizedPhase * .pi * 2)

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                drawRings(in: &context, center: center, breathScale: breathScale)
            }
        }
        .frame(width: totalSize, height: totalSize)
    }

    // MARK: - Drawing

    private func drawRings(
        in context: inout GraphicsContext,
        center: CGPoint,
        breathScale: Double
    ) {
        for index in (0..<ringCount).reversed() {
            let ringIndex = CGFloat(index)
            let radius = (baseSize / 2 + ringIndex * baseSize * ringSpacing) * breathScale
            let opacity = opacityForRing(at: index)
            let lineWidth: CGFloat = index == 0 ? 2.0 : 1.5

            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color.opacity(opacity)),
                lineWidth: lineWidth
            )
        }
    }

    /// Outer rings get progressively more transparent.
    private func opacityForRing(at index: Int) -> Double {
        let maxOpacity = 0.8
        let minOpacity = 0.15
        guard ringCount > 1 else { return maxOpacity }
        let fraction = Double(index) / Double(ringCount - 1)
        return maxOpacity - fraction * (maxOpacity - minOpacity)
    }

    /// Total frame size accounting for all rings.
    private var totalSize: CGFloat {
        baseSize + CGFloat(ringCount - 1) * baseSize * ringSpacing * 2 + baseSize * 0.3
    }
}

// MARK: - Preview

#Preview("Breathing Ring") {
    ZStack {
        Color.black.ignoresSafeArea()

        HStack(spacing: 40) {
            VStack {
                BreathingRing(ringCount: 1, baseSize: 30)
                Text("Weak").font(.caption).foregroundStyle(.gray)
            }
            VStack {
                BreathingRing(ringCount: 3, baseSize: 30)
                Text("Good").font(.caption).foregroundStyle(.gray)
            }
            VStack {
                BreathingRing(ringCount: 5, baseSize: 30)
                Text("Strong").font(.caption).foregroundStyle(.gray)
            }
        }
    }
    .preferredColorScheme(.dark)
}
