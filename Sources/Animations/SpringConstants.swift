import SwiftUI

// MARK: - Spring Animation Constants

/// Shared spring animation configurations used throughout FestiChat.
/// All animations respect `UIAccessibility.isReduceMotionEnabled`.
enum SpringConstants {

    // MARK: - Spring parameters

    /// Page entrance spring: stiffness 300, damping 24.
    /// Used for staggered element reveals on screen transitions.
    static let pageEntrance = Spring(mass: 1.0, stiffness: 300, damping: 24)

    /// Message spring: stiffness 200, damping 20.
    /// Used for chat message slide-in animations.
    static let message = Spring(mass: 1.0, stiffness: 200, damping: 20)

    /// Bouncy spring for micro-interactions (toggles, badges).
    static let bouncy = Spring(mass: 1.0, stiffness: 400, damping: 18)

    /// Gentle spring for subtle transitions (fades, small movements).
    static let gentle = Spring(mass: 1.0, stiffness: 150, damping: 20)

    // MARK: - SwiftUI Animation values

    /// Page entrance animation wrapping the page entrance spring.
    static let pageEntranceAnimation: Animation = .spring(pageEntrance)

    /// Message animation wrapping the message spring.
    static let messageAnimation: Animation = .spring(message)

    /// Bouncy animation for micro-interactions.
    static let bouncyAnimation: Animation = .spring(bouncy)

    /// Gentle animation for subtle transitions.
    static let gentleAnimation: Animation = .spring(gentle)

    /// Custom bezier-like reveal animation (approximated with easeOut).
    /// Approximates cubic-bezier(0.16, 1, 0.3, 1) for reveals.
    static let revealAnimation: Animation = .easeOut(duration: 0.45)

    // MARK: - Timing

    /// Stagger delay between items in a staggered reveal (50ms).
    static let staggerDelay: Double = 0.05

    /// Duration for a standard fade transition.
    static let fadeDuration: Double = 0.25

    /// Duration for scroll reveal transitions.
    static let scrollRevealDuration: Double = 0.45

    // MARK: - Accessibility-aware animation

    /// Returns the provided animation, or `.default` with zero duration if Reduce Motion is on.
    /// This ensures all animations gracefully degrade.
    static func accessibleAnimation(_ animation: Animation) -> Animation {
        isReduceMotionEnabled ? .linear(duration: 0.01) : animation
    }

    /// Returns an accessible spring animation using the page entrance parameters.
    static var accessiblePageEntrance: Animation {
        accessibleAnimation(pageEntranceAnimation)
    }

    /// Returns an accessible spring animation using the message parameters.
    static var accessibleMessage: Animation {
        accessibleAnimation(messageAnimation)
    }

    /// Returns an accessible reveal animation.
    static var accessibleReveal: Animation {
        accessibleAnimation(revealAnimation)
    }

    // MARK: - Reduce Motion detection

    /// Checks the system accessibility setting for Reduce Motion.
    static var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }
}
