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
/// Pass `tint:` to override the default neutral fill — e.g. status red for an
/// inline retry indicator. Nil keeps the colour-scheme-adaptive default.
struct ShimmerRect: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    init(
        width: CGFloat? = nil,
        height: CGFloat = 16,
        cornerRadius: CGFloat = BlipCornerRadius.sm,
        tint: Color? = nil
    ) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
            .frame(width: width, height: height)
            .shimmer()
    }

    private var fillColor: Color {
        if let tint { return tint.opacity(0.25) }
        return colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
}

/// Circular placeholder with shimmer for avatar skeletons.
/// `tint:` overrides the default neutral fill — useful for tinted inline busy
/// indicators (e.g. red retry pulse).
struct ShimmerCircle: View {
    let size: CGFloat
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    init(size: CGFloat = BlipSizing.avatarSmall, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: size, height: size)
            .shimmer()
    }

    private var fillColor: Color {
        if let tint { return tint.opacity(0.25) }
        return colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
}

// MARK: - Skeleton

/// Layout-matching skeleton placeholder. Each shape mirrors the final loaded
/// content so the load-to-content transition feels like a fade-in, not a
/// layout shift. Composes `ShimmerRect` / `ShimmerCircle` under the hood.
///
/// Usage:
/// ```swift
/// Skeleton(.chatRow)                  // avatar + name + last-message line
/// Skeleton(.eventCard)                // image header + title + meta row
/// Skeleton(.productPack)              // pack-pricing card
/// Skeleton(.avatar(diameter: 56))     // bare avatar circle
/// Skeleton.list(of: .chatRow, count: 3)
/// Skeleton(.inlineBusy())             // small in-button busy pulse
/// ```
struct Skeleton: View {

    /// Layout shape of a skeleton placeholder.
    enum Shape {
        /// Avatar circle + two text lines (display name + last-message).
        /// Mirrors a chat list / search result row.
        case chatRow

        /// Image header + title + meta line. Mirrors `EventCard`.
        case eventCard

        /// Square pack card with header + price + caption text. Mirrors
        /// `MessagePackStore` pack cells and `PaywallSheet` rows.
        case productPack

        /// Bare avatar circle at the given diameter. Use for AsyncImage
        /// placeholders or "we're scanning for a peer" decorative slots.
        case avatar(diameter: CGFloat)

        /// Inline busy indicator for in-button or in-row action progress.
        /// Not a layout placeholder — a small shimmer pulse that visually
        /// rhymes with the rest of the loading language without inflating
        /// surrounding layout. Pass `tint:` to colour-match the parent button
        /// (red for retry, white on a coloured CTA, etc.).
        case inlineBusy(tint: Color? = nil)
    }

    let shape: Shape

    init(_ shape: Shape) {
        self.shape = shape
    }

    var body: some View {
        switch shape {
        case .chatRow:
            HStack(spacing: BlipSpacing.md) {
                ShimmerCircle(size: BlipSizing.avatarSmall)
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    ShimmerRect(width: 140, height: 14)
                    ShimmerRect(width: 220, height: 10)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)

        case .eventCard:
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                ShimmerRect(height: 120, cornerRadius: BlipCornerRadius.lg)
                ShimmerRect(width: 200, height: 14)
                ShimmerRect(width: 120, height: 10)
            }

        case .productPack:
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                ShimmerRect(width: 60, height: 22)
                ShimmerRect(height: 14)
                ShimmerRect(width: 80, height: 10)
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
            )

        case .avatar(let diameter):
            ShimmerCircle(size: diameter)

        case .inlineBusy(let tint):
            // Small shimmer pill — matches the visual weight of a
            // controlSize(.small) ProgressView without the spinner motif.
            ShimmerCircle(size: 14, tint: tint)
        }
    }
}

extension Skeleton {
    /// Vertical stack of `count` identical skeletons. Use for list-loading
    /// states (search results, event grids, friend lists) where the eventual
    /// content is a vertical run of the same row.
    static func list(
        of shape: Shape,
        count: Int,
        spacing: CGFloat = BlipSpacing.md
    ) -> some View {
        VStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                Skeleton(shape)
            }
        }
    }
}

// MARK: - Preview

#Preview("Shimmer primitives") {
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

#Preview("Skeleton — chatRow stack") {
    Skeleton.list(of: .chatRow, count: 4)
        .padding(BlipSpacing.md)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Skeleton — eventCard") {
    VStack(spacing: BlipSpacing.lg) {
        Skeleton(.eventCard)
        Skeleton(.eventCard)
    }
    .padding(BlipSpacing.md)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Skeleton — productPack grid") {
    LazyVGrid(columns: [
        GridItem(.flexible(), spacing: BlipSpacing.md),
        GridItem(.flexible(), spacing: BlipSpacing.md)
    ], spacing: BlipSpacing.md) {
        ForEach(0..<4, id: \.self) { _ in
            Skeleton(.productPack)
        }
    }
    .padding(BlipSpacing.md)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Skeleton — avatar diameters") {
    HStack(spacing: BlipSpacing.lg) {
        Skeleton(.avatar(diameter: 32))
        Skeleton(.avatar(diameter: 56))
        Skeleton(.avatar(diameter: 80))
    }
    .padding(BlipSpacing.md)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Skeleton — inlineBusy tints (light mode)") {
    HStack(spacing: BlipSpacing.lg) {
        Skeleton(.inlineBusy())
        Skeleton(.inlineBusy(tint: .red))
        Skeleton(.inlineBusy(tint: .white))
    }
    .padding(BlipSpacing.md)
    .preferredColorScheme(.light)
}
