import SwiftUI

// MARK: - RippleEffect

/// Expanding concentric ring animation for the Push-to-Talk (PTT) feature.
///
/// Displays multiple rings that expand outward with staggered timing,
/// creating a sonar-like ripple effect. Configurable ring count, speed, and color.
///
/// Respects `UIAccessibility.isReduceMotionEnabled`:
/// - Normal motion: Expanding and fading concentric rings.
/// - Reduced motion: A single pulsing ring with subtle opacity change.
///
/// Usage:
/// ```swift
/// RippleEffect(isActive: $isRecording, ringCount: 3, color: .blipAccentPurple)
/// ```
struct RippleEffect: View {

    /// Whether the ripple animation is active.
    @Binding var isActive: Bool

    /// Number of concentric rings.
    let ringCount: Int

    /// Base color for the rings.
    let color: Color

    /// Maximum scale factor for the outermost ring.
    let maxScale: CGFloat

    /// Duration of one full expansion cycle per ring.
    let cycleDuration: Double

    /// Line width of each ring.
    let lineWidth: CGFloat

    /// Creates a ripple effect view.
    /// - Parameters:
    ///   - isActive: Binding controlling animation playback.
    ///   - ringCount: Number of rings. Default `3`.
    ///   - color: Ring color. Default `.blipAccentPurple`.
    ///   - maxScale: Max expansion scale. Default `2.5`.
    ///   - cycleDuration: Cycle duration in seconds. Default `1.5`.
    ///   - lineWidth: Ring stroke width. Default `2`.
    init(
        isActive: Binding<Bool>,
        ringCount: Int = 3,
        color: Color = .blipAccentPurple,
        maxScale: CGFloat = 2.5,
        cycleDuration: Double = 1.5,
        lineWidth: CGFloat = 2
    ) {
        self._isActive = isActive
        self.ringCount = max(1, ringCount)
        self.color = color
        self.maxScale = maxScale
        self.cycleDuration = cycleDuration
        self.lineWidth = lineWidth
    }

    var body: some View {
        if SpringConstants.isReduceMotionEnabled {
            reducedMotionView
        } else {
            fullMotionView
        }
    }

    // MARK: - Full motion

    private var fullMotionView: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                RippleRing(
                    isActive: isActive,
                    color: color,
                    maxScale: maxScale,
                    cycleDuration: cycleDuration,
                    lineWidth: lineWidth,
                    delayFraction: Double(index) / Double(ringCount)
                )
            }
        }
    }

    // MARK: - Reduced motion

    private var reducedMotionView: some View {
        Circle()
            .stroke(color.opacity(isActive ? 0.6 : 0.0), lineWidth: lineWidth)
            .scaleEffect(isActive ? 1.3 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

// MARK: - Individual ring

/// A single ring within the ripple effect that expands and fades on a loop.
private struct RippleRing: View {

    let isActive: Bool
    let color: Color
    let maxScale: CGFloat
    let cycleDuration: Double
    let lineWidth: CGFloat
    let delayFraction: Double

    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: lineWidth)
            .scaleEffect(scale)
            .opacity(opacity)
            .onChange(of: isActive) { _, active in
                if active {
                    startAnimation()
                } else {
                    stopAnimation()
                }
            }
            .onAppear {
                if isActive {
                    startAnimation()
                }
            }
    }

    private func startAnimation() {
        let delay = cycleDuration * delayFraction

        scale = 1.0
        opacity = 0.0

        withAnimation(
            .easeOut(duration: cycleDuration)
            .repeatForever(autoreverses: false)
            .delay(delay)
        ) {
            scale = maxScale
        }

        withAnimation(
            .easeInOut(duration: cycleDuration)
            .repeatForever(autoreverses: false)
            .delay(delay)
        ) {
            opacity = 0.0
        }

        // Brief initial opacity ramp-up
        withAnimation(.easeIn(duration: 0.15).delay(delay)) {
            opacity = 0.7
        }
    }

    private func stopAnimation() {
        withAnimation(.easeOut(duration: 0.3)) {
            scale = 1.0
            opacity = 0.0
        }
    }
}

// MARK: - Convenience modifier

/// Attaches a ripple effect behind a view (e.g., a PTT button).
struct RippleEffectModifier: ViewModifier {

    @Binding var isActive: Bool
    let ringCount: Int
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(
                RippleEffect(
                    isActive: $isActive,
                    ringCount: ringCount,
                    color: color
                )
            )
    }
}

extension View {
    /// Adds a ripple effect behind this view.
    func rippleEffect(
        isActive: Binding<Bool>,
        ringCount: Int = 3,
        color: Color = .blipAccentPurple
    ) -> some View {
        modifier(RippleEffectModifier(
            isActive: isActive,
            ringCount: ringCount,
            color: color
        ))
    }
}
