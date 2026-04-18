import SwiftUI

// MARK: - Blip Typography

/// Typography system using Plus Jakarta Sans with system font fallback.
/// Supports Dynamic Type scaling for accessibility.
struct BlipTypography: Sendable {

    /// Display numerals / hero counters — Bold 40pt, rounded
    let display: Font

    /// Large titles — Bold 34pt
    let largeTitle: Font

    /// Primary titles — SemiBold 28pt
    let title1: Font

    /// Secondary titles — SemiBold 24pt
    let title2: Font

    /// Section headers — SemiBold 22pt
    let headline: Font

    /// Tertiary titles / prominent labels — Medium 20pt
    let title3: Font

    /// Body / chat text — Regular 17pt
    let body: Font

    /// Prominent body text / button labels — Medium 16pt
    let callout: Font

    /// Footnote / list items — Regular 15pt
    let footnote: Font

    /// Secondary / metadata — Regular 13pt
    let secondary: Font

    /// Captions — Medium 11pt
    let caption: Font

    /// Small captions — Medium 10pt
    let caption2: Font

    /// Micro labels / status indicators — Medium 9pt
    let micro: Font

    // MARK: - Default instance

    /// Standard typography set using Plus Jakarta Sans with system fallback.
    /// Fonts scale automatically with Dynamic Type via `.relativeTo`.
    static let standard = BlipTypography(
        display: .custom(BlipFontName.bold, size: 40, relativeTo: .largeTitle),
        largeTitle: .custom(BlipFontName.bold, size: 34, relativeTo: .largeTitle),
        title1: .custom(BlipFontName.semiBold, size: 28, relativeTo: .title),
        title2: .custom(BlipFontName.semiBold, size: 24, relativeTo: .title2),
        headline: .custom(BlipFontName.semiBold, size: 22, relativeTo: .headline),
        title3: .custom(BlipFontName.medium, size: 20, relativeTo: .title3),
        body: .custom(BlipFontName.regular, size: 17, relativeTo: .body),
        callout: .custom(BlipFontName.medium, size: 16, relativeTo: .callout),
        footnote: .custom(BlipFontName.regular, size: 15, relativeTo: .footnote),
        secondary: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        caption: .custom(BlipFontName.medium, size: 11, relativeTo: .caption2),
        caption2: .custom(BlipFontName.medium, size: 10, relativeTo: .caption2),
        micro: .custom(BlipFontName.medium, size: 9, relativeTo: .caption2)
    )

    /// System font fallback if custom fonts are not available.
    static let system = BlipTypography(
        display: .system(size: 40, weight: .bold, design: .rounded),
        largeTitle: .system(size: 34, weight: .bold, design: .rounded),
        title1: .system(size: 28, weight: .semibold, design: .rounded),
        title2: .system(size: 24, weight: .semibold, design: .rounded),
        headline: .system(size: 22, weight: .semibold, design: .rounded),
        title3: .system(size: 20, weight: .medium, design: .default),
        body: .system(size: 17, weight: .regular, design: .default),
        callout: .system(size: 16, weight: .medium, design: .default),
        footnote: .system(size: 15, weight: .regular, design: .default),
        secondary: .system(size: 13, weight: .regular, design: .default),
        caption: .system(size: 11, weight: .medium, design: .default),
        caption2: .system(size: 10, weight: .medium, design: .default),
        micro: .system(size: 9, weight: .medium, design: .default)
    )
}

// MARK: - Font name constants

/// PostScript names for Plus Jakarta Sans font files.
/// The actual .ttf files must be added to Resources/Fonts/ and registered in Info.plist.
enum BlipFontName {
    static let regular = "PlusJakartaSans-Regular"
    static let medium = "PlusJakartaSans-Medium"
    static let semiBold = "PlusJakartaSans-SemiBold"
    static let bold = "PlusJakartaSans-Bold"
}

// MARK: - Font registration helper

enum BlipFontRegistration {

    /// Checks if Plus Jakarta Sans is available in the system.
    /// Returns `true` if at least one weight is registered.
    static var isCustomFontAvailable: Bool {
        #if canImport(UIKit)
        let families = UIFont.familyNames
        return families.contains("Plus Jakarta Sans")
        #elseif canImport(AppKit)
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.contains("Plus Jakarta Sans")
        #else
        return false
        #endif
    }

    /// Returns the appropriate typography based on font availability.
    static var resolved: BlipTypography {
        isCustomFontAvailable ? .standard : .system
    }
}

// MARK: - View modifier for consistent text styling

/// Applies Blip typography styles to text views.
struct BlipTextStyle: ViewModifier {

    enum Style {
        case display
        case largeTitle
        case title1
        case title2
        case headline
        case title3
        case body
        case callout
        case footnote
        case secondary
        case caption
        case caption2
        case micro
    }

    let style: Style
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        switch style {
        case .display:
            content.font(theme.typography.display)
        case .largeTitle:
            content.font(theme.typography.largeTitle)
        case .title1:
            content.font(theme.typography.title1)
        case .title2:
            content.font(theme.typography.title2)
        case .headline:
            content.font(theme.typography.headline)
        case .title3:
            content.font(theme.typography.title3)
        case .body:
            content.font(theme.typography.body)
        case .callout:
            content.font(theme.typography.callout)
        case .footnote:
            content.font(theme.typography.footnote)
        case .secondary:
            content.font(theme.typography.secondary)
        case .caption:
            content.font(theme.typography.caption)
        case .caption2:
            content.font(theme.typography.caption2)
        case .micro:
            content.font(theme.typography.micro)
        }
    }
}

extension View {
    /// Applies a Blip text style.
    func blipTextStyle(_ style: BlipTextStyle.Style) -> some View {
        modifier(BlipTextStyle(style: style))
    }
}
