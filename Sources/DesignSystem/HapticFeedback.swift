import SwiftUI

// MARK: - Haptic Feedback Utilities

/// Centralized haptic feedback triggers for consistent tactile responses.
/// All haptics are no-ops on platforms without UIKit.
enum FCHaptics {

    /// Light impact for button taps, card presses.
    static func lightImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Medium impact for confirmations, tab switches.
    static func mediumImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Heavy impact for SOS press, destructive actions.
    static func heavyImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }

    /// Soft impact for glass button presses.
    static func softImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    /// Selection feedback for toggles, pickers, list selections.
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Success notification for completed actions.
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Warning notification for alerts.
    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// Error notification for failures.
    static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

// MARK: - Sensory Feedback View Modifier

/// Adds haptic feedback when a trigger value changes.
struct HapticModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let style: FCHapticStyle

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, _ in
                switch style {
                case .soft: FCHaptics.softImpact()
                case .light: FCHaptics.lightImpact()
                case .medium: FCHaptics.mediumImpact()
                case .selection: FCHaptics.selection()
                }
            }
    }
}

enum FCHapticStyle {
    case soft
    case light
    case medium
    case selection
}

extension View {
    /// Triggers a haptic when the value changes.
    func hapticFeedback<T: Equatable>(_ style: FCHapticStyle = .soft, trigger: T) -> some View {
        modifier(HapticModifier(trigger: trigger, style: style))
    }
}
