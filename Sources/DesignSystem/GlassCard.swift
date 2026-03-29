import SwiftUI

// MARK: - GlassCard

/// A reusable glassmorphism container view.
///
/// Renders a translucent material background with a subtle border and rounded corners,
/// matching the Blip design language. The material thickness is configurable.
///
/// Usage:
/// ```swift
/// GlassCard {
///     Text("Hello")
/// }
/// ```
struct GlassCard<Content: View>: View {

    /// Controls the blur intensity of the glass material.
    enum MaterialThickness: Sendable {
        case ultraThin
        case regular
        case thick
    }

    let thickness: MaterialThickness
    let cornerRadius: CGFloat
    let borderOpacity: Double
    let padding: EdgeInsets
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    /// Creates a glass card with configurable material, corner radius, and content.
    /// - Parameters:
    ///   - thickness: Material blur intensity. Default `.thick`.
    ///   - cornerRadius: Corner radius in points. Default `24`.
    ///   - borderOpacity: Opacity of the 0.5pt border. Default `0.2`.
    ///   - padding: Inner content padding. Default `.blipCard`.
    ///   - content: The card's body content.
    init(
        thickness: MaterialThickness = .thick,
        cornerRadius: CGFloat = BlipCornerRadius.xl,
        borderOpacity: Double = 0.2,
        padding: EdgeInsets = .blipCard,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.thickness = thickness
        self.cornerRadius = cornerRadius
        self.borderOpacity = borderOpacity
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(glassBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(borderOverlay)
    }

    // MARK: - Private

    @ViewBuilder
    private var glassBackground: some View {
        switch thickness {
        case .ultraThin:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        case .regular:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        case .thick:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thickMaterial)
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: BlipSizing.hairline)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? .white.opacity(borderOpacity)
            : .black.opacity(borderOpacity)
    }
}

// MARK: - Convenience view modifier

/// Wraps a view in a GlassCard container.
struct GlassCardModifier: ViewModifier {

    let thickness: GlassCard<EmptyView>.MaterialThickness
    let cornerRadius: CGFloat
    let borderOpacity: Double

    func body(content: Content) -> some View {
        content
            .padding(.blipCard)
            .background(glassBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(borderOverlay)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var glassBackground: some View {
        switch thickness {
        case .ultraThin:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        case .regular:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        case .thick:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thickMaterial)
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                colorScheme == .dark
                    ? .white.opacity(borderOpacity)
                    : .black.opacity(borderOpacity),
                lineWidth: BlipSizing.hairline
            )
    }
}

extension View {
    /// Wraps the view in a glass material container.
    func glassCard(
        thickness: GlassCard<EmptyView>.MaterialThickness = .thick,
        cornerRadius: CGFloat = BlipCornerRadius.xl,
        borderOpacity: Double = 0.2
    ) -> some View {
        modifier(GlassCardModifier(
            thickness: thickness,
            cornerRadius: cornerRadius,
            borderOpacity: borderOpacity
        ))
    }
}
