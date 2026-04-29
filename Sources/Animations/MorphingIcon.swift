import SwiftUI

// MARK: - MorphingIcon

/// Animated shape interpolation between a microphone icon and a send arrow.
///
/// Used in the chat text field to morph the action button from "record voice note"
/// (mic) to "send message" (arrow) when text is entered.
///
/// Respects `UIAccessibility.isReduceMotionEnabled`:
/// - Normal motion: Smooth shape morph with rotation and scale spring.
/// - Reduced motion: Instant icon swap with a brief cross-fade.
///
/// Usage:
/// ```swift
/// MorphingIcon(isSendMode: $hasText)
///     .frame(width: 24, height: 24)
/// ```
struct MorphingIcon: View {

    /// When `true`, shows the send arrow. When `false`, shows the microphone.
    @Binding var isSendMode: Bool

    /// Tint color for the icon.
    var tintColor: Color = .white

    /// Size of the icon frame.
    var size: CGFloat = 24

    @State private var rotation: Double = 0
    @State private var scale: CGFloat = 1.0
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if SpringConstants.isReduceMotionEnabled {
                reducedMotionContent
            } else {
                fullMotionContent
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(isSendMode ? "Send message" : "Record voice note")
    }

    // MARK: - Full motion

    private var fullMotionContent: some View {
        ZStack {
            // Microphone icon
            Image(systemName: "mic.fill")
                .font(microphoneFont)
                .foregroundStyle(tintColor)
                .opacity(isSendMode ? 0.0 : 1.0)
                .scaleEffect(isSendMode ? 0.3 : 1.0)
                .rotationEffect(.degrees(isSendMode ? -90 : 0))

            // Send arrow icon
            Image(systemName: "arrow.up")
                .font(sendFont)
                .foregroundStyle(tintColor)
                .opacity(isSendMode ? 1.0 : 0.0)
                .scaleEffect(isSendMode ? 1.0 : 0.3)
                .rotationEffect(.degrees(isSendMode ? 0 : 90))
        }
        .animation(SpringConstants.bouncyAnimation, value: isSendMode)
    }

    // MARK: - Reduced motion

    private var reducedMotionContent: some View {
        Group {
            if isSendMode {
                Image(systemName: "arrow.up")
                    .font(sendFont)
                    .foregroundStyle(tintColor)
            } else {
                Image(systemName: "mic.fill")
                    .font(microphoneFont)
                    .foregroundStyle(tintColor)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isSendMode)
    }

    private var microphoneFont: Font {
        iconPointSize <= 15 ? theme.typography.subheadline : theme.typography.body
    }

    private var sendFont: Font {
        iconPointSize <= 15 ? theme.typography.callout : theme.typography.title3
    }

    private var iconPointSize: CGFloat {
        size * 0.7
    }
}

// MARK: - MorphingIconButton

/// A tappable button variant of the morphing icon, wrapped in an accent circle background.
struct MorphingIconButton: View {

    @Binding var isSendMode: Bool
    let action: () -> Void

    var buttonSize: CGFloat = BlipSizing.minTapTarget

    @State private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(backgroundFill)
                    .frame(width: buttonSize, height: buttonSize)

                MorphingIcon(
                    isSendMode: $isSendMode,
                    tintColor: .white,
                    size: buttonSize * 0.45
                )
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(SpringConstants.bouncyAnimation, value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(isSendMode ? "Send" : "Record")
        .accessibilityAddTraits(.isButton)
    }

    private var backgroundFill: some ShapeStyle {
        LinearGradient.blipAccent
    }
}

// MARK: - Shape paths for custom morph (advanced, for future Canvas-based morph)

/// Defines the control points for the microphone and send arrow shapes.
/// Reserved for a future implementation using Canvas and shape interpolation
/// instead of SF Symbol cross-fade.
enum MorphingIconPaths {

    /// Normalized path points for a simplified microphone silhouette.
    /// Coordinates are in a 0...1 unit space.
    static let microphonePoints: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.00), // top center
        CGPoint(x: 0.70, y: 0.05), // top right curve
        CGPoint(x: 0.70, y: 0.45), // right body
        CGPoint(x: 0.50, y: 0.50), // bottom center of head
        CGPoint(x: 0.30, y: 0.45), // left body
        CGPoint(x: 0.30, y: 0.05), // top left curve
        CGPoint(x: 0.50, y: 0.55), // stem start
        CGPoint(x: 0.50, y: 0.80), // stem end
        CGPoint(x: 0.35, y: 0.80), // base left
        CGPoint(x: 0.65, y: 0.80), // base right
    ]

    /// Normalized path points for an upward arrow.
    static let arrowPoints: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.00), // tip
        CGPoint(x: 0.80, y: 0.35), // right wing tip
        CGPoint(x: 0.60, y: 0.35), // right wing inner
        CGPoint(x: 0.60, y: 0.80), // right shaft bottom
        CGPoint(x: 0.40, y: 0.80), // left shaft bottom
        CGPoint(x: 0.40, y: 0.35), // left wing inner
        CGPoint(x: 0.20, y: 0.35), // left wing tip
    ]

    /// Interpolates between two point arrays.
    /// - Parameters:
    ///   - from: Source points.
    ///   - to: Destination points.
    ///   - progress: 0 = fully `from`, 1 = fully `to`.
    /// - Returns: Interpolated points. Arrays are matched by index; shorter array is padded.
    static func interpolate(
        from: [CGPoint],
        to: [CGPoint],
        progress: CGFloat
    ) -> [CGPoint] {
        let maxCount = max(from.count, to.count)
        let paddedFrom = padArray(from, to: maxCount)
        let paddedTo = padArray(to, to: maxCount)

        return zip(paddedFrom, paddedTo).map { (a, b) in
            CGPoint(
                x: a.x + (b.x - a.x) * progress,
                y: a.y + (b.y - a.y) * progress
            )
        }
    }

    private static func padArray(_ array: [CGPoint], to count: Int) -> [CGPoint] {
        guard array.count < count, let last = array.last else { return array }
        return array + Array(repeating: last, count: count - array.count)
    }
}
