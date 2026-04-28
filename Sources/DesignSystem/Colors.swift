import SwiftUI

// MARK: - Blip Color Tokens

/// Adaptive color tokens that resolve automatically for light and dark modes.
/// Dark: #000000 bg, #FFFFFF text, rgba(255,255,255,0.5) muted, #6600FF accent
/// Light: #FFFFFF bg, #000000 text, rgba(0,0,0,0.5) muted, #6600FF accent
struct BlipColors: Sendable {

    // MARK: - Semantic tokens

    /// Primary background. Dark: #000000, Light: #FFFFFF
    let background: Color

    /// Primary text. Dark: #FFFFFF, Light: #000000
    let text: Color

    /// Secondary/muted text. Dark: rgba(255,255,255,0.5), Light: rgba(0,0,0,0.5)
    let mutedText: Color

    /// Tertiary text for timestamps and metadata. Dark: rgba(255,255,255,0.35), Light: rgba(0,0,0,0.35)
    let tertiaryText: Color

    /// Subtle border for glass elements. Dark: rgba(255,255,255,0.08), Light: rgba(0,0,0,0.08)
    let border: Color

    /// Card/surface background. Dark: rgba(255,255,255,0.02), Light: rgba(0,0,0,0.02)
    let cardBG: Color

    /// Hover/press state highlight. Dark: rgba(255,255,255,0.05), Light: rgba(0,0,0,0.05)
    let hover: Color

    /// Accent purple, same in both themes.
    let accentPurple: Color

    // MARK: - Complementary accents

    /// Electric cyan (#00D4FF) — online/active indicators
    let electricCyan: Color

    /// Warm coral (#FF6B6B) — destructive/SOS states
    let warmCoral: Color

    /// Mint (#34D399) — success/connected states
    let mint: Color

    // MARK: - Status colors

    /// Success / online / confirmed
    let statusGreen: Color

    /// Warning / pending
    let statusAmber: Color

    /// Error / SOS / critical
    let statusRed: Color

    // MARK: - Surface hierarchy

    /// Base surface. Dark: #0A0A0F, Light: #FAFAFE
    let surfaceBase: Color

    /// Elevated surface. Dark: #12121A, Light: #FFFFFF
    let surfaceElevated: Color

    /// Card surface. Dark: #1A1A2E, Light: #F5F5FA
    let surfaceCard: Color

    /// Interactive surface. Dark: #22223A, Light: #EDEDF5
    let surfaceInteractive: Color

    // MARK: - Factory

    /// Resolves colors for the given color scheme.
    static func resolved(for scheme: ColorScheme) -> BlipColors {
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
    /// `tertiaryText` is its own catalog token (light: black@0.55, dark: white@0.35)
    /// so timestamps + metadata clear the WCAG 3:1 non-text contrast bar in light
    /// mode without darkening dark-mode metadata. Previously computed as
    /// `MutedText.opacity(0.7)` which, after the light-mode MutedText bump to
    /// black@0.6, would have landed at ~2.7:1 — under the 3:1 floor.
    static let adaptive = BlipColors(
        background: Color("Background", bundle: nil),
        text: Color("TextPrimary", bundle: nil),
        mutedText: Color("MutedText", bundle: nil),
        tertiaryText: Color("TertiaryText", bundle: nil),
        border: Color("Border", bundle: nil),
        cardBG: Color("CardBG", bundle: nil),
        hover: Color("Hover", bundle: nil),
        accentPurple: Color("AccentPurple", bundle: nil),
        electricCyan: Color(red: 0.0, green: 0.83, blue: 1.0),
        warmCoral: Color(red: 1.0, green: 0.42, blue: 0.42),
        mint: Color(red: 0.20, green: 0.83, blue: 0.60),
        statusGreen: Color(red: 0.20, green: 0.84, blue: 0.47),
        statusAmber: Color(red: 1.0, green: 0.76, blue: 0.0),
        statusRed: Color(red: 1.0, green: 0.27, blue: 0.27),
        surfaceBase: Color(red: 0.039, green: 0.039, blue: 0.059),
        surfaceElevated: Color(red: 0.071, green: 0.071, blue: 0.102),
        surfaceCard: Color(red: 0.102, green: 0.102, blue: 0.180),
        surfaceInteractive: Color(red: 0.133, green: 0.133, blue: 0.227)
    )

    // MARK: - Explicit theme sets (programmatic fallback)

    static let darkColors = BlipColors(
        background: .black,
        text: .white,
        mutedText: .white.opacity(0.5),
        tertiaryText: .white.opacity(0.35),
        border: .white.opacity(0.08),
        cardBG: .white.opacity(0.02),
        hover: .white.opacity(0.05),
        accentPurple: Color(red: 0.4, green: 0.0, blue: 1.0),
        electricCyan: Color(red: 0.0, green: 0.83, blue: 1.0),
        warmCoral: Color(red: 1.0, green: 0.42, blue: 0.42),
        mint: Color(red: 0.20, green: 0.83, blue: 0.60),
        statusGreen: Color(red: 0.20, green: 0.84, blue: 0.47),
        statusAmber: Color(red: 1.0, green: 0.76, blue: 0.0),
        statusRed: Color(red: 1.0, green: 0.27, blue: 0.27),
        surfaceBase: Color(red: 0.039, green: 0.039, blue: 0.059),
        surfaceElevated: Color(red: 0.071, green: 0.071, blue: 0.102),
        surfaceCard: Color(red: 0.102, green: 0.102, blue: 0.180),
        surfaceInteractive: Color(red: 0.133, green: 0.133, blue: 0.227)
    )

    static let lightColors = BlipColors(
        background: .white,
        text: .black,
        // WCAG-AA tuned: black@0.6 on white = ~4.6:1 (clears AA body text 4.5:1).
        // Was 0.5 (~3.3:1, AA-fail for body).
        mutedText: .black.opacity(0.6),
        // black@0.55 on white = ~3.7:1 (clears the 3:1 non-text contrast bar
        // by a comfortable margin). Was 0.35 (~2.0:1, well under 3:1).
        tertiaryText: .black.opacity(0.55),
        // Bumped from 0.08 → 0.12 for visible card separation on white surfaces;
        // 0.08 was nearly invisible against white in real-device testing.
        border: .black.opacity(0.12),
        cardBG: .black.opacity(0.02),
        hover: .black.opacity(0.05),
        accentPurple: Color(red: 0.4, green: 0.0, blue: 1.0),
        electricCyan: Color(red: 0.0, green: 0.73, blue: 0.90),
        warmCoral: Color(red: 0.90, green: 0.35, blue: 0.35),
        mint: Color(red: 0.18, green: 0.72, blue: 0.52),
        statusGreen: Color(red: 0.18, green: 0.72, blue: 0.40),
        statusAmber: Color(red: 0.90, green: 0.68, blue: 0.0),
        statusRed: Color(red: 0.90, green: 0.22, blue: 0.22),
        surfaceBase: Color(red: 0.98, green: 0.98, blue: 0.996),
        surfaceElevated: .white,
        surfaceCard: Color(red: 0.961, green: 0.961, blue: 0.980),
        surfaceInteractive: Color(red: 0.929, green: 0.929, blue: 0.961)
    )
}

// MARK: - Color convenience extensions

extension Color {

    /// Blip accent purple (#6600FF)
    static let blipAccentPurple = Color(red: 0.4, green: 0.0, blue: 1.0)

    /// Gradient stops for the animated mesh background
    static let blipGradientDeepPurple = Color(red: 0.15, green: 0.0, blue: 0.35)
    static let blipGradientMidnightBlue = Color(red: 0.05, green: 0.05, blue: 0.25)
    static let blipGradientDarkTeal = Color(red: 0.0, green: 0.12, blue: 0.20)
    static let blipGradientNearBlack = Color(red: 0.02, green: 0.02, blue: 0.06)

    /// Accent purple gradient for buttons and highlights (3-stop)
    static let blipAccentGradient = LinearGradient(
        colors: [
            Color(red: 0.40, green: 0.0, blue: 1.0),   // #6600FF
            Color(red: 0.545, green: 0.361, blue: 0.965), // #8B5CF6
            Color(red: 0.655, green: 0.545, blue: 0.980)  // #A78BFA
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Complementary accent colors

    /// Electric cyan (#00D4FF) for online/active indicators
    static let blipElectricCyan = Color(red: 0.0, green: 0.83, blue: 1.0)

    /// Warm coral (#FF6B6B) for destructive/SOS states
    static let blipWarmCoral = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Mint (#34D399) for success/connected states
    static let blipMint = Color(red: 0.20, green: 0.83, blue: 0.60)

    // MARK: - Ambient glow colors

    /// Ambient purple glow (#6600FF at 10% opacity) for subtle background washes
    static let blipAmbientPurple = Color(red: 0.4, green: 0.0, blue: 1.0).opacity(0.10)

    /// Ambient cyan glow (#00D4FF at 6% opacity) for subtle background washes
    static let blipAmbientCyan = Color(red: 0.0, green: 0.83, blue: 1.0).opacity(0.06)

    // MARK: - Surface hierarchy (dark mode)

    /// Surface base dark: #0A0A0F
    static let blipSurfaceBaseDark = Color(red: 0.039, green: 0.039, blue: 0.059)

    /// Surface elevated dark: #12121A
    static let blipSurfaceElevatedDark = Color(red: 0.071, green: 0.071, blue: 0.102)

    /// Surface card dark: #1A1A2E
    static let blipSurfaceCardDark = Color(red: 0.102, green: 0.102, blue: 0.180)

    /// Surface interactive dark: #22223A
    static let blipSurfaceInteractiveDark = Color(red: 0.133, green: 0.133, blue: 0.227)

    // MARK: - Surface hierarchy (light mode)

    /// Surface base light: #FAFAFE
    static let blipSurfaceBaseLight = Color(red: 0.98, green: 0.98, blue: 0.996)

    /// Surface elevated light: #FFFFFF
    static let blipSurfaceElevatedLight = Color.white

    /// Surface card light: #F5F5FA
    static let blipSurfaceCardLight = Color(red: 0.961, green: 0.961, blue: 0.980)

    /// Surface interactive light: #EDEDF5
    static let blipSurfaceInteractiveLight = Color(red: 0.929, green: 0.929, blue: 0.961)
}

// MARK: - ShapeStyle convenience for colors

extension ShapeStyle where Self == Color {
    /// Blip accent purple, usable in ShapeStyle contexts (e.g. `.foregroundStyle`).
    static var blipAccentPurple: Color { Color.blipAccentPurple }
}

// MARK: - ShapeStyle convenience for gradients

extension LinearGradient {
    /// Standard accent gradient for interactive elements (3-stop).
    static let blipAccent = LinearGradient(
        colors: [
            Color(red: 0.40, green: 0.0, blue: 1.0),     // #6600FF
            Color(red: 0.545, green: 0.361, blue: 0.965), // #8B5CF6
            Color(red: 0.655, green: 0.545, blue: 0.980)  // #A78BFA
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
