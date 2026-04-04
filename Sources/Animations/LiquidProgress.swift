import SwiftUI

// MARK: - LiquidProgress

/// A fluid progress indicator with a viscous, wobbling fill effect.
/// Uses Canvas for rendering the liquid surface tension simulation.
/// Respects Reduce Motion by falling back to a simple rounded rect fill.
struct LiquidProgress: View {

    // MARK: - Configuration

    /// Progress value from 0.0 to 1.0.
    private let progress: Double

    /// The fill color for the liquid.
    private let color: Color

    /// Height of the progress bar.
    private let barHeight: CGFloat

    /// Corner radius of the bar container.
    private let cornerRadius: CGFloat

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init

    init(
        progress: Double,
        color: Color = Color("AccentPurple"),
        barHeight: CGFloat = 12,
        cornerRadius: CGFloat = 6
    ) {
        self.progress = max(0, min(progress, 1))
        self.color = color
        self.barHeight = barHeight
        self.cornerRadius = cornerRadius
    }

    // MARK: - Body

    var body: some View {
        if reduceMotion {
            staticBar
        } else {
            animatedBar
        }
    }

    // MARK: - Static Bar (Reduce Motion)

    private var staticBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = width * progress

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color.opacity(0.15))

                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: barHeight)
    }

    // MARK: - Animated Bar

    private var animatedBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height

                // Background track
                let trackRect = CGRect(origin: .zero, size: size)
                let trackPath = RoundedRectangle(cornerRadius: cornerRadius)
                    .path(in: trackRect)
                context.fill(trackPath, with: .color(color.opacity(0.15)))

                // Liquid fill
                let fillWidth = width * progress
                guard fillWidth > 0 else { return }

                var liquidPath = Path()

                // Build the liquid shape with a wobbly top surface
                let waveAmplitude: CGFloat = min(barHeight * 0.25, 3.0)
                let waveFrequency: CGFloat = 3.0
                let waveSpeed = elapsed * 2.5

                liquidPath.move(to: CGPoint(x: 0, y: height))
                liquidPath.addLine(to: CGPoint(x: 0, y: 0))

                // Wobbly top edge
                let steps = max(Int(fillWidth), 1)
                for step in 0...steps {
                    let x = CGFloat(step)
                    guard x <= fillWidth else { break }

                    // Surface tension: wave dampens near edges
                    let normalizedX = x / fillWidth
                    let edgeDamping = sin(normalizedX * .pi)

                    let xNorm1 = Double(x) * waveFrequency / Double(width) * .pi * 2
                    let wave1 = sin(xNorm1 + waveSpeed)
                    let xNorm2 = Double(x) * waveFrequency * 1.7 / Double(width) * .pi * 2
                    let wave2 = sin(xNorm2 - waveSpeed * 0.7) * 0.5

                    let waveOffset = (wave1 + wave2) * Double(waveAmplitude) * edgeDamping
                    let y = height * 0.15 + waveOffset

                    liquidPath.addLine(to: CGPoint(x: x, y: max(0, y)))
                }

                liquidPath.addLine(to: CGPoint(x: fillWidth, y: height))
                liquidPath.closeSubpath()

                // Clip to rounded rect
                context.clipToLayer { clipContext in
                    clipContext.fill(trackPath, with: .color(.white))
                }

                context.fill(liquidPath, with: .color(color))

                // Highlight on top surface for viscous effect
                let highlightRect = CGRect(x: 0, y: 0, width: fillWidth, height: height * 0.35)
                context.fill(
                    Path(highlightRect),
                    with: .color(.white.opacity(0.12))
                )
            }
        }
        .frame(height: barHeight)
    }
}

// MARK: - Preview

#Preview("Liquid Progress") {
    LiquidProgressPreview()
        .preferredColorScheme(.dark)
}

private struct LiquidProgressPreview: View {
    @State private var progress: Double = 0.6

    var body: some View {
        VStack(spacing: 30) {
            LiquidProgress(progress: progress, color: Color("AccentPurple"))
                .padding(.horizontal)

            LiquidProgress(progress: progress, color: .cyan, barHeight: 20, cornerRadius: 10)
                .padding(.horizontal)

            LiquidProgress(progress: 0.3, color: .orange, barHeight: 8)
                .padding(.horizontal)

            Slider(value: $progress, in: 0...1)
                .padding(.horizontal)

            Text("Progress: \(Int(progress * 100))%")
                .foregroundStyle(.gray)
        }
        .padding()
        .background(Color.black)
    }
}
