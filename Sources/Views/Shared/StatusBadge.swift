import SwiftUI

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
    @Environment(\.theme) private var theme

    enum DeliveryStatus: Sendable, Equatable {
        case composing
        case queued
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
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(resolvedColor)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
    }

    // MARK: - Queued (clock icon)

    private var queuedIcon: some View {
        Image(systemName: "clock")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    // MARK: - Sent (single check)

    private var sentIcon: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(resolvedColor)
            .scaleEffect(animationTrigger ? 1.0 : 0.5)
            .opacity(animationTrigger ? 1.0 : 0.0)
            .onAppear { triggerAnimation() }
    }

    // MARK: - Delivered (double check outline)

    private var deliveredIcon: some View {
        ZStack {
            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(resolvedColor)
                .offset(x: -size * 0.15)

            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .medium))
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
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(readColor)
                .offset(x: -size * 0.15)

            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .bold))
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
        case .sent:
            return Color.blipElectricCyan
        case .composing, .queued:
            return theme.colors.mutedText
        case .delivered, .read:
            return Color.blipMint
        }
    }

    private var readColor: Color {
        tintColor ?? Color.blipMint
    }

    private var accessibilityText: String {
        switch status {
        case .composing: return "Typing"
        case .queued: return "Queued"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
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
            [StatusBadge.DeliveryStatus.composing, .queued, .sent, .delivered, .read],
            id: \.self
        ) { status in
            HStack {
                Text("\(String(describing: status))")
                    .font(.system(size: 14))
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
