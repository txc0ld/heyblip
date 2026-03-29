import SwiftUI

// MARK: - ShimmerModifier

/// Glass skeleton shimmer for loading states.
/// Applies a horizontal light sweep animation over content.
/// Respects reduce motion: falls back to subtle opacity pulse.
struct ShimmerModifier: ViewModifier {

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if SpringConstants.isReduceMotionEnabled {
            content.opacity(0.6)
        } else {
            content
                .overlay(shimmerOverlay)
                .clipped()
                .onAppear { startShimmer() }
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .offset(x: phase * (geo.size.width * 1.6) - geo.size.width * 0.3)
        }
    }

    private func startShimmer() {
        withAnimation(
            .linear(duration: 1.5)
            .repeatForever(autoreverses: false)
        ) {
            phase = 1
        }
    }
}

extension View {
    /// Adds a glass shimmer loading effect.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Shimmer Placeholder Shapes

/// Rectangular placeholder with shimmer for skeleton screens.
struct ShimmerRect: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(width: CGFloat? = nil, height: CGFloat = 16, cornerRadius: CGFloat = BlipCornerRadius.sm) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// Circular placeholder with shimmer for avatar skeletons.
struct ShimmerCircle: View {
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(size: CGFloat = BlipSizing.avatarSmall) {
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
            .frame(width: size, height: size)
            .shimmer()
    }
}

// MARK: - Preview

#Preview("Shimmer") {
    VStack(spacing: BlipSpacing.md) {
        GlassCard(thickness: .regular) {
            HStack(spacing: BlipSpacing.md) {
                ShimmerCircle(size: BlipSizing.avatarSmall)
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    ShimmerRect(width: 120, height: 14)
                    ShimmerRect(width: 200, height: 10)
                }
            }
        }

        GlassCard(thickness: .regular) {
            HStack(spacing: BlipSpacing.md) {
                ShimmerCircle(size: BlipSizing.avatarSmall)
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    ShimmerRect(width: 160, height: 14)
                    ShimmerRect(width: 100, height: 10)
                }
            }
        }

        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.sm) {
                ShimmerRect(height: 120, cornerRadius: BlipCornerRadius.lg)
                ShimmerRect(width: 180, height: 14)
                ShimmerRect(height: 10)
            }
        }
    }
    .padding(BlipSpacing.md)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
