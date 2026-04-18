import SwiftUI
import MapKit

private enum ResponderMapL10n {
    static let sos = String(localized: "medical.responder_map.sos", defaultValue: "SOS")
    static let navigateToAlert = String(localized: "medical.responder_map.navigate_accessibility_label", defaultValue: "Navigate to alert")
    static let dismiss = String(localized: "common.dismiss", defaultValue: "Dismiss")
    static let recenterMap = String(localized: "medical.responder_map.recenter", defaultValue: "Recenter map")
    static let mapLegend = String(localized: "medical.responder_map.legend.accessibility_label", defaultValue: "Map legend")
    static let severitySection = String(localized: "medical.responder_map.legend.severity", defaultValue: "SOS Severity")
    static let critical = String(localized: "medical.alert.severity.critical", defaultValue: "Critical")
    static let urgent = String(localized: "medical.alert.severity.urgent", defaultValue: "Urgent")
    static let nonUrgent = String(localized: "medical.alert.severity.non_urgent", defaultValue: "Non-Urgent")
    static let accuracySection = String(localized: "medical.responder_map.legend.accuracy", defaultValue: "Accuracy")
    static let gpsLock = String(localized: "medical.alert.accuracy.gps_lock", defaultValue: "GPS Lock")
    static let estimated = String(localized: "medical.alert.accuracy.estimated", defaultValue: "Estimated")
    static let lastKnown = String(localized: "medical.alert.accuracy.last_known", defaultValue: "Last Known")
    static let previewNearPyramid = "Near Pyramid Stage"
    static let previewCampingB = "Camping B"
    static let previewDizzy = "Dizzy"
    static let previewMedic5 = "Medic-5"
    static let previewMedical1 = "Medical 1"
    static let previewMedical2 = "Medical 2"
    static let previewMedic1 = "Medic-1"

    static func medicalTent(_ name: String) -> String {
        String(format: String(localized: "medical.responder_map.medical_tent_accessibility_label", defaultValue: "Medical tent: %@"), locale: Locale.current, name)
    }

    static func responder(_ callsign: String) -> String {
        String(format: String(localized: "medical.responder_map.responder_accessibility_label", defaultValue: "Responder: %@"), locale: Locale.current, callsign)
    }
}

// MARK: - ResponderMapView

/// MapKit view for medical responders showing SOS pins, medical tents,
/// walking routes, and accuracy rings.
///
/// SOS pins pulse by severity:
/// - Red: continuous pulsing
/// - Amber: slow pulse
/// - Green: static
///
/// Accuracy indicators:
/// - Solid pin = GPS lock (+-5m)
/// - Pulsing circle = estimated (+-40m)
/// - Dashed circle = last-known (stale)
struct ResponderMapView: View {

    let alerts: [SOSAlertItem]
    let medicalTents: [MedicalTentPin]
    let responderLocations: [ResponderPin]
    let eventCenter: CLLocationCoordinate2D
    let eventRadiusMeters: Double

    var onAlertTap: ((SOSAlertItem) -> Void)?
    var onNavigateToAlert: ((SOSAlertItem) -> Void)?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedAlert: SOSAlertItem?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mapContent

            // Controls
            VStack(spacing: BlipSpacing.sm) {
                recenterButton

                // Legend
                legendButton
            }
            .padding(BlipSpacing.md)
        }
        .onAppear { recenter() }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            // Event boundary
            MapCircle(center: eventCenter, radius: eventRadiusMeters)
                .foregroundStyle(.blipAccentPurple.opacity(0.03))
                .stroke(.blipAccentPurple.opacity(0.15), lineWidth: 1)

            // Medical tent locations
            ForEach(medicalTents) { tent in
                Annotation(tent.name, coordinate: tent.coordinate) {
                    MedicalTentPinView(tent: tent)
                }
            }

            // SOS alert pins
            ForEach(alerts) { alert in
                Annotation(ResponderMapL10n.sos, coordinate: alert.coordinate(relativeTo: eventCenter)) {
                    SOSPinView(alert: alert) {
                        selectedAlert = alert
                        onAlertTap?(alert)
                    }
                }
            }

            // Responder locations
            ForEach(responderLocations) { responder in
                Annotation(responder.callsign, coordinate: responder.coordinate) {
                    ResponderPinView(responder: responder)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(
                    colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08),
                    lineWidth: BlipSizing.hairline
                )
        )
        .overlay(alignment: .bottom) {
            if let alert = selectedAlert {
                alertQuickCard(for: alert)
                    .padding(BlipSpacing.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: selectedAlert?.id)
    }

    // MARK: - Alert Quick Card

    @ViewBuilder
    private func alertQuickCard(for alert: SOSAlertItem) -> some View {
        GlassCard(thickness: .thick, cornerRadius: BlipCornerRadius.xl) {
            HStack(spacing: BlipSpacing.md) {
                Circle()
                    .fill(alert.severityColor)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(alert.severityLabel) - #\(alert.shortID)")
                        .font(theme.typography.secondary)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.colors.text)

                    Text(alert.locationDescription)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Button(action: {
                    onNavigateToAlert?(alert)
                }) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(theme.typography.body)
                        .foregroundStyle(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                        .background(Circle().fill(alert.severityColor))
                }
                .accessibilityLabel(ResponderMapL10n.navigateToAlert)

                Button(action: { selectedAlert = nil }) {
                    Image(systemName: "xmark")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                }
                .accessibilityLabel(ResponderMapL10n.dismiss)
            }
        }
    }

    // MARK: - Controls

    private var recenterButton: some View {
        Button(action: recenter) {
            Image(systemName: "scope")
                .font(theme.typography.callout)
                .foregroundStyle(.blipAccentPurple)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(.thickMaterial)
                        .overlay(Circle().stroke(
                            colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.1),
                            lineWidth: BlipSizing.hairline
                        ))
                )
        }
        .accessibilityLabel(ResponderMapL10n.recenterMap)
    }

    private var legendButton: some View {
        Menu {
            Section(ResponderMapL10n.severitySection) {
                Label(ResponderMapL10n.critical, systemImage: "circle.fill").foregroundStyle(.red)
                Label(ResponderMapL10n.urgent, systemImage: "circle.fill").foregroundStyle(.orange)
                Label(ResponderMapL10n.nonUrgent, systemImage: "circle.fill").foregroundStyle(.green)
            }
            Section(ResponderMapL10n.accuracySection) {
                Label(ResponderMapL10n.gpsLock, systemImage: "location.fill")
                Label(ResponderMapL10n.estimated, systemImage: "location.circle")
                Label(ResponderMapL10n.lastKnown, systemImage: "location.slash")
            }
        } label: {
            Image(systemName: "info.circle")
                .font(theme.typography.callout)
                .foregroundStyle(theme.colors.mutedText)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(.thickMaterial)
                        .overlay(Circle().stroke(
                            colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.1),
                            lineWidth: BlipSizing.hairline
                        ))
                )
        }
        .accessibilityLabel(ResponderMapL10n.mapLegend)
    }

    private func recenter() {
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: eventCenter,
                    latitudinalMeters: eventRadiusMeters * 2.5,
                    longitudinalMeters: eventRadiusMeters * 2.5
                )
            )
        }
    }
}

// MARK: - SOSPinView

/// SOS pin on the responder map with severity-based pulsing.
private struct SOSPinView: View {

    let alert: SOSAlertItem
    let onTap: () -> Void

    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Accuracy ring
                accuracyRing

                // Pulse ring (red/amber only)
                if alert.severity != .green && !SpringConstants.isReduceMotionEnabled {
                    Circle()
                        .stroke(alert.severityColor.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 36, height: 36)
                        .scaleEffect(isPulsing ? 1.8 : 1.0)
                        .opacity(isPulsing ? 0 : 0.6)
                }

                // Pin dot
                Circle()
                    .fill(alert.severityColor)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: "cross.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: alert.severityColor.opacity(0.5), radius: 4)
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard alert.severity != .green, !SpringConstants.isReduceMotionEnabled else { return }
            let duration = alert.severity == .red ? 1.0 : 2.0
            withAnimation(SpringConstants.gentleAnimation.repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityLabel("\(alert.severityLabel) SOS alert, \(alert.accuracy.label) accuracy")
    }

    @ViewBuilder
    private var accuracyRing: some View {
        switch alert.accuracy {
        case .precise:
            EmptyView()
        case .estimated:
            Circle()
                .stroke(alert.severityColor.opacity(0.2), lineWidth: 1)
                .frame(width: 50, height: 50)
        case .lastKnown:
            Circle()
                .stroke(alert.severityColor.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: 60, height: 60)
        }
    }
}

// MARK: - MedicalTentPinView

private struct MedicalTentPinView: View {

    let tent: MedicalTentPin

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cross.case.fill")
                .font(theme.typography.body)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.red)
                )

            Text(tent.name)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.white))
        }
        .accessibilityLabel(ResponderMapL10n.medicalTent(tent.name))
    }
}

// MARK: - ResponderPinView

private struct ResponderPinView: View {

    let responder: ResponderPin

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(theme.typography.callout)
                .foregroundStyle(.blipAccentPurple)

            Text(responder.callsign)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.blipAccentPurple))
        }
        .accessibilityLabel(ResponderMapL10n.responder(responder.callsign))
    }
}

// MARK: - Data Models

struct MedicalTentPin: Identifiable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct ResponderPin: Identifiable {
    let id: UUID
    let callsign: String
    let coordinate: CLLocationCoordinate2D
    let isOnDuty: Bool
}

extension SOSAlertItem {
    /// Returns a stable coordinate derived deterministically from the alert's UUID.
    /// Without real GPS lat/lng fields on SOSAlertItem, we use the UUID bytes
    /// to produce a repeatable offset so pins never jump between re-renders.
    func coordinate(relativeTo center: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let uuidBytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        // Use first 8 bytes for latitude offset, next 8 for longitude offset
        let latSeed = uuidBytes.prefix(8).enumerated().reduce(0.0) { acc, pair in
            acc + Double(pair.element) / pow(256.0, Double(pair.offset + 1))
        }
        let lonSeed = uuidBytes.suffix(8).enumerated().reduce(0.0) { acc, pair in
            acc + Double(pair.element) / pow(256.0, Double(pair.offset + 1))
        }
        // Map [0,1) range to [-0.003, 0.003) for ~300m spread
        let latOffset = (latSeed - 0.5) * 0.006
        let lonOffset = (lonSeed - 0.5) * 0.006
        return CLLocationCoordinate2D(
            latitude: center.latitude + latOffset,
            longitude: center.longitude + lonOffset
        )
    }

    var severityColor: Color {
        switch severity {
        case .green: return BlipColors.adaptive.statusGreen
        case .amber: return BlipColors.adaptive.statusAmber
        case .red: return BlipColors.adaptive.statusRed
        }
    }

    var severityLabel: String {
        switch severity {
        case .green: return ResponderMapL10n.nonUrgent
        case .amber: return ResponderMapL10n.urgent
        case .red: return ResponderMapL10n.critical
        }
    }
}

// MARK: - Preview

#Preview("Responder Map") {
    let alerts: [SOSAlertItem] = [
        SOSAlertItem(id: UUID(), shortID: "A7F3", severity: .red, locationDescription: ResponderMapL10n.previewNearPyramid, description: nil, accuracy: .precise, acceptedBy: nil, createdAt: Date().addingTimeInterval(-180)),
        SOSAlertItem(id: UUID(), shortID: "B2E1", severity: .amber, locationDescription: ResponderMapL10n.previewCampingB, description: ResponderMapL10n.previewDizzy, accuracy: .estimated, acceptedBy: ResponderMapL10n.previewMedic5, createdAt: Date().addingTimeInterval(-420)),
    ]

    let tents: [MedicalTentPin] = [
        MedicalTentPin(id: UUID(), name: ResponderMapL10n.previewMedical1, coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5850)),
        MedicalTentPin(id: UUID(), name: ResponderMapL10n.previewMedical2, coordinate: CLLocationCoordinate2D(latitude: 51.0050, longitude: -2.5870)),
    ]

    ResponderMapView(
        alerts: alerts,
        medicalTents: tents,
        responderLocations: [
            ResponderPin(id: UUID(), callsign: ResponderMapL10n.previewMedic1, coordinate: CLLocationCoordinate2D(latitude: 51.0045, longitude: -2.5858), isOnDuty: true),
        ],
        eventCenter: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
        eventRadiusMeters: 3000
    )
    .frame(height: 400)
    .padding()
    .background(GradientBackground())
    .preferredColorScheme(.dark)
}
