import SwiftUI

// MARK: - GlassButton

/// A glass-styled button with accent purple gradient fill.
/// Provides visual feedback for hover (macOS) and press states.
/// Enforces minimum 44pt tap target for accessibility.
struct GlassButton: View {

    /// Visual style of the button.
    enum Style: Sendable {
        /// Filled with accent gradient. Primary actions.
        case primary
        /// Glass material background. Secondary actions.
        case secondary
        /// Transparent with border only. Tertiary actions.
        case outline
    }

    /// Size preset affecting padding and font.
    enum Size: Sendable {
        case small
        case regular
        case large

        var verticalPadding: CGFloat {
            switch self {
            case .small: return BlipSpacing.sm
            case .regular: return BlipSpacing.md - 2
            case .large: return BlipSpacing.md
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return BlipSpacing.md
            case .regular: return BlipSpacing.lg
            case .large: return BlipSpacing.xl
            }
        }

        var font: Font {
            switch self {
            case .small: return .custom(BlipFontName.medium, size: 13, relativeTo: .footnote)
            case .regular: return .custom(BlipFontName.semiBold, size: 15, relativeTo: .body)
            case .large: return .custom(BlipFontName.semiBold, size: 17, relativeTo: .body)
            }
        }
    }

    let title: String
    let icon: String?
    let style: Style
    let size: Size
    let isLoading: Bool
    let action: () -> Void

    @State private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    /// Creates a glass button.
    /// - Parameters:
    ///   - title: Button label text.
    ///   - icon: Optional SF Symbol name shown before the title.
    ///   - style: Visual style. Default `.primary`.
    ///   - size: Size preset. Default `.regular`.
    ///   - isLoading: Shows a spinner and disables interaction. Default `false`.
    ///   - action: Closure executed on tap.
    init(
        _ title: String,
        icon: String? = nil,
        style: Style = .primary,
        size: Size = .regular,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: {
            guard !isLoading else { return }
            action()
        }) {
            HStack(spacing: BlipSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                        .scaleEffect(0.8)
                } else if let icon {
                    Image(systemName: icon)
                        .font(size.font)
                }

                Text(title)
                    .font(size.font)
            }
            .foregroundStyle(foregroundColor)
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: BlipSizing.minTapTarget)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
            .overlay(borderOverlay)
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(SpringConstants.buttonPress, value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Style resolution

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            LinearGradient.blipAccent
                .opacity(isPressed ? 0.85 : 1.0)
        case .secondary:
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .fill(isPressed ? hoverFill : Color.clear)
                )
        case .outline:
            Color.clear
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .fill(isPressed ? hoverFill : Color.clear)
                )
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch style {
        case .primary:
            EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .stroke(borderColor, lineWidth: BlipSizing.hairline)
        case .outline:
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .stroke(Color.blipAccentPurple.opacity(0.6), lineWidth: 1)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary, .outline:
            return colorScheme == .dark ? .white : .black
        }
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.15)
            : .black.opacity(0.10)
    }

    private var hoverFill: Color {
        colorScheme == .dark
            ? .white.opacity(0.05)
            : .black.opacity(0.05)
    }
}

// MARK: - SpringConstants helper for button

private extension SpringConstants {
    static let buttonPress: Animation = .spring(
        response: 0.25,
        dampingFraction: 0.7
    )
}

// MARK: - Full-width variant

extension GlassButton {
    /// Returns this button stretched to fill the available width.
    func fullWidth() -> some View {
        self.frame(maxWidth: .infinity)
    }
}
