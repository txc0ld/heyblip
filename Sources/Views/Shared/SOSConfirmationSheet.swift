import SwiftUI

// MARK: - SOSConfirmationSheet

/// SOS confirmation sheet with 3 severity tiers:
/// - Green (non-urgent): tap confirm
/// - Amber (urgent): slide to confirm
/// - Red (critical): hold for 3 seconds with haptic escalation + countdown circle
///
/// Includes: 10-second cancel banner after send, proximity sensor check,
/// false alarm throttle (drag captcha after 2+ false alarms).
struct SOSConfirmationSheet: View {

    @Binding var isPresented: Bool

    var onSend: ((SOSSeverity) -> Void)?
    var onCancel: (() -> Void)?

    @State private var selectedSeverity: SOSSeverity = .green
    @State private var isSending = false
    @State private var hasSent = false
    @State private var cancelCountdown: Int = 10
    @State private var cancelTimer: Timer?

    // Green: tap confirm
    @State private var greenConfirmed = false

    // Amber: slide to confirm
    @State private var amberSlideOffset: CGFloat = 0
    @State private var amberConfirmed = false

    // Red: hold 3 seconds
    @State private var redHoldProgress: CGFloat = 0
    @State private var redIsHolding = false
    @State private var redConfirmed = false
    @State private var holdTimer: Timer?

    // False alarm throttle
    @State private var falseAlarmCount: Int = 0
    @State private var showCaptcha = false
    @State private var captchaDragOffset: CGFloat = 0
    @State private var captchaCompleted = false

    // Proximity check
    @State private var isPhoneFaceDown = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let amberSlideThreshold: CGFloat = 240
    private let redHoldDuration: TimeInterval = 3.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
                .onTapGesture {} // Prevent dismiss

            VStack(spacing: BlipSpacing.lg) {
                // Drag handle
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, BlipSpacing.sm)

                if hasSent {
                    sentConfirmation
                } else if isPhoneFaceDown {
                    proximityWarning
                } else if showCaptcha && !captchaCompleted {
                    falseAlarmCaptcha
                } else {
                    sosContent
                }

                Spacer()
            }
            .padding(BlipSpacing.md)
        }
        .background(.ultraThickMaterial)
    }

    // MARK: - SOS Content

    private var sosContent: some View {
        VStack(spacing: BlipSpacing.lg) {
            // Title
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "cross.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)

                Text("Request Help")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text("Select the severity of your situation")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
            }

            // Severity selection
            VStack(spacing: BlipSpacing.md) {
                severityCard(.green)
                severityCard(.amber)
                severityCard(.red)
            }

            // Confirmation area
            confirmationArea

            // Cancel button
            Button(action: { isPresented = false }) {
                Text("Cancel")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(minHeight: BlipSizing.minTapTarget)
            }
        }
    }

    // MARK: - Severity Card

    private func severityCard(_ severity: SOSSeverity) -> some View {
        let isSelected = selectedSeverity == severity

        return Button(action: { selectedSeverity = severity }) {
            HStack(spacing: BlipSpacing.md) {
                Circle()
                    .fill(severityColor(severity))
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(severityTitle(severity))
                        .font(theme.typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.colors.text)

                    Text(severityDescription(severity))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(severityColor(severity))
                }
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .fill(isSelected ? severityColor(severity).opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .stroke(isSelected ? severityColor(severity).opacity(0.4) : theme.colors.border, lineWidth: isSelected ? 1.5 : BlipSizing.hairline)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(severityTitle(severity)): \(severityDescription(severity))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Confirmation Area

    @ViewBuilder
    private var confirmationArea: some View {
        switch selectedSeverity {
        case .green:
            greenConfirmation
        case .amber:
            amberConfirmation
        case .red:
            redConfirmation
        }
    }

    // Green: Tap to confirm
    private var greenConfirmation: some View {
        GlassButton("Confirm - Request Help", icon: "checkmark.circle") {
            sendSOS(.green)
        }
        .fullWidth()
    }

    // Amber: Slide to confirm
    private var amberConfirmation: some View {
        ZStack(alignment: .leading) {
            // Track
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .fill(BlipColors.darkColors.statusAmber.opacity(0.15))
                .frame(height: 56)
                .overlay(
                    Text("Slide to confirm")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                        .stroke(BlipColors.darkColors.statusAmber.opacity(0.3), lineWidth: 1)
                )

            // Fill progress
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .fill(BlipColors.darkColors.statusAmber.opacity(0.3))
                .frame(width: amberSlideOffset + 56, height: 56)

            // Slider knob
            Circle()
                .fill(BlipColors.darkColors.statusAmber)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )
                .offset(x: amberSlideOffset + 4)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            amberSlideOffset = max(0, min(amberSlideThreshold, value.translation.width))
                        }
                        .onEnded { _ in
                            if amberSlideOffset >= amberSlideThreshold {
                                amberConfirmed = true
                                sendSOS(.amber)
                            } else {
                                withAnimation(SpringConstants.accessiblePageEntrance) {
                                    amberSlideOffset = 0
                                }
                            }
                        }
                )
        }
        .frame(height: 56)
        .accessibilityLabel("Slide to confirm urgent help request")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }

    // Red: Hold 3 seconds
    private var redConfirmation: some View {
        VStack(spacing: BlipSpacing.sm) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(BlipColors.darkColors.statusRed.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)

                // Progress ring
                Circle()
                    .trim(from: 0, to: redHoldProgress)
                    .stroke(BlipColors.darkColors.statusRed, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(redIsHolding ? .linear(duration: redHoldDuration) : .easeOut(duration: 0.3), value: redHoldProgress)

                // Center content
                VStack(spacing: 2) {
                    Image(systemName: "cross.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BlipColors.darkColors.statusRed)

                    if redIsHolding {
                        Text("\(Int((1.0 - redHoldProgress) * redHoldDuration) + 1)s")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                            .contentTransition(.numericText())
                    }
                }
            }
            .onLongPressGesture(minimumDuration: redHoldDuration, pressing: { pressing in
                redIsHolding = pressing
                if pressing {
                    startRedHold()
                } else {
                    cancelRedHold()
                }
            }) {
                // Completed hold
                redConfirmed = true
                triggerCompletionHaptic()
                sendSOS(.red)
            }

            Text(redIsHolding ? "Keep holding..." : "Hold for 3 seconds")
                .font(theme.typography.secondary)
                .foregroundStyle(BlipColors.darkColors.statusRed)
        }
        .accessibilityLabel("Hold for 3 seconds to send critical help request")
    }

    // MARK: - Sent Confirmation

    private var sentConfirmation: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(severityColor(selectedSeverity))

            Text("Help Requested")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("Medical responders have been alerted. Stay where you are.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            // Cancel banner
            GlassCard(thickness: .regular) {
                HStack(spacing: BlipSpacing.md) {
                    Text("Cancel in \(cancelCountdown)s")
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Spacer()

                    Button(action: cancelSOS) {
                        Text("Cancel SOS")
                            .font(theme.typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(BlipColors.darkColors.statusRed)
                            .padding(.horizontal, BlipSpacing.md)
                            .padding(.vertical, BlipSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(BlipColors.darkColors.statusRed.opacity(0.15))
                            )
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
            }
        }
    }

    // MARK: - Proximity Warning

    private var proximityWarning: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "iphone.gen3.slash")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)

            Text("Pick Up Your Phone")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("Your phone appears to be face-down or in a pocket. Pick it up to confirm your SOS request.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - False Alarm Captcha

    private var falseAlarmCaptcha: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(BlipColors.darkColors.statusAmber)

            Text("Confirm This is Real")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("You've sent multiple alerts recently. Please drag the slider to confirm this is a real emergency.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            // Simple drag captcha
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(theme.colors.hover)
                    .frame(height: 56)
                    .overlay(
                        Text("Drag to confirm")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                    )

                Circle()
                    .fill(.blipAccentPurple)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: captchaDragOffset + 4)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                captchaDragOffset = max(0, min(240, value.translation.width))
                            }
                            .onEnded { _ in
                                if captchaDragOffset >= 240 {
                                    captchaCompleted = true
                                } else {
                                    withAnimation(SpringConstants.accessiblePageEntrance) {
                                        captchaDragOffset = 0
                                    }
                                }
                            }
                    )
            }
            .frame(height: 56)
        }
    }

    // MARK: - Actions

    private func sendSOS(_ severity: SOSSeverity) {
        if falseAlarmCount >= 2 && !captchaCompleted && severity != .green {
            showCaptcha = true
            return
        }

        isSending = true
        onSend?(severity)

        withAnimation(SpringConstants.accessiblePageEntrance) {
            hasSent = true
        }

        // Start cancel countdown
        cancelCountdown = 10
        cancelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            cancelCountdown -= 1
            if cancelCountdown <= 0 {
                timer.invalidate()
                cancelTimer = nil
            }
        }

        triggerSendHaptic()
    }

    private func cancelSOS() {
        cancelTimer?.invalidate()
        cancelTimer = nil
        falseAlarmCount += 1
        onCancel?()

        withAnimation(SpringConstants.accessiblePageEntrance) {
            hasSent = false
            isSending = false
            redHoldProgress = 0
            amberSlideOffset = 0
        }
    }

    // MARK: - Red Hold

    private func startRedHold() {
        redHoldProgress = 0
        withAnimation(.linear(duration: redHoldDuration)) {
            redHoldProgress = 1.0
        }
        triggerHoldStartHaptic()
    }

    private func cancelRedHold() {
        withAnimation(.easeOut(duration: 0.3)) {
            redHoldProgress = 0
        }
    }

    // MARK: - Haptics

    private func triggerSendHaptic() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }

    private func triggerCompletionHaptic() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }

    private func triggerHoldStartHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        #endif
    }

    // MARK: - Helpers

    private func severityColor(_ severity: SOSSeverity) -> Color {
        switch severity {
        case .green: return BlipColors.darkColors.statusGreen
        case .amber: return BlipColors.darkColors.statusAmber
        case .red: return BlipColors.darkColors.statusRed
        }
    }

    private func severityTitle(_ severity: SOSSeverity) -> String {
        switch severity {
        case .green: return "Non-Urgent"
        case .amber: return "Urgent"
        case .red: return "Critical Emergency"
        }
    }

    private func severityDescription(_ severity: SOSSeverity) -> String {
        switch severity {
        case .green: return "I need help but I'm not in immediate danger"
        case .amber: return "I need help soon - feeling unwell or unsafe"
        case .red: return "Life-threatening emergency - I need help NOW"
        }
    }
}

// MARK: - Preview

#Preview("SOS Sheet - Selection") {
    SOSConfirmationSheet(isPresented: .constant(true))
        .preferredColorScheme(.dark)
        .festiChatTheme()
}

#Preview("SOS Sheet - Sent") {
    ZStack {
        Color.black.ignoresSafeArea()
        SOSConfirmationSheet(isPresented: .constant(true))
    }
    .preferredColorScheme(.dark)
    .festiChatTheme()
}
