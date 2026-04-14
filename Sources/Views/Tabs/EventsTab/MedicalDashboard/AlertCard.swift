import SwiftUI

private enum AlertCardL10n {
    static let elapsed = String(localized: "medical.alert_card.elapsed", defaultValue: "elapsed")
    static let accept = String(localized: "common.accept", defaultValue: "Accept")
    static let navigate = String(localized: "common.navigate", defaultValue: "Navigate")
    static let resolve = String(localized: "common.resolve", defaultValue: "Resolve")
    static let nonUrgent = String(localized: "medical.alert.non_urgent.uppercase", defaultValue: "NON-URGENT")
    static let urgent = String(localized: "medical.alert.urgent.uppercase", defaultValue: "URGENT")
    static let critical = String(localized: "medical.alert.critical.uppercase", defaultValue: "CRITICAL")
    static let gpsLock = String(localized: "medical.alert.accuracy.gps_lock", defaultValue: "GPS Lock")
    static let estimated = String(localized: "medical.alert.accuracy.estimated", defaultValue: "Estimated")
    static let lastKnown = String(localized: "medical.alert.accuracy.last_known", defaultValue: "Last Known")
    static let acceptAccessibility = String(localized: "medical.alert_card.accept_accessibility_label", defaultValue: "Accept this alert")
    static let navigateAccessibility = String(localized: "medical.alert_card.navigate_accessibility_label", defaultValue: "Navigate to alert location")
    static let resolveAccessibility = String(localized: "medical.alert_card.resolve_accessibility_label", defaultValue: "Resolve this alert")
    static let previewNearPyramid = "Near Pyramid Stage, Section B"
    static let previewCampingArea = "Camping Area B, near showers"
    static let previewDizzy = "Feeling very dizzy and nauseous"
    static let previewMedic5 = "Medic-5"
    static let previewWestHolts = "West Holts area"
    static let previewMinorCut = "Minor cut, need first aid"

    static func alertID(_ shortID: String) -> String {
        String(
            format: String(localized: "medical.alert.identifier", defaultValue: "Alert #%@"),
            locale: Locale.current,
            shortID
        )
    }

    static func acceptedBy(_ callsign: String) -> String {
        String(
            format: String(localized: "medical.alert_card.accepted_by", defaultValue: "Accepted by %@"),
            locale: Locale.current,
            callsign
        )
    }

    static func accessibilityDescription(severity: String, elapsed: String, location: String) -> String {
        String(
            format: String(localized: "medical.alert_card.accessibility_label", defaultValue: "%@ alert, %@ elapsed, %@"),
            locale: Locale.current,
            severity,
            elapsed,
            location
        )
    }
}

// MARK: - AlertCard

/// Glass card for a single SOS alert in the medical dashboard.
///
/// Shows severity color, elapsed time, location description, and
/// Accept/Navigate/Resolve action buttons.
struct AlertCard: View {

    let alert: SOSAlertItem
    var onAccept: (() -> Void)?
    var onNavigate: (() -> Void)?
    var onResolve: (() -> Void)?

    @State private var elapsedText: String = ""
    @State private var isPulsing = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                // Header: severity + time
                headerRow

                // Location
                locationRow

                // Description
                if let description = alert.description {
                    Text(description)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .lineLimit(2)
                }

                // Status badge
                if let acceptedBy = alert.acceptedBy {
                    acceptedBadge(callsign: acceptedBy)
                }

                // Actions
                actionButtons
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(severityColor.opacity(0.3), lineWidth: 1.5)
        )
        .onAppear {
            updateElapsed()
            startPulseIfCritical()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: BlipSpacing.sm) {
            // Severity indicator
            ZStack {
                Circle()
                    .fill(severityColor.opacity(0.2))
                    .frame(width: 36, height: 36)

                Circle()
                    .fill(severityColor)
                    .frame(width: 12, height: 12)

                if alert.severity == .red && !SpringConstants.isReduceMotionEnabled {
                    Circle()
                        .stroke(severityColor.opacity(0.5), lineWidth: 1)
                        .frame(width: 36, height: 36)
                        .scaleEffect(isPulsing ? 1.4 : 1.0)
                        .opacity(isPulsing ? 0 : 0.5)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(severityLabel)
                    .font(theme.typography.body)
                    .fontWeight(.bold)
                    .foregroundStyle(severityColor)

                Text(AlertCardL10n.alertID(alert.shortID))
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }

            Spacer()

            // Elapsed time
            VStack(alignment: .trailing, spacing: 1) {
                Text(elapsedText)
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)
                    .monospacedDigit()

                Text(AlertCardL10n.elapsed)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - Location Row

    private var locationRow: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "location.fill")
                .font(.system(size: 12))
                .foregroundStyle(severityColor)

            Text(alert.locationDescription)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.text)

            Spacer()

            // Accuracy indicator
            accuracyBadge
        }
    }

    private var accuracyBadge: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: alert.accuracy.iconName)
                .font(.system(size: 10))
                .foregroundStyle(alert.accuracy.color)

            Text(alert.accuracy.label)
                .font(theme.typography.caption)
                .foregroundStyle(alert.accuracy.color)
        }
        .padding(.horizontal, BlipSpacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(alert.accuracy.color.opacity(0.12)))
    }

    // MARK: - Accepted Badge

    private func acceptedBadge(callsign: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blipAccentPurple)

            Text(AlertCardL10n.acceptedBy(callsign))
                .font(theme.typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(.blipAccentPurple)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.sm, style: .continuous)
                .fill(.blipAccentPurple.opacity(0.1))
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: BlipSpacing.sm) {
            if alert.acceptedBy == nil {
                Button(action: { onAccept?() }) {
                    Label(AlertCardL10n.accept, systemImage: "checkmark.circle.fill")
                        .font(theme.typography.secondary)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(
                            Capsule()
                                .fill(LinearGradient.blipAccent)
                        )
                }
                .frame(minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(AlertCardL10n.acceptAccessibility)
            }

            Button(action: { onNavigate?() }) {
                Label(AlertCardL10n.navigate, systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(.blipAccentPurple)
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.vertical, BlipSpacing.sm)
                    .background(
                        Capsule()
                            .fill(.blipAccentPurple.opacity(0.12))
                    )
            }
            .frame(minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(AlertCardL10n.navigateAccessibility)

            Spacer()

            if alert.acceptedBy != nil {
                Button(action: { onResolve?() }) {
                    Label(AlertCardL10n.resolve, systemImage: "checkmark.seal.fill")
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)
                        .foregroundStyle(BlipColors.darkColors.statusGreen)
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(
                            Capsule()
                                .fill(BlipColors.darkColors.statusGreen.opacity(0.12))
                        )
                }
                .frame(minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(AlertCardL10n.resolveAccessibility)
            }
        }
    }

    // MARK: - Helpers

    private var severityColor: Color {
        switch alert.severity {
        case .green: return BlipColors.darkColors.statusGreen
        case .amber: return BlipColors.darkColors.statusAmber
        case .red: return BlipColors.darkColors.statusRed
        }
    }

    private var severityLabel: String {
        switch alert.severity {
        case .green: return AlertCardL10n.nonUrgent
        case .amber: return AlertCardL10n.urgent
        case .red: return AlertCardL10n.critical
        }
    }

    private func updateElapsed() {
        let interval = Date().timeIntervalSince(alert.createdAt)
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        elapsedText = String(format: "%02d:%02d", minutes, seconds)
    }

    private func startPulseIfCritical() {
        guard alert.severity == .red, !SpringConstants.isReduceMotionEnabled else { return }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }

    private var accessibilityDescription: String {
        AlertCardL10n.accessibilityDescription(severity: severityLabel, elapsed: elapsedText, location: alert.locationDescription)
    }
}

// MARK: - SOSAlertItem

/// View-level data for an SOS alert card.
struct SOSAlertItem: Identifiable {
    let id: UUID
    let shortID: String
    let severity: SOSSeverity
    let locationDescription: String
    let description: String?
    let accuracy: LocationAccuracy
    let acceptedBy: String?
    let createdAt: Date
}

enum LocationAccuracy {
    case precise
    case estimated
    case lastKnown

    var iconName: String {
        switch self {
        case .precise: return "location.fill"
        case .estimated: return "location.circle"
        case .lastKnown: return "location.slash"
        }
    }

    var label: String {
        switch self {
        case .precise: return AlertCardL10n.gpsLock
        case .estimated: return AlertCardL10n.estimated
        case .lastKnown: return AlertCardL10n.lastKnown
        }
    }

    var color: Color {
        switch self {
        case .precise: return BlipColors.darkColors.statusGreen
        case .estimated: return BlipColors.darkColors.statusAmber
        case .lastKnown: return BlipColors.darkColors.statusRed
        }
    }
}

// MARK: - Preview

#Preview("Alert Cards") {
    ZStack {
        GradientBackground()
        ScrollView {
            VStack(spacing: BlipSpacing.md) {
                AlertCard(alert: SOSAlertItem(
                    id: UUID(),
                    shortID: "A7F3",
                    severity: .red,
                    locationDescription: AlertCardL10n.previewNearPyramid,
                    description: nil,
                    accuracy: .precise,
                    acceptedBy: nil,
                    createdAt: Date().addingTimeInterval(-180)
                ))

                AlertCard(alert: SOSAlertItem(
                    id: UUID(),
                    shortID: "B2E1",
                    severity: .amber,
                    locationDescription: AlertCardL10n.previewCampingArea,
                    description: AlertCardL10n.previewDizzy,
                    accuracy: .estimated,
                    acceptedBy: AlertCardL10n.previewMedic5,
                    createdAt: Date().addingTimeInterval(-420)
                ))

                AlertCard(alert: SOSAlertItem(
                    id: UUID(),
                    shortID: "C9D4",
                    severity: .green,
                    locationDescription: AlertCardL10n.previewWestHolts,
                    description: AlertCardL10n.previewMinorCut,
                    accuracy: .lastKnown,
                    acceptedBy: nil,
                    createdAt: Date().addingTimeInterval(-60)
                ))
            }
            .padding()
        }
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
