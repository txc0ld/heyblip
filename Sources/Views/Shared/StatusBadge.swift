import SwiftUI

private enum StatusBadgeL10n {
    static let typing = String(localized: "chat.status.typing", defaultValue: "Typing")
    static let queued = String(localized: "chat.status.queued", defaultValue: "Queued")
    static let encrypting = String(localized: "chat.status.encrypting", defaultValue: "Encrypting")
    static let failed = String(localized: "chat.status.failed", defaultValue: "Failed to send")
    static let sent = String(localized: "chat.status.sent", defaultValue: "Sent")
    static let delivered = String(localized: "chat.status.delivered", defaultValue: "Delivered")
    static let read = String(localized: "chat.status.read", defaultValue: "Read")
}

// MARK: - StatusBadge

/// Displays message delivery status with animated checkmark icons.
/// States: composing (typing dots), sent (single check), delivered (double check), read (filled double check).
struct StatusBadge: View {

    /// The delivery state to display.
    let status: DeliveryStatus

    /// Icon size.
    let size: CGFloat

    /// Tint color override. Defaults to muted text for sent/delivered, accent for read.
    let tintColor: Color?

    @State private var animationTrigger = false
    @State private var dotAnimating: [Bool] = [false, false, false]
    @Environment(\.theme) private var theme

    enum DeliveryStatus: Sendable, Equatable {
        case composing
        case queued
        case encrypting
        case failed
        case sent
        case delivered
        case read
    }

    init(
        status: DeliveryStatus,
        size: CGFloat = 14,
        tintColor: Color? = nil
    ) {
        self.status = status
        self.size = size
        self.tintColor = tintColor
    }

    var body: some View {
        Group {
            switch status {
            case .composing:
                composingDots
            case .queued:
                queuedIcon
            case .encrypting:
                encryptingIcon
            case .failed:
                failedIcon
            case .sent:
                sentIcon
            case .delivered:
                deliveredIcon
            case .read:
                readIcon
            }
        }
        .onChange(of: status) { _, _ in
            triggerAnimation()
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Composing (typing dots)

    private var composingDots: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(resolvedColor)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .scaleEffect(dotAnimating[index] ? 1.3 : 0.7)
                    .opacity(dotAnimating[index] ? 1.0 : 0.4)
            }
        }
        .onAppear {
            startDotAnimation()
        }
    }

    private func startDotAnimation() {
        guard !SpringConstants.isReduceMotionEnabled else {
            dotAnimating = [true, true, true]
            return
        }

        let staggerOffset: Double = 0.15
        for index in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(staggerOffset * Double(index))
            ) {
                dotAnimating[index] = true
            }
        }
    }

    // MARK: - Queued (clock icon)

    private var queuedIcon: some View {
        Image(systemName: "clock")
            .font(statusIconFont)
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    // MARK: - Encrypting (lock icon)

    private var encryptingIcon: some View {
        Image(systemName: "lock")
            .font(statusIconFont)
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    private var failedIcon: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(statusIconFont)
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    // MARK: - Sent (single check)

    private var sentIcon: some View {
        Image(systemName: "checkmark")
            .font(statusIconFont)
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    // MARK: - Delivered (double check outline)

    private var deliveredIcon: some View {
        ZStack {
            Image(systemName: "checkmark")
                .font(statusIconFont)
                .foregroundStyle(resolvedColor)
                .offset(x: -size * 0.15)

            Image(systemName: "checkmark")
                .font(statusIconFont)
                .foregroundStyle(resolvedColor)
                .offset(x: size * 0.15)
        }
        .scaleEffect(animationTrigger ? 1.0 : 0.5)
        .opacity(animationTrigger ? 1.0 : 0.0)
        .onAppear { triggerAnimation() }
    }

    // MARK: - Read (filled double check)

    private var readIcon: some View {
        ZStack {
            Image(systemName: "checkmark")
                .font(readIconFont)
                .foregroundStyle(readColor)
                .offset(x: -size * 0.15)

            Image(systemName: "checkmark")
                .font(readIconFont)
                .foregroundStyle(readColor)
                .offset(x: size * 0.15)
        }
        .scaleEffect(animationTrigger ? 1.0 : 0.5)
        .opacity(animationTrigger ? 1.0 : 0.0)
        .onAppear { triggerAnimation() }
    }

    // MARK: - Helpers

    private var resolvedColor: Color {
        if let tintColor {
            return tintColor
        }
        switch status {
        case .failed:
            return theme.colors.statusRed
        case .sent:
            return Color.blipElectricCyan
        case .composing, .queued, .encrypting:
            return theme.colors.mutedText
        case .delivered, .read:
            return Color.blipMint
        }
    }

    private var readColor: Color {
        tintColor ?? Color.blipMint
    }

    private var statusIconFont: Font {
        if size <= 11 {
            return theme.typography.caption
        }
        if size <= 14 {
            return theme.typography.subheadline
        }
        if size <= 17 {
            return theme.typography.callout
        }
        return theme.typography.title3
    }

    private var readIconFont: Font {
        if size <= 11 {
            return theme.typography.caption
        }
        if size <= 14 {
            return theme.typography.callout
        }
        return theme.typography.title3
    }

    private var accessibilityText: String {
        switch status {
        case .composing: return StatusBadgeL10n.typing
        case .queued: return StatusBadgeL10n.queued
        case .encrypting: return StatusBadgeL10n.encrypting
        case .failed: return StatusBadgeL10n.failed
        case .sent: return StatusBadgeL10n.sent
        case .delivered: return StatusBadgeL10n.delivered
        case .read: return StatusBadgeL10n.read
        }
    }

    private func triggerAnimation() {
        animationTrigger = false
        let animation = SpringConstants.isReduceMotionEnabled
            ? Animation.easeIn(duration: 0.15)
            : SpringConstants.bouncyAnimation
        withAnimation(animation) {
            animationTrigger = true
        }
    }
}

// MARK: - Preview

#Preview("Status Badges") {
    VStack(spacing: 20) {
        ForEach(
            [StatusBadge.DeliveryStatus.composing, .queued, .encrypting, .failed, .sent, .delivered, .read],
            id: \.self
        ) { status in
            HStack {
                Text("\(String(describing: status))")
                    .font(Theme.shared.typography.secondary)
                    .foregroundStyle(.white)
                    .frame(width: 100, alignment: .leading)
                StatusBadge(status: status)
            }
        }
    }
    .padding()
    .background(GradientBackground())
    .environment(\.theme, Theme.shared)
}

#Preview("Status Badges - Large") {
    HStack(spacing: 20) {
        StatusBadge(status: .sent, size: 20)
        StatusBadge(status: .delivered, size: 20)
        StatusBadge(status: .read, size: 20)
    }
    .padding()
    .background(GradientBackground())
    .environment(\.theme, Theme.shared)
}
