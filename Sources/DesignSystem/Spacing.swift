import SwiftUI

// MARK: - Blip Spacing Scale

/// Consistent spacing values used throughout the app.
/// Based on a 4pt base unit with common multipliers.
enum BlipSpacing {

    /// 4pt — Extra small. Icon gaps, tight inline spacing.
    static let xs: CGFloat = 4

    /// 8pt — Small. Inter-element spacing within a component.
    static let sm: CGFloat = 8

    /// 16pt — Medium. Standard content padding, list item spacing.
    static let md: CGFloat = 16

    /// 24pt — Large. Section spacing, card padding.
    static let lg: CGFloat = 24

    /// 32pt — Extra large. Major section gaps, modal padding.
    static let xl: CGFloat = 32

    /// 48pt — Double extra large. Page-level spacing, hero content padding.
    static let xxl: CGFloat = 48
}

// MARK: - Corner radius tokens

/// Corner radius values matching the glassmorphism design language.
enum BlipCornerRadius {

    /// 8pt — Small elements like badges, chips.
    static let sm: CGFloat = 8

    /// 12pt — Chat bubbles, small cards.
    static let md: CGFloat = 12

    /// 16pt — Medium cards, text fields.
    static let lg: CGFloat = 16

    /// 24pt — Primary glass cards and sheets.
    static let xl: CGFloat = 24

    /// 32pt — Full-size modals, large cards.
    static let xxl: CGFloat = 32

    /// Dynamic — Rounded capsule (used for pill-shaped elements).
    static let capsule: CGFloat = .infinity
}

// MARK: - Sizing tokens

/// Minimum tap target and component sizing.
enum BlipSizing {

    /// 44pt — Minimum tap target (Apple HIG).
    static let minTapTarget: CGFloat = 44

    /// 36pt — Standard icon button size.
    static let iconButton: CGFloat = 36

    /// 40pt — Avatar size in lists.
    static let avatarSmall: CGFloat = 40

    /// 56pt — Avatar size in headers.
    static let avatarMedium: CGFloat = 56

    /// 80pt — Avatar size on profile screens.
    static let avatarLarge: CGFloat = 80

    /// 0.5pt — Hairline border width for glass elements.
    static let hairline: CGFloat = 0.5
}

// MARK: - Padding convenience

extension EdgeInsets {

    /// Standard card padding (24pt all around).
    static let blipCard = EdgeInsets(
        top: BlipSpacing.lg,
        leading: BlipSpacing.lg,
        bottom: BlipSpacing.lg,
        trailing: BlipSpacing.lg
    )

    /// Standard content padding (16pt all around).
    static let blipContent = EdgeInsets(
        top: BlipSpacing.md,
        leading: BlipSpacing.md,
        bottom: BlipSpacing.md,
        trailing: BlipSpacing.md
    )

    /// Horizontal-only padding (16pt leading/trailing).
    static let blipHorizontal = EdgeInsets(
        top: 0,
        leading: BlipSpacing.md,
        bottom: 0,
        trailing: BlipSpacing.md
    )
}
