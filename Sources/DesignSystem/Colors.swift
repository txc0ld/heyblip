import SwiftUI

// MARK: - FestiChat Color Tokens

/// Adaptive color tokens that resolve automatically for light and dark modes.
/// Dark: #000000 bg, #FFFFFF text, rgba(255,255,255,0.5) muted, #6600FF accent
/// Light: #FFFFFF bg, #000000 text, rgba(0,0,0,0.5) muted, #6600FF accent
struct FCColors: Sendable {

    // MARK: - Semantic tokens

    /// Primary background. Dark: #000000, Light: #FFFFFF
    let background: Color

    /// Primary text. Dark: #FFFFFF, Light: #000000
    let text: Color

    /// Secondary/muted text. Dark: rgba(255,255,255,0.5), Light: rgba(0,0,0,0.5)
    let mutedText: Color

    /// Subtle border for glass elements. Dark: rgba(255,255,255,0.08), Light: rgba(0,0,0,0.08)
    let border: Color

    /// Card/surface background. Dark: rgba(255,255,255,0.02), Light: rgba(0,0,0,0.02)
    let cardBG: Color

    /// Hover/press state highlight. Dark: rgba(255,255,255,0.05), Light: rgba(0,0,0,0.05)
    let hover: Color

    /// Accent purple, same in both themes.
    let accentPurple: Color

    // MARK: - Status colors

    /// Success / online / confirmed
    let statusGreen: Color

    /// Warning / pending
    let statusAmber: Color

    /// Error / SOS / critical
    let statusRed: Color

    // MARK: - Factory

    /// Resolves colors for the given color scheme.
    static func resolved(for scheme: ColorScheme) -> FCColors {
        switch scheme {
        case .dark:
            return darkColors
        case .light:
            return lightColors
        @unknown default:
            return darkColors
        }
    }

    /// Adaptive color set that automatically adapts to the current color scheme.
    /// These use Asset Catalog colors when available, with programmatic fallbacks.
    static let adaptive = FCColors(
        background: Color("Background", bundle: nil),
        text: Color("TextPrimary", bundle: nil),
        mutedText: Color("MutedText", bundle: nil),
        border: Color("Border", bundle: nil),
        cardBG: Color("CardBG", bundle: nil),
        hover: Color("Hover", bundle: nil),
        accentPurple: Color("AccentPurple", bundle: nil),
        statusGreen: Color(red: 0.20, green: 0.84, blue: 0.47),
        statusAmber: Color(red: 1.0, green: 0.76, blue: 0.0),
        statusRed: Color(red: 1.0, green: 0.27, blue: 0.27)
    )

    // MARK: - Explicit theme sets (programmatic fallback)

    static let darkColors = FCColors(
        background: .black,
        text: .white,
        mutedText: .white.opacity(0.5),
        border: .white.opacity(0.08),
        cardBG: .white.opacity(0.02),
        hover: .white.opacity(0.05),
        accentPurple: Color(red: 0.4, green: 0.0, blue: 1.0),
        statusGreen: Color(red: 0.20, green: 0.84, blue: 0.47),
        statusAmber: Color(red: 1.0, green: 0.76, blue: 0.0),
        statusRed: Color(red: 1.0, green: 0.27, blue: 0.27)
    )

    static let lightColors = FCColors(
        background: .white,
        text: .black,
        mutedText: .black.opacity(0.5),
        border: .black.opacity(0.08),
        cardBG: .black.opacity(0.02),
        hover: .black.opacity(0.05),
        accentPurple: Color(red: 0.4, green: 0.0, blue: 1.0),
        statusGreen: Color(red: 0.18, green: 0.72, blue: 0.40),
        statusAmber: Color(red: 0.90, green: 0.68, blue: 0.0),
        statusRed: Color(red: 0.90, green: 0.22, blue: 0.22)
    )
}

// MARK: - Color convenience extensions

extension Color {

    /// FestiChat accent purple (#6600FF)
    static let fcAccentPurple = Color(red: 0.4, green: 0.0, blue: 1.0)

    /// Gradient stops for the animated mesh background
    static let fcGradientDeepPurple = Color(red: 0.15, green: 0.0, blue: 0.35)
    static let fcGradientMidnightBlue = Color(red: 0.05, green: 0.05, blue: 0.25)
    static let fcGradientDarkTeal = Color(red: 0.0, green: 0.12, blue: 0.20)
    static let fcGradientNearBlack = Color(red: 0.02, green: 0.02, blue: 0.06)

    /// Accent purple gradient for buttons and highlights
    static let fcAccentGradient = LinearGradient(
        colors: [
            Color(red: 0.40, green: 0.0, blue: 1.0),
            Color(red: 0.55, green: 0.15, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - ShapeStyle convenience for colors

extension ShapeStyle where Self == Color {
    /// FestiChat accent purple, usable in ShapeStyle contexts (e.g. `.foregroundStyle`).
    static var fcAccentPurple: Color { Color.fcAccentPurple }
}

// MARK: - ShapeStyle convenience for gradients

extension LinearGradient {
    /// Standard accent gradient for interactive elements.
    static let fcAccent = LinearGradient(
        colors: [
            Color(red: 0.40, green: 0.0, blue: 1.0),
            Color(red: 0.55, green: 0.15, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
