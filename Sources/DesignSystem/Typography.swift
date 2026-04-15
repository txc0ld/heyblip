import SwiftUI

// MARK: - Blip Typography

/// Typography system using Plus Jakarta Sans with system font fallback.
/// Supports Dynamic Type scaling for accessibility.
struct BlipTypography: Sendable {

    /// Hero numbers (peer counts, balance) — Bold 40pt
    let display: Font

    /// Large titles — Bold 34pt
    let largeTitle: Font

    /// Section titles — SemiBold 28pt
    let title2: Font

    /// Card titles — SemiBold 20pt
    let title3: Font

    /// Section headers — SemiBold 22pt
    let headline: Font

    /// Body / chat text — Regular 17pt
    let body: Font

    /// Slightly larger body text — Regular 16pt
    let callout: Font

    /// Button text, subtitles — Medium 15pt
    let subheadline: Font

    /// Secondary / metadata — Regular 13pt
    let secondary: Font

    /// Footnote (alias for secondary) — Regular 13pt
    let footnote: Font

    /// Captions — Medium 11pt
    let caption: Font

    /// Tiny badges (LIVE, BEST VALUE) — Medium 9pt
    let captionSmall: Font

    // MARK: - Default instance

    /// Standard typography set using Plus Jakarta Sans with system fallback.
    /// Fonts scale automatically with Dynamic Type via `.relativeTo`.
    static let standard = BlipTypography(
        display: .custom(BlipFontName.bold, size: 40, relativeTo: .largeTitle),
        largeTitle: .custom(BlipFontName.bold, size: 34, relativeTo: .largeTitle),
        title2: .custom(BlipFontName.semiBold, size: 28, relativeTo: .title2),
        title3: .custom(BlipFontName.semiBold, size: 20, relativeTo: .title3),
        headline: .custom(BlipFontName.semiBold, size: 22, relativeTo: .headline),
        body: .custom(BlipFontName.regular, size: 17, relativeTo: .body),
        callout: .custom(BlipFontName.regular, size: 16, relativeTo: .callout),
        subheadline: .custom(BlipFontName.medium, size: 15, relativeTo: .subheadline),
        secondary: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        footnote: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        caption: .custom(BlipFontName.medium, size: 11, relativeTo: .caption2),
        captionSmall: .custom(BlipFontName.medium, size: 9, relativeTo: .caption2)
    )

    /// System font fallback if custom fonts are not available.
    static let system = BlipTypography(
        display: .system(size: 40, weight: .bold, design: .rounded),
        largeTitle: .system(size: 34, weight: .bold, design: .rounded),
        title2: .system(size: 28, weight: .semibold, design: .rounded),
        title3: .system(size: 20, weight: .semibold, design: .rounded),
        headline: .system(size: 22, weight: .semibold, design: .rounded),
        body: .system(size: 17, weight: .regular, design: .default),
        callout: .system(size: 16, weight: .regular, design: .default),
        subheadline: .system(size: 15, weight: .medium, design: .default),
        secondary: .system(size: 13, weight: .regular, design: .default),
        footnote: .system(size: 13, weight: .regular, design: .default),
        caption: .system(size: 11, weight: .medium, design: .default),
        captionSmall: .system(size: 9, weight: .medium, design: .default)
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
        case title2
        case title3
        case headline
        case body
        case callout
        case subheadline
        case secondary
        case footnote
        case caption
        case captionSmall
    }

    let style: Style
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        switch style {
        case .display:
            content.font(theme.typography.display)
        case .largeTitle:
            content.font(theme.typography.largeTitle)
        case .title2:
            content.font(theme.typography.title2)
        case .title3:
            content.font(theme.typography.title3)
        case .headline:
            content.font(theme.typography.headline)
        case .body:
            content.font(theme.typography.body)
        case .callout:
            content.font(theme.typography.callout)
        case .subheadline:
            content.font(theme.typography.subheadline)
        case .secondary:
            content.font(theme.typography.secondary)
        case .footnote:
            content.font(theme.typography.footnote)
        case .caption:
            content.font(theme.typography.caption)
        case .captionSmall:
            content.font(theme.typography.captionSmall)
        }
    }
}

extension View {
    /// Applies a Blip text style.
    func blipTextStyle(_ style: BlipTextStyle.Style) -> some View {
        modifier(BlipTextStyle(style: style))
    }
}
