import SwiftUI

// MARK: - MeshParticleView

/// Ambient particle system representing mesh peers in the network.
///
/// Each dot represents a mesh peer, gently floating in the background.
/// New peer discovery triggers a bloom/pulse. Active relay connections
/// are shown as faint animated dashed lines between particles.
///
/// Respects Reduce Motion: falls back to static, low-opacity dots.
struct MeshParticleView: View {

    /// Number of active mesh peers driving particle count.
    let peerCount: Int

    /// Called when a new peer joins (triggers bloom animation).
    var onNewPeer: (() -> Void)?

    @State private var particles: [Particle] = []
    @State private var animationPhase: CGFloat = 0
    @State private var bloomParticleID: UUID?

    @Environment(\.colorScheme) private var colorScheme

    private let maxVisibleParticles = 30
    private let particleBaseSize: CGFloat = 4
    private let bloomScale: CGFloat = 2.5
    private let connectionLineOpacity: Double = 0.08

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // Connection lines between nearby particles
                if !isReduceMotionEnabled {
                    connectionLinesLayer(in: size)
                }

                // Particle dots
                ForEach(particles) { particle in
                    particleDot(particle: particle, in: size)
                }
            }
            .onAppear {
                generateParticles(in: size)
                startAnimationIfAllowed()
            }
            .onChange(of: peerCount) { _, newCount in
                updateParticleCount(newCount, in: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Particle Dot

    @ViewBuilder
    private func particleDot(particle: Particle, in size: CGSize) -> some View {
        let isBloom = particle.id == bloomParticleID
        let baseX = particle.baseX * size.width
        let baseY = particle.baseY * size.height

        let offsetX: CGFloat = isReduceMotionEnabled ? 0 :
            sin(animationPhase * particle.speedMultiplier + particle.phaseOffset) * 15
        let offsetY: CGFloat = isReduceMotionEnabled ? 0 :
            cos(animationPhase * particle.speedMultiplier * 0.7 + particle.phaseOffset) * 10

        Circle()
            .fill(particleColor(for: particle))
            .frame(width: particleSize(for: particle), height: particleSize(for: particle))
            .scaleEffect(isBloom ? bloomScale : 1.0)
            .opacity(isBloom ? 0.9 : particle.opacity)
            .blur(radius: isBloom ? 4 : 0.5)
            .position(x: baseX + offsetX, y: baseY + offsetY)
            .animation(
                isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6),
                value: isBloom
            )
    }

    private func particleColor(for particle: Particle) -> Color {
        if particle.isRelaying {
            return .blipAccentPurple.opacity(0.7)
        }
        return colorScheme == .dark
            ? .white.opacity(0.3)
            : .black.opacity(0.15)
    }

    private func particleSize(for particle: Particle) -> CGFloat {
        particleBaseSize * particle.sizeMultiplier
    }

    // MARK: - Connection Lines

    @ViewBuilder
    private func connectionLinesLayer(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let connectionDistance: CGFloat = 120
            let visibleParticles = particles.prefix(maxVisibleParticles)

            for i in visibleParticles.indices {
                for j in (i + 1)..<visibleParticles.count {
                    let p1 = visibleParticles[i]
                    let p2 = visibleParticles[j]

                    guard p1.isRelaying || p2.isRelaying else { continue }

                    let pos1 = CGPoint(
                        x: p1.baseX * size.width + sin(animationPhase * p1.speedMultiplier + p1.phaseOffset) * 15,
                        y: p1.baseY * size.height + cos(animationPhase * p1.speedMultiplier * 0.7 + p1.phaseOffset) * 10
                    )
                    let pos2 = CGPoint(
                        x: p2.baseX * size.width + sin(animationPhase * p2.speedMultiplier + p2.phaseOffset) * 15,
                        y: p2.baseY * size.height + cos(animationPhase * p2.speedMultiplier * 0.7 + p2.phaseOffset) * 10
                    )

                    let dist = hypot(pos1.x - pos2.x, pos1.y - pos2.y)
                    guard dist < connectionDistance else { continue }

                    let opacity = (1.0 - dist / connectionDistance) * connectionLineOpacity

                    var path = Path()
                    path.move(to: pos1)
                    path.addLine(to: pos2)

                    context.stroke(
                        path,
                        with: .color(colorScheme == .dark
                            ? .white.opacity(opacity)
                            : .black.opacity(opacity)),
                        style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                    )
                }
            }
        }
    }

    // MARK: - Particle Management

    private func generateParticles(in size: CGSize) {
        let count = min(peerCount, maxVisibleParticles)
        particles = (0..<max(count, 5)).map { _ in
            Particle.random()
        }
    }

    private func updateParticleCount(_ newCount: Int, in size: CGSize) {
        let targetCount = min(newCount, maxVisibleParticles)
        let currentCount = particles.count

        if targetCount > currentCount {
            let newParticle = Particle.random()
            particles.append(newParticle)

            // Trigger bloom for new peer
            bloomParticleID = newParticle.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if bloomParticleID == newParticle.id {
                    bloomParticleID = nil
                }
            }
        } else if targetCount < currentCount && !particles.isEmpty {
            particles.removeLast()
        }
    }

    // MARK: - Animation

    private func startAnimationIfAllowed() {
        guard !isReduceMotionEnabled else { return }

        withAnimation(
            .linear(duration: 20)
            .repeatForever(autoreverses: false)
        ) {
            animationPhase = 2 * .pi
        }
    }

    private var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }
}

// MARK: - Particle Model

private struct Particle: Identifiable {
    let id = UUID()
    let baseX: CGFloat
    let baseY: CGFloat
    let opacity: Double
    let sizeMultiplier: CGFloat
    let speedMultiplier: CGFloat
    let phaseOffset: CGFloat
    let isRelaying: Bool

    static func random() -> Particle {
        Particle(
            baseX: CGFloat.random(in: 0.05...0.95),
            baseY: CGFloat.random(in: 0.05...0.95),
            opacity: Double.random(in: 0.15...0.4),
            sizeMultiplier: CGFloat.random(in: 0.6...1.5),
            speedMultiplier: CGFloat.random(in: 0.3...1.2),
            phaseOffset: CGFloat.random(in: 0...(2 * .pi)),
            isRelaying: Bool.random() && Bool.random() // ~25% chance
        )
    }
}

// MARK: - Preview

#Preview("Mesh Particles - Dark") {
    ZStack {
        GradientBackground()
        MeshParticleView(peerCount: 15)
    }
    .preferredColorScheme(.dark)
}

#Preview("Mesh Particles - Light") {
    ZStack {
        Color.white
        MeshParticleView(peerCount: 8)
    }
    .preferredColorScheme(.light)
}
