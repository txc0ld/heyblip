import SwiftUI

// MARK: - Blip Typography

/// Typography system using Plus Jakarta Sans with system font fallback.
/// Supports Dynamic Type scaling for accessibility.
struct BlipTypography: Sendable {

    /// Hero / splash text — Bold 40pt
    let display: Font

    /// Large titles — Bold 34pt
    let largeTitle: Font

    /// Primary titles — SemiBold 28pt (alias for title2, kept for legacy callers)
    let title1: Font

    /// Modal / sheet titles — SemiBold 28pt
    let title2: Font

    /// Section headers — SemiBold 20pt
    let title3: Font

    /// Card headers — SemiBold 22pt
    let headline: Font

    /// Action labels, callouts — SemiBold 16pt
    let callout: Font

    /// Secondary labels — Medium 15pt
    let subheadline: Font

    /// Body / chat text — Regular 17pt
    let body: Font

    /// Secondary / metadata — Regular 13pt
    let secondary: Font

    /// Footnote labels — Regular 13pt
    let footnote: Font

    /// Captions — Medium 11pt
    let caption: Font

    /// Tiny labels / timestamps — Medium 9pt
    let captionSmall: Font

    /// Small captions — Medium 10pt (alias kept for legacy callers, maps to captionSmall)
    let caption2: Font

    /// Micro labels / status indicators — Medium 9pt (alias kept for legacy callers)
    let micro: Font

    // MARK: - Default instance

    /// Standard typography set using Plus Jakarta Sans with system fallback.
    /// Fonts scale automatically with Dynamic Type via `.relativeTo`.
    static let standard = BlipTypography(
        display: .custom(BlipFontName.bold, size: 40, relativeTo: .largeTitle),
        largeTitle: .custom(BlipFontName.bold, size: 34, relativeTo: .largeTitle),
        title1: .custom(BlipFontName.semiBold, size: 28, relativeTo: .title),
        title2: .custom(BlipFontName.semiBold, size: 28, relativeTo: .title2),
        title3: .custom(BlipFontName.semiBold, size: 20, relativeTo: .title3),
        headline: .custom(BlipFontName.semiBold, size: 22, relativeTo: .headline),
        callout: .custom(BlipFontName.semiBold, size: 16, relativeTo: .callout),
        subheadline: .custom(BlipFontName.medium, size: 15, relativeTo: .subheadline),
        body: .custom(BlipFontName.regular, size: 17, relativeTo: .body),
        secondary: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        footnote: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        caption: .custom(BlipFontName.medium, size: 11, relativeTo: .caption2),
        captionSmall: .custom(BlipFontName.medium, size: 9, relativeTo: .caption2),
        caption2: .custom(BlipFontName.medium, size: 10, relativeTo: .caption2),
        micro: .custom(BlipFontName.medium, size: 9, relativeTo: .caption2)
    )

    /// System font fallback if custom fonts are not available.
    static let system = BlipTypography(
        display: .system(size: 40, weight: .bold, design: .default),
        largeTitle: .system(size: 34, weight: .bold, design: .rounded),
        title1: .system(size: 28, weight: .semibold, design: .rounded),
        title2: .system(size: 28, weight: .semibold, design: .default),
        title3: .system(size: 20, weight: .semibold, design: .default),
        headline: .system(size: 22, weight: .semibold, design: .rounded),
        callout: .system(size: 16, weight: .semibold, design: .default),
        subheadline: .system(size: 15, weight: .medium, design: .default),
        body: .system(size: 17, weight: .regular, design: .default),
        secondary: .system(size: 13, weight: .regular, design: .default),
        footnote: .system(size: 13, weight: .regular, design: .default),
        caption: .system(size: 11, weight: .medium, design: .default),
        captionSmall: .system(size: 9, weight: .medium, design: .default),
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
        case title3
        case headline
        case callout
        case subheadline
        case body
        case secondary
        case footnote
        case caption
        case captionSmall
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
        case .title3:
            content.font(theme.typography.title3)
        case .headline:
            content.font(theme.typography.headline)
        case .callout:
            content.font(theme.typography.callout)
        case .subheadline:
            content.font(theme.typography.subheadline)
        case .body:
            content.font(theme.typography.body)
        case .secondary:
            content.font(theme.typography.secondary)
        case .footnote:
            content.font(theme.typography.footnote)
        case .caption:
            content.font(theme.typography.caption)
        case .captionSmall:
            content.font(theme.typography.captionSmall)
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
