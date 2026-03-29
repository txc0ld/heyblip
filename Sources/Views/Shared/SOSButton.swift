import SwiftUI

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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private var iconSize: CGFloat {
        switch size {
        case .compact: return 18
        case .regular: return 22
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
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(isPressed ? .white : theme.colors.statusRed)
                .frame(width: buttonSize, height: buttonSize)
                .background(buttonBackground)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            isPressed
                                ? theme.colors.statusRed.opacity(0.8)
                                : (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1)),
                            lineWidth: BlipSizing.hairline
                        )
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
        .accessibilityLabel("Emergency")
        .accessibilityHint("Double tap to open emergency options")
        .accessibilityAddTraits(.isButton)
        .accessibilitySortPriority(1)
        .fullScreenCover(isPresented: $showSOSSheet) {
            SOSConfirmationSheet(isPresented: $showSOSSheet)
        }
    }

    // MARK: - Private

    @ViewBuilder
    private var buttonBackground: some View {
        if isPressed {
            Circle().fill(theme.colors.statusRed)
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
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button {
                showSOSSheet = true
            } label: {
                GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
                    HStack(spacing: BlipSpacing.md) {
                        Image(systemName: "cross.case.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(theme.colors.statusRed)

                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                            Text("Emergency SOS")
                                .font(theme.typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.colors.text)

                            Text("Request help from nearby responders")
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
            .accessibilityLabel("Emergency SOS")
            .accessibilityHint("Double tap to open emergency options")
            .fullScreenCover(isPresented: $showSOSSheet) {
                SOSConfirmationSheet(isPresented: $showSOSSheet)
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
