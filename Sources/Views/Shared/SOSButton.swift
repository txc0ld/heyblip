import SwiftUI

private enum SOSButtonL10n {
    static let emergency = String(localized: "sos.button.accessibility_label", defaultValue: "Emergency")
    static let emergencyHint = String(localized: "sos.button.accessibility_hint", defaultValue: "Double tap to open emergency options")
    static let title = String(localized: "sos.button.card.title", defaultValue: "Emergency SOS")
    static let subtitle = String(localized: "sos.button.card.subtitle", defaultValue: "Request help from nearby responders")
}

// MARK: - SOSButton

/// Icon-only SOS button — red medical cross on glass.
/// No text label. Tap opens the real SOSConfirmationSheet.
struct SOSButton: View {

    /// Controls overall button size. Default `.regular` for profile placement.
    enum Size {
        case compact  // Smaller for inline use
        case regular  // Standard 60pt tap target
    }

    let size: Size

    @State private var isPressed = false
    @State private var showSOSSheet = false
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private var iconFont: Font {
        switch size {
        case .compact: return theme.typography.title3
        case .regular: return theme.typography.headline
        }
    }

    private var buttonSize: CGFloat {
        switch size {
        case .compact: return 44
        case .regular: return 60
        }
    }

    init(size: Size = .regular) {
        self.size = size
    }

    var body: some View {
        Button {
            showSOSSheet = true
        } label: {
            Image(systemName: "cross.case.fill")
                .font(iconFont)
                .fontWeight(.bold)
                .foregroundStyle(isPressed ? .white : Color.blipWarmCoral)
                .frame(width: buttonSize, height: buttonSize)
                .background(buttonBackground)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            isPressed
                                ? Color.blipWarmCoral.opacity(0.8)
                                : (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1)),
                            lineWidth: BlipSizing.hairline
                        )
                )
                .background(
                    PulseGlow(
                        color: Color.blipWarmCoral,
                        size: buttonSize * 1.8,
                        cycleDuration: 1.5
                    )
                    .opacity(isPressed ? 1.0 : 0.0)
                    .animation(SpringConstants.gentleAnimation, value: isPressed)
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
                .animation(SpringConstants.bouncyAnimation, value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .frame(minWidth: buttonSize, minHeight: buttonSize)
        .contentShape(Circle())
        .accessibilityLabel(SOSButtonL10n.emergency)
        .accessibilityHint(SOSButtonL10n.emergencyHint)
        .accessibilityAddTraits(.isButton)
        .accessibilitySortPriority(1)
        .fullScreenCover(isPresented: $showSOSSheet) {
            SOSConfirmationSheet(
                isPresented: $showSOSSheet,
                sosViewModel: coordinator.sosViewModel
            )
        }
    }

    // MARK: - Private

    @ViewBuilder
    private var buttonBackground: some View {
        if isPressed {
            Circle().fill(Color.blipWarmCoral)
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Full-width SOS button for profile placement

extension SOSButton {
    /// Full-width glass card variant for prominent placement (e.g., profile screen).
    struct ProfileCard: View {
        @State private var showSOSSheet = false
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button {
                showSOSSheet = true
            } label: {
                GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
                    HStack(spacing: BlipSpacing.md) {
                        Image(systemName: "cross.case.fill")
                            .font(theme.typography.headline)
                            .foregroundStyle(Color.blipWarmCoral)

                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text(SOSButtonL10n.title)
                                .font(theme.typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.colors.text)

                            Text(SOSButtonL10n.subtitle)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: BlipSizing.minTapTarget + BlipSpacing.md)
            .accessibilityLabel(SOSButtonL10n.title)
            .accessibilityHint(SOSButtonL10n.emergencyHint)
            .fullScreenCover(isPresented: $showSOSSheet) {
                SOSConfirmationSheet(
                    isPresented: $showSOSSheet,
                    sosViewModel: coordinator.sosViewModel
                )
            }
        }
    }
}

// MARK: - Preview

#Preview("SOS Button - Icon Only") {
    ZStack {
        GradientBackground()
        SOSButton()
    }
    .environment(\.theme, Theme.shared)
}

#Preview("SOS Button - Profile Card") {
    ZStack {
        GradientBackground()
        SOSButton.ProfileCard()
            .padding(.horizontal, BlipSpacing.md)
    }
    .environment(\.theme, Theme.shared)
}

#Preview("SOS Button - Light") {
    ZStack {
        Color.white.ignoresSafeArea()
        SOSButton()
    }
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}
