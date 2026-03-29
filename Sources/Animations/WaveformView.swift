import SwiftUI

// MARK: - WaveformView

/// Real-time audio amplitude visualization rendered with Canvas.
///
/// Displays a smooth bezier waveform driven by an array of audio level values (0.0 to 1.0).
/// The wave oscillates symmetrically around the vertical center, with amplitude proportional
/// to the input levels.
///
/// Configurable appearance:
/// - `color`: Accent purple for active recording/sending, muted for playback.
/// - `lineWidth`: Stroke width of the waveform path.
/// - `barCount`: Number of sample points rendered (higher = smoother).
///
/// Respects `UIAccessibility.isReduceMotionEnabled`:
/// - Full motion: Animated smooth bezier wave that updates with audio levels.
/// - Reduced motion: Static rounded bars at the current amplitude (no animation).
///
/// Usage:
/// ```swift
/// WaveformView(
///     levels: viewModel.audioLevels,
///     color: .blipAccentPurple,
///     isActive: true
/// )
/// .frame(height: 48)
/// ```
struct WaveformView: View {

    // MARK: - Configuration

    /// Audio amplitude levels as an array of floats in 0.0...1.0.
    /// Each value represents the amplitude at that point in the waveform.
    let levels: [Float]

    /// The primary color for the waveform stroke and fill.
    let color: Color

    /// Whether the waveform should animate (e.g., recording is active).
    let isActive: Bool

    /// Number of bars for the reduced-motion static visualization.
    let barCount: Int

    /// Stroke line width.
    let lineWidth: CGFloat

    /// Opacity of the gradient fill beneath the waveform stroke.
    let fillOpacity: Double

    /// Animation phase offset that shifts the wave horizontally for a flowing effect.
    @State private var phase: Double = 0.0

    /// Creates a waveform visualization view.
    /// - Parameters:
    ///   - levels: Audio amplitude values (0.0 to 1.0). Empty array renders a flat line.
    ///   - color: Waveform color. Default is accent purple.
    ///   - isActive: Whether animation is running. Default `true`.
    ///   - barCount: Bar count for reduced motion mode. Default `24`.
    ///   - lineWidth: Stroke width. Default `2`.
    ///   - fillOpacity: Opacity of the fill gradient. Default `0.15`.
    init(
        levels: [Float],
        color: Color = .blipAccentPurple,
        isActive: Bool = true,
        barCount: Int = 24,
        lineWidth: CGFloat = 2,
        fillOpacity: Double = 0.15
    ) {
        self.levels = levels
        self.color = color
        self.isActive = isActive
        self.barCount = max(4, barCount)
        self.lineWidth = lineWidth
        self.fillOpacity = fillOpacity
    }

    var body: some View {
        if SpringConstants.isReduceMotionEnabled {
            staticBarsView
        } else {
            animatedWaveView
        }
    }

    // MARK: - Animated wave (full motion)

    private var animatedWaveView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                drawWaveform(context: context, size: size, date: timeline.date)
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                phase = 0.0
            }
        }
    }

    /// Draw the bezier waveform into the Canvas context.
    private func drawWaveform(context: GraphicsContext, size: CGSize, date: Date) {
        let width = size.width
        let height = size.height
        let midY = height / 2.0

        // Advance the phase for a flowing animation effect.
        let elapsed = date.timeIntervalSinceReferenceDate
        let currentPhase = isActive ? elapsed * 2.0 : phase

        // Determine the amplitude at each x position via interpolation.
        let sampleCount = max(Int(width / 2.0), 20)

        var topPoints: [CGPoint] = []
        var bottomPoints: [CGPoint] = []

        for i in 0 ..< sampleCount {
            let t = CGFloat(i) / CGFloat(sampleCount - 1)
            let x = t * width

            // Map the x position to a level index.
            let amplitude = interpolatedLevel(at: t, phase: currentPhase)
            let maxAmplitude = midY * 0.85
            let y = CGFloat(amplitude) * maxAmplitude

            topPoints.append(CGPoint(x: x, y: midY - y))
            bottomPoints.append(CGPoint(x: x, y: midY + y))
        }

        // Build the bezier stroke path (top half).
        let strokePath = smoothBezierPath(through: topPoints)

        // Build a closed fill path (top + mirrored bottom).
        var fillPath = strokePath
        for point in bottomPoints.reversed() {
            fillPath.addLine(to: point)
        }
        fillPath.closeSubpath()

        // Draw the gradient fill.
        let fillGradient = Gradient(colors: [
            color.opacity(fillOpacity),
            color.opacity(0.0)
        ])
        context.fill(
            fillPath,
            with: .linearGradient(
                fillGradient,
                startPoint: CGPoint(x: width / 2, y: midY - midY * 0.85),
                endPoint: CGPoint(x: width / 2, y: midY + midY * 0.85)
            )
        )

        // Draw the mirrored bottom stroke.
        let bottomStrokePath = smoothBezierPath(through: bottomPoints)
        context.stroke(
            bottomStrokePath,
            with: .color(color.opacity(0.5)),
            lineWidth: lineWidth * 0.7
        )

        // Draw the top stroke on top.
        context.stroke(
            strokePath,
            with: .color(color),
            lineWidth: lineWidth
        )

        // Draw a center line when inactive.
        if !isActive {
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: width, y: midY))
            context.stroke(
                centerLine,
                with: .color(color.opacity(0.3)),
                lineWidth: lineWidth * 0.5
            )
        }
    }

    /// Interpolate the audio level at a normalized position `t` (0.0 to 1.0).
    ///
    /// Uses cosine interpolation for smooth transitions between sample points.
    /// The `phase` parameter shifts the wave to create a flowing animation.
    private func interpolatedLevel(at t: CGFloat, phase: Double) -> Float {
        guard !levels.isEmpty else { return 0 }

        let levelCount = CGFloat(levels.count)
        let position = t * levelCount + CGFloat(phase).truncatingRemainder(dividingBy: levelCount)
        let wrappedPosition = position.truncatingRemainder(dividingBy: levelCount)
        let adjustedPosition = wrappedPosition < 0 ? wrappedPosition + levelCount : wrappedPosition

        let indexFloat = adjustedPosition
        let index0 = Int(indexFloat) % levels.count
        let index1 = (index0 + 1) % levels.count
        let fraction = Float(indexFloat - CGFloat(Int(indexFloat)))

        // Cosine interpolation for smoothness.
        let cosT = (1.0 - cos(fraction * .pi)) / 2.0
        let level = levels[index0] * (1.0 - cosT) + levels[index1] * cosT

        return max(0, min(1, level))
    }

    /// Build a smooth bezier path through an array of points.
    ///
    /// Uses cubic bezier curves with control points derived from neighboring points
    /// to produce a smooth, natural-looking wave.
    private func smoothBezierPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 2 else {
            if let first = points.first {
                path.move(to: first)
            }
            return path
        }

        path.move(to: points[0])

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        for i in 1 ..< points.count {
            let prev = points[max(0, i - 2)]
            let current = points[i - 1]
            let next = points[i]
            let afterNext = points[min(points.count - 1, i + 1)]

            // Control point offsets (Catmull-Rom to cubic bezier conversion).
            let tension: CGFloat = 0.3
            let cp1 = CGPoint(
                x: current.x + (next.x - prev.x) * tension,
                y: current.y + (next.y - prev.y) * tension
            )
            let cp2 = CGPoint(
                x: next.x - (afterNext.x - current.x) * tension,
                y: next.y - (afterNext.y - current.y) * tension
            )

            path.addCurve(to: next, control1: cp1, control2: cp2)
        }

        return path
    }

    // MARK: - Static bars (reduced motion)

    private var staticBarsView: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing(for: geometry.size.width)) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: lineWidth)
                        .fill(color.opacity(isActive ? 1.0 : 0.4))
                        .frame(
                            width: barWidth(for: geometry.size.width),
                            height: barHeight(at: index, totalHeight: geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Width of each static bar.
    private func barWidth(for totalWidth: CGFloat) -> CGFloat {
        let spacing = max(1, totalWidth * 0.02)
        return max(2, (totalWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
    }

    /// Spacing between static bars.
    private func barSpacing(for totalWidth: CGFloat) -> CGFloat {
        max(1, totalWidth * 0.02)
    }

    /// Height of a static bar at the given index, mapped from audio levels.
    private func barHeight(at index: Int, totalHeight: CGFloat) -> CGFloat {
        let level: Float
        if levels.isEmpty {
            level = 0.05
        } else {
            let normalizedIndex = Float(index) / Float(max(1, barCount - 1))
            let levelsIndex = Int(normalizedIndex * Float(levels.count - 1))
            let clampedIndex = max(0, min(levels.count - 1, levelsIndex))
            level = levels[clampedIndex]
        }

        let minHeight: CGFloat = totalHeight * 0.08
        let maxHeight: CGFloat = totalHeight * 0.9
        return minHeight + CGFloat(level) * (maxHeight - minHeight)
    }
}

// MARK: - Convenience modifier

/// Applies a waveform visualization as an overlay on a view.
struct WaveformOverlayModifier: ViewModifier {

    let levels: [Float]
    let color: Color
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                WaveformView(levels: levels, color: color, isActive: isActive)
            )
    }
}

extension View {
    /// Overlay an audio waveform visualization on this view.
    func waveformOverlay(
        levels: [Float],
        color: Color = .blipAccentPurple,
        isActive: Bool = true
    ) -> some View {
        modifier(WaveformOverlayModifier(levels: levels, color: color, isActive: isActive))
    }
}

// MARK: - Preview

#Preview("Active Waveform") {
    VStack(spacing: 32) {
        Text("Sending (accent purple)")
            .font(.caption)
            .foregroundStyle(.secondary)

        WaveformView(
            levels: (0 ..< 32).map { i in
                Float(sin(Double(i) * 0.3) * 0.4 + 0.5)
            },
            color: .blipAccentPurple,
            isActive: true
        )
        .frame(height: 48)
        .padding(.horizontal)

        Text("Playback (muted)")
            .font(.caption)
            .foregroundStyle(.secondary)

        WaveformView(
            levels: (0 ..< 32).map { i in
                Float(abs(sin(Double(i) * 0.5)) * 0.6 + 0.1)
            },
            color: .gray,
            isActive: true
        )
        .frame(height: 48)
        .padding(.horizontal)

        Text("Inactive")
            .font(.caption)
            .foregroundStyle(.secondary)

        WaveformView(
            levels: [0.1, 0.2, 0.1, 0.15],
            color: .blipAccentPurple,
            isActive: false
        )
        .frame(height: 48)
        .padding(.horizontal)
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
