import SwiftUI

// MARK: - ParticleField

/// Ambient floating particles for dark-mode backgrounds.
/// Renders 15-20 tiny dots with slow parallax drift using Canvas + TimelineView.
/// Respects Reduce Motion by displaying static dots with no movement.
struct ParticleField: View {

    // MARK: - Configuration

    /// Number of particles to render.
    private let particleCount: Int

    // MARK: - State

    @State private var particles: [Particle] = []

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Init

    init(particleCount: Int = 18) {
        self.particleCount = max(15, min(particleCount, 20))
    }

    // MARK: - Body

    var body: some View {
        if colorScheme == .light {
            Color.clear
        } else if reduceMotion {
            staticField
        } else {
            animatedField
        }
    }

    // MARK: - Static Field (Reduce Motion)

    private var staticField: some View {
        Canvas { context, size in
            ensureParticles(in: size)
            for particle in particles {
                let rect = CGRect(
                    x: particle.x * size.width - particle.radius,
                    y: particle.y * size.height - particle.radius,
                    width: particle.radius * 2,
                    height: particle.radius * 2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(particle.color.opacity(particle.baseOpacity))
                )
            }
        }
        .onAppear { generateParticles(in: .zero) }
        .ignoresSafeArea()
    }

    // MARK: - Animated Field

    private var animatedField: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                ensureParticles(in: size)
                for particle in particles {
                    let driftX = sin(elapsed * particle.speedX + particle.phaseX) * particle.amplitude
                    let driftY = cos(elapsed * particle.speedY + particle.phaseY) * particle.amplitude

                    let x = (particle.x + driftX) * size.width
                    let y = (particle.y + driftY) * size.height

                    let rect = CGRect(
                        x: x - particle.radius,
                        y: y - particle.radius,
                        width: particle.radius * 2,
                        height: particle.radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(particle.color.opacity(particle.baseOpacity))
                    )
                }
            }
        }
        .onAppear { generateParticles(in: .zero) }
        .ignoresSafeArea()
    }

    // MARK: - Particle Generation

    private func ensureParticles(in size: CGSize) {
        if particles.isEmpty {
            generateParticles(in: size)
        }
    }

    private func generateParticles(in size: CGSize) {
        guard particles.isEmpty else { return }
        particles = (0..<particleCount).map { _ in
            Particle(
                x: Double.random(in: 0...1),
                y: Double.random(in: 0...1),
                radius: CGFloat.random(in: 1...3),
                baseOpacity: Double.random(in: 0.10...0.20),
                color: Bool.random() ? Color("AccentPurple") : .cyan,
                speedX: Double.random(in: 0.05...0.15),
                speedY: Double.random(in: 0.03...0.12),
                phaseX: Double.random(in: 0...(2 * .pi)),
                phaseY: Double.random(in: 0...(2 * .pi)),
                amplitude: Double.random(in: 0.01...0.04)
            )
        }
    }
}

// MARK: - Particle Model

private struct Particle {
    let x: Double
    let y: Double
    let radius: CGFloat
    let baseOpacity: Double
    let color: Color
    let speedX: Double
    let speedY: Double
    let phaseX: Double
    let phaseY: Double
    let amplitude: Double
}

// MARK: - Preview

#Preview("Particle Field") {
    ZStack {
        Color.black.ignoresSafeArea()
        ParticleField()
    }
    .preferredColorScheme(.dark)
}
