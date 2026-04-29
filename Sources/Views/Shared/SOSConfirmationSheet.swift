import SwiftUI

private enum SOSConfirmationL10n {
    static let title = String(localized: "sos.confirmation.title", defaultValue: "Request Help")
    static let subtitle = String(localized: "sos.confirmation.subtitle", defaultValue: "Select the severity of your situation")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let greenConfirm = String(localized: "sos.confirmation.green_confirm", defaultValue: "Confirm - Request Help")
    static let amberSlide = String(localized: "sos.confirmation.amber_slide", defaultValue: "Slide to confirm")
    static let amberAccessibility = String(localized: "sos.confirmation.amber_accessibility_label", defaultValue: "Slide to confirm urgent help request")
    static let redHolding = String(localized: "sos.confirmation.red_holding", defaultValue: "Keep holding...")
    static let redPrompt = String(localized: "sos.confirmation.red_prompt", defaultValue: "Hold for 3 seconds")
    static let redAccessibility = String(localized: "sos.confirmation.red_accessibility_label", defaultValue: "Hold for 3 seconds to send critical help request")
    static let helpRequested = String(localized: "sos.confirmation.sent.title", defaultValue: "Help Requested")
    static let helpRequestedSubtitle = String(localized: "sos.confirmation.sent.subtitle", defaultValue: "Medical responders have been alerted. Stay where you are.")
    static let cancelSOS = String(localized: "sos.confirmation.sent.cancel", defaultValue: "Cancel SOS")
    static let noPeersWarning = String(localized: "sos.confirmation.no_peers_warning", defaultValue: "No nearby peers detected. Your alert will be sent via relay if available.")
    static let pickUpPhone = String(localized: "sos.confirmation.proximity.title", defaultValue: "Pick Up Your Phone")
    static let pickUpPhoneSubtitle = String(localized: "sos.confirmation.proximity.subtitle", defaultValue: "Your phone appears to be face-down or in a pocket. Pick it up to confirm your SOS request.")
    static let captchaTitle = String(localized: "sos.confirmation.captcha.title", defaultValue: "Confirm This is Real")
    static let captchaSubtitle = String(localized: "sos.confirmation.captcha.subtitle", defaultValue: "You've sent multiple alerts recently. Please drag the slider to confirm this is a real emergency.")
    static let captchaDrag = String(localized: "sos.confirmation.captcha.drag", defaultValue: "Drag to confirm")
    static let nonUrgent = String(localized: "sos.severity.non_urgent", defaultValue: "Non-Urgent")
    static let urgent = String(localized: "sos.severity.urgent", defaultValue: "Urgent")
    static let criticalEmergency = String(localized: "sos.severity.critical_emergency", defaultValue: "Critical Emergency")
    static let greenDescription = String(localized: "sos.severity.green_description", defaultValue: "I need help but I'm not in immediate danger")
    static let amberDescription = String(localized: "sos.severity.amber_description", defaultValue: "I need help soon - feeling unwell or unsafe")
    static let redDescription = String(localized: "sos.severity.red_description", defaultValue: "Life-threatening emergency - I need help NOW")

    static func cancelIn(_ seconds: Int) -> String {
        String(
            format: String(localized: "sos.confirmation.sent.cancel_countdown", defaultValue: "Cancel in %ds"),
            locale: Locale.current,
            seconds
        )
    }
}

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
    var sosViewModel: SOSViewModel? = nil

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
    @State private var sendError: String?

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
        .task {
            sosViewModel?.startSOSFlow()
            falseAlarmCount = sosViewModel?.falseAlarmCount ?? 0
        }
        .onDisappear {
            cancelTimer?.invalidate()
            cancelTimer = nil

            if !hasSent {
                sosViewModel?.cancelFlow()
            }
        }
    }

    // MARK: - SOS Content

    private var sosContent: some View {
        VStack(spacing: BlipSpacing.lg) {
            // Title
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "cross.circle.fill")
                    .blipTextStyle(.display)
                    .foregroundStyle(.red)

                Text(SOSConfirmationL10n.title)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text(SOSConfirmationL10n.subtitle)
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

            if sosViewModel?.noPeersWarningShown == true {
                noPeersWarningBanner
            }

            if let sendError {
                Text(sendError)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.statusRed)
                    .multilineTextAlignment(.center)
            }

            // Cancel button
            Button(action: { isPresented = false }) {
                Text(SOSConfirmationL10n.cancel)
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
                        .font(theme.typography.title3)
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
        GlassButton(SOSConfirmationL10n.greenConfirm, icon: "checkmark.circle") {
            sendSOS(.green)
        }
        .fullWidth()
    }

    // Amber: Slide to confirm
    private var amberConfirmation: some View {
        ZStack(alignment: .leading) {
            // Track
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .fill(theme.colors.statusAmber.opacity(0.15))
                .frame(height: 56)
                .overlay(
                    Text(SOSConfirmationL10n.amberSlide)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                        .stroke(theme.colors.statusAmber.opacity(0.3), lineWidth: 1)
                )

            // Fill progress
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .fill(theme.colors.statusAmber.opacity(0.3))
                .frame(width: amberSlideOffset + 56, height: 56)

            // Slider knob
            Circle()
                .fill(theme.colors.statusAmber)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "chevron.right.2")
                        .font(theme.typography.callout)
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
        .accessibilityLabel(SOSConfirmationL10n.amberAccessibility)
        .accessibilityAddTraits(.allowsDirectInteraction)
    }

    // Red: Hold 3 seconds
    private var redConfirmation: some View {
        VStack(spacing: BlipSpacing.sm) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(theme.colors.statusRed.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)

                // Progress ring
                Circle()
                    .trim(from: 0, to: redHoldProgress)
                    .stroke(theme.colors.statusRed, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(redIsHolding ? .linear(duration: redHoldDuration) : .easeOut(duration: 0.3), value: redHoldProgress)

                // Center content
                VStack(spacing: 2) {
                    Image(systemName: "cross.fill")
                        .font(theme.typography.title3)
                        .foregroundStyle(theme.colors.statusRed)

                    if redIsHolding {
                        Text("\(Int((1.0 - redHoldProgress) * redHoldDuration) + 1)s")
                            .font(theme.typography.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(theme.colors.statusRed)
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

            Text(redIsHolding ? SOSConfirmationL10n.redHolding : SOSConfirmationL10n.redPrompt)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.statusRed)
        }
        .accessibilityLabel(SOSConfirmationL10n.redAccessibility)
    }

    // MARK: - Sent Confirmation

    private var sentConfirmation: some View {
        VStack(spacing: BlipSpacing.lg) {
            // BreathingRing behind the success checkmark communicates that the
            // alert is alive and propagating — the rings expand and contract
            // continuously while the cancel countdown is running. Severity
            // colour matches the selected tier so red emergencies pulse with a
            // red ring, etc. BreathingRing internally honours
            // accessibilityReduceMotion and falls back to static rings.
            ZStack {
                BreathingRing(
                    ringCount: 3,
                    baseSize: 60,
                    color: severityColor(selectedSeverity),
                    cycleDuration: 2.4
                )
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.typography.display)
                    .foregroundStyle(severityColor(selectedSeverity))
            }

            Text(SOSConfirmationL10n.helpRequested)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(SOSConfirmationL10n.helpRequestedSubtitle)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            if sosViewModel?.noPeersWarningShown == true {
                noPeersWarningBanner
            }

            // Cancel banner
            GlassCard(thickness: .regular) {
                HStack(spacing: BlipSpacing.md) {
                    Text(SOSConfirmationL10n.cancelIn(cancelCountdown))
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Spacer()

                    Button(action: cancelSOS) {
                        Text(SOSConfirmationL10n.cancelSOS)
                            .font(theme.typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.colors.statusRed)
                            .padding(.horizontal, BlipSpacing.md)
                            .padding(.vertical, BlipSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(theme.colors.statusRed.opacity(0.15))
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
                .font(theme.typography.display)
                .foregroundStyle(theme.colors.mutedText)

            Text(SOSConfirmationL10n.pickUpPhone)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(SOSConfirmationL10n.pickUpPhoneSubtitle)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
    }

    private var noPeersWarningBanner: some View {
        GlassCard(thickness: .regular) {
            HStack(alignment: .top, spacing: BlipSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colors.statusAmber)
                    .padding(.top, 2)

                Text(SOSConfirmationL10n.noPeersWarning)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.text)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(theme.colors.statusAmber.opacity(0.35), lineWidth: BlipSizing.hairline)
        )
    }

    // MARK: - False Alarm Captcha

    private var falseAlarmCaptcha: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .blipTextStyle(.display)
                .foregroundStyle(theme.colors.statusAmber)

            Text(SOSConfirmationL10n.captchaTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(SOSConfirmationL10n.captchaSubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            // Simple drag captcha
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(theme.colors.hover)
                    .frame(height: 56)
                    .overlay(
                        Text(SOSConfirmationL10n.captchaDrag)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                    )

                Circle()
                    .fill(.blipAccentPurple)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "chevron.right.2")
                            .font(theme.typography.callout)
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
        sendError = nil

        guard let sosViewModel else {
            onSend?(severity)
            withAnimation(SpringConstants.accessiblePageEntrance) {
                hasSent = true
            }
            isSending = false
            startCancelCountdown()
            triggerSendHaptic()
            return
        }

        sosViewModel.selectedSeverity = severity

        Task {
            await sosViewModel.confirmAlert()

            await MainActor.run {
                isSending = false

                if case .error(let message) = sosViewModel.flowState {
                    sendError = message
                    return
                }

                onSend?(severity)
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    hasSent = true
                }
                startCancelCountdown()
                triggerSendHaptic()
            }
        }
    }

    private func cancelSOS() {
        cancelTimer?.invalidate()
        cancelTimer = nil
        falseAlarmCount += 1
        onCancel?()

        if let sosViewModel {
            Task {
                await sosViewModel.cancelActiveAlert()
            }
        }

        withAnimation(SpringConstants.accessiblePageEntrance) {
            hasSent = false
            isSending = false
            redHoldProgress = 0
            amberSlideOffset = 0
        }
    }

    private func startCancelCountdown() {
        cancelCountdown = 10
        cancelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor [weak timer] in
                cancelCountdown -= 1
                if cancelCountdown <= 0 {
                    timer?.invalidate()
                    cancelTimer = nil
                }
            }
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
        case .green: return theme.colors.statusGreen
        case .amber: return theme.colors.statusAmber
        case .red: return theme.colors.statusRed
        }
    }

    private func severityTitle(_ severity: SOSSeverity) -> String {
        switch severity {
        case .green: return SOSConfirmationL10n.nonUrgent
        case .amber: return SOSConfirmationL10n.urgent
        case .red: return SOSConfirmationL10n.criticalEmergency
        }
    }

    private func severityDescription(_ severity: SOSSeverity) -> String {
        switch severity {
        case .green: return SOSConfirmationL10n.greenDescription
        case .amber: return SOSConfirmationL10n.amberDescription
        case .red: return SOSConfirmationL10n.redDescription
        }
    }
}

// MARK: - Preview

#Preview("SOS Sheet - Selection") {
    SOSConfirmationSheet(isPresented: .constant(true))
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("SOS Sheet - Sent") {
    ZStack {
        Color.black.ignoresSafeArea()
        SOSConfirmationSheet(isPresented: .constant(true))
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
