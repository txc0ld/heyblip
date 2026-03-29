import SwiftUI

// MARK: - Blip Typography

/// Typography system using Plus Jakarta Sans with system font fallback.
/// Supports Dynamic Type scaling for accessibility.
struct BlipTypography: Sendable {

    /// Large titles — Bold 34pt
    let largeTitle: Font

    /// Section headers — SemiBold 22pt
    let headline: Font

    /// Body / chat text — Regular 17pt
    let body: Font

    /// Secondary / metadata — Regular 13pt
    let secondary: Font

    /// Captions — Medium 11pt
    let caption: Font

    // MARK: - Default instance

    /// Standard typography set using Plus Jakarta Sans with system fallback.
    /// Fonts scale automatically with Dynamic Type via `.relativeTo`.
    static let standard = BlipTypography(
        largeTitle: .custom(BlipFontName.bold, size: 34, relativeTo: .largeTitle),
        headline: .custom(BlipFontName.semiBold, size: 22, relativeTo: .headline),
        body: .custom(BlipFontName.regular, size: 17, relativeTo: .body),
        secondary: .custom(BlipFontName.regular, size: 13, relativeTo: .footnote),
        caption: .custom(BlipFontName.medium, size: 11, relativeTo: .caption2)
    )

    /// System font fallback if custom fonts are not available.
    static let system = BlipTypography(
        largeTitle: .system(size: 34, weight: .bold, design: .rounded),
        headline: .system(size: 22, weight: .semibold, design: .rounded),
        body: .system(size: 17, weight: .regular, design: .default),
        secondary: .system(size: 13, weight: .regular, design: .default),
        caption: .system(size: 11, weight: .medium, design: .default)
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
        case largeTitle
        case headline
        case body
        case secondary
        case caption
    }

    let style: Style
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        switch style {
        case .largeTitle:
            content.font(theme.typography.largeTitle)
        case .headline:
            content.font(theme.typography.headline)
        case .body:
            content.font(theme.typography.body)
        case .secondary:
            content.font(theme.typography.secondary)
        case .caption:
            content.font(theme.typography.caption)
        }
    }
}

extension View {
    /// Applies a Blip text style.
    func blipTextStyle(_ style: BlipTextStyle.Style) -> some View {
        modifier(BlipTextStyle(style: style))
    }
}
