import SwiftUI
import MapKit

private enum AlertDetailL10n {
    static let close = String(localized: "medical.alert_detail.close", defaultValue: "Close")
    static let resolveAlert = String(localized: "medical.alert_detail.resolve.title", defaultValue: "Resolve Alert")
    static let treatedOnSite = String(localized: "medical.alert_detail.resolve.treated_on_site", defaultValue: "Treated on Site")
    static let transported = String(localized: "medical.alert_detail.resolve.transported", defaultValue: "Transported")
    static let falseAlarm = String(localized: "medical.alert_detail.resolve.false_alarm", defaultValue: "False Alarm")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let accepted = String(localized: "medical.alert_detail.status.accepted", defaultValue: "ACCEPTED")
    static let active = String(localized: "medical.alert_detail.status.active", defaultValue: "ACTIVE")
    static let liveLocation = String(localized: "medical.alert_detail.live_location", defaultValue: "Live Location")
    static let sos = String(localized: "medical.alert_detail.map_annotation.sos", defaultValue: "SOS")
    static let details = String(localized: "medical.alert_detail.details", defaultValue: "Details")
    static let detailSeverity = String(localized: "medical.alert_detail.detail.severity", defaultValue: "Severity")
    static let detailLocation = String(localized: "medical.alert_detail.detail.location", defaultValue: "Location")
    static let detailGPSAccuracy = String(localized: "medical.alert_detail.detail.gps_accuracy", defaultValue: "GPS Accuracy")
    static let detailDescription = String(localized: "medical.alert_detail.detail.description", defaultValue: "Description")
    static let detailAcceptedBy = String(localized: "medical.alert_detail.detail.accepted_by", defaultValue: "Accepted By")
    static let responseTime = String(localized: "medical.alert_detail.response_time", defaultValue: "Response Time")
    static let acceptAlert = String(localized: "medical.alert_detail.action.accept", defaultValue: "Accept Alert")
    static let navigate = String(localized: "medical.alert_detail.action.navigate", defaultValue: "Navigate to Location")
    static let resolve = String(localized: "medical.alert_detail.action.resolve", defaultValue: "Resolve Alert")
    static let nonUrgent = String(localized: "medical.alert.severity.non_urgent", defaultValue: "Non-Urgent")
    static let urgent = String(localized: "medical.alert.severity.urgent", defaultValue: "Urgent")
    static let criticalEmergency = String(localized: "medical.alert.severity.critical_emergency", defaultValue: "Critical Emergency")
    static let previewNearPyramid = "Near Pyramid Stage, Section B, Row 12"
    static let previewCampingArea = "Camping Area B, near showers"
    static let previewDescription = "Feeling very dizzy and nauseous, has not eaten today"
    static let previewMedic5 = "Medic-5"

    static func alertTitle(_ shortID: String) -> String {
        String(format: String(localized: "medical.alert.identifier", defaultValue: "Alert #%@"), locale: Locale.current, shortID)
    }

    static func timer(_ minutes: Int, _ seconds: Int) -> String {
        String(format: String(localized: "medical.alert_detail.response_timer", defaultValue: "%02d:%02d"), locale: Locale.current, minutes, seconds)
    }
}

// MARK: - AlertDetailSheet

/// Full alert detail sheet showing live location, severity info,
/// and the response workflow (accept -> navigate -> resolve).
struct AlertDetailSheet: View {

    @Binding var isPresented: Bool

    let alert: SOSAlertItem

    var onAccept: (() -> Void)?
    var onNavigate: (() -> Void)?
    var onResolve: ((SOSResolution) -> Void)?

    @State private var showResolveOptions = false
    @State private var responseTimer: Int = 0
    @State private var timer: Timer?
    @State private var cameraPosition: MapCameraPosition = .automatic

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(spacing: BlipSpacing.lg) {
                        severityHeader
                        liveMapSection
                        detailsSection
                        responseTimerSection
                        workflowActions
                    }
                    .padding(BlipSpacing.md)
                }
            }
            .navigationTitle(AlertDetailL10n.alertTitle(alert.shortID))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AlertDetailL10n.close) { isPresented = false }
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
            .onAppear { startResponseTimer() }
            .onDisappear { timer?.invalidate() }
            .confirmationDialog(AlertDetailL10n.resolveAlert, isPresented: $showResolveOptions) {
                Button(AlertDetailL10n.treatedOnSite) { onResolve?(.treatedOnSite); isPresented = false }
                Button(AlertDetailL10n.transported) { onResolve?(.transported); isPresented = false }
                Button(AlertDetailL10n.falseAlarm) { onResolve?(.falseAlarm); isPresented = false }
                Button(AlertDetailL10n.cancel, role: .cancel) {}
            }
        }
    }

    // MARK: - Severity Header

    private var severityHeader: some View {
        GlassCard(thickness: .regular) {
            HStack(spacing: BlipSpacing.md) {
                // Severity badge
                ZStack {
                    Circle()
                        .fill(severityColor.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: "cross.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(severityColor)
                }

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(severityLabel)
                        .font(theme.typography.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(severityColor)

                    Text(AlertDetailL10n.alertTitle(alert.shortID))
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)

                    Text(alert.createdAt, style: .relative)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText.opacity(0.7))
                }

                Spacer()

                // Status
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        let (text, color) = statusInfo
        return Text(text)
            .font(theme.typography.caption)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var statusInfo: (String, Color) {
        if alert.acceptedBy != nil {
            return (AlertDetailL10n.accepted, .blipAccentPurple)
        }
        return (AlertDetailL10n.active, severityColor)
    }

    // MARK: - Live Map Section

    private var liveMapSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                HStack {
                    Image(systemName: "location.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(severityColor)

                    Text(AlertDetailL10n.liveLocation)
                        .font(theme.typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.colors.text)

                    Spacer()

                    // Accuracy indicator
                    HStack(spacing: BlipSpacing.xs) {
                        Image(systemName: alert.accuracy.iconName)
                            .font(.system(size: 10))
                        Text(alert.accuracy.label)
                            .font(theme.typography.caption)
                    }
                    .foregroundStyle(alert.accuracy.color)
                }

                Map(position: $cameraPosition) {
                    Annotation(AlertDetailL10n.sos, coordinate: alert.coordinate) {
                        ZStack {
                            // Accuracy circle
                            if alert.accuracy == .estimated {
                                Circle()
                                    .fill(severityColor.opacity(0.1))
                                    .frame(width: 60, height: 60)
                                    .overlay(
                                        Circle()
                                            .stroke(severityColor.opacity(0.3), lineWidth: 1)
                                    )
                            } else if alert.accuracy == .lastKnown {
                                Circle()
                                    .fill(severityColor.opacity(0.05))
                                    .frame(width: 80, height: 80)
                                    .overlay(
                                        Circle()
                                            .stroke(severityColor.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    )
                            }

                            // Pin
                            Circle()
                                .fill(severityColor)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Image(systemName: "cross.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                                .shadow(color: severityColor.opacity(0.5), radius: 4)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))

                Text(alert.locationDescription)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                Text(AlertDetailL10n.details)
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                detailRow(label: AlertDetailL10n.detailSeverity, value: severityLabel, color: severityColor)
                detailRow(label: AlertDetailL10n.detailLocation, value: alert.locationDescription, color: theme.colors.text)
                detailRow(label: AlertDetailL10n.detailGPSAccuracy, value: alert.accuracy.label, color: alert.accuracy.color)

                if let description = alert.description {
                    detailRow(label: AlertDetailL10n.detailDescription, value: description, color: theme.colors.text)
                }

                if let acceptedBy = alert.acceptedBy {
                    detailRow(label: AlertDetailL10n.detailAcceptedBy, value: acceptedBy, color: .blipAccentPurple)
                }
            }
        }
    }

    private func detailRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(theme.typography.secondary)
                .foregroundStyle(color)

            Spacer()
        }
    }

    // MARK: - Response Timer

    private var responseTimerSection: some View {
        GlassCard(thickness: .ultraThin) {
            HStack {
                Image(systemName: "timer")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.colors.mutedText)

                Text(AlertDetailL10n.responseTime)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)

                Spacer()

                Text(formattedTime)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.colors.text)
                    .contentTransition(.numericText())
            }
        }
    }

    private var formattedTime: String {
        let minutes = responseTimer / 60
        let seconds = responseTimer % 60
        return AlertDetailL10n.timer(minutes, seconds)
    }

    // MARK: - Workflow Actions

    private var workflowActions: some View {
        VStack(spacing: BlipSpacing.md) {
            if alert.acceptedBy == nil {
                GlassButton(AlertDetailL10n.acceptAlert, icon: "checkmark.circle.fill") {
                    onAccept?()
                }
                .fullWidth()
            }

            GlassButton(AlertDetailL10n.navigate, icon: "arrow.triangle.turn.up.right.diamond.fill", style: .secondary) {
                onNavigate?()
            }
            .fullWidth()

            if alert.acceptedBy != nil {
                GlassButton(AlertDetailL10n.resolve, icon: "checkmark.seal.fill", style: .outline) {
                    showResolveOptions = true
                }
                .fullWidth()
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
        case .green: return AlertDetailL10n.nonUrgent
        case .amber: return AlertDetailL10n.urgent
        case .red: return AlertDetailL10n.criticalEmergency
        }
    }

    private func startResponseTimer() {
        let elapsed = Int(Date().timeIntervalSince(alert.createdAt))
        responseTimer = elapsed

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                responseTimer += 1
            }
        }
    }
}

// MARK: - Preview

#Preview("Alert Detail - Active") {
    AlertDetailSheet(
        isPresented: .constant(true),
        alert: SOSAlertItem(
            id: UUID(),
            shortID: "A7F3",
            severity: .red,
            locationDescription: AlertDetailL10n.previewNearPyramid,
            description: nil,
            accuracy: .precise,
            acceptedBy: nil,
            createdAt: Date().addingTimeInterval(-180)
        )
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Alert Detail - Accepted") {
    AlertDetailSheet(
        isPresented: .constant(true),
        alert: SOSAlertItem(
            id: UUID(),
            shortID: "B2E1",
            severity: .amber,
            locationDescription: AlertDetailL10n.previewCampingArea,
            description: AlertDetailL10n.previewDescription,
            accuracy: .estimated,
            acceptedBy: AlertDetailL10n.previewMedic5,
            createdAt: Date().addingTimeInterval(-420)
        )
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}
