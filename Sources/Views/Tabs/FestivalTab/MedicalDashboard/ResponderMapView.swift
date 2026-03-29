import SwiftUI
import MapKit

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
    let festivalCenter: CLLocationCoordinate2D
    let festivalRadiusMeters: Double

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
            // Festival boundary
            MapCircle(center: festivalCenter, radius: festivalRadiusMeters)
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
                Annotation("SOS", coordinate: alert.coordinate) {
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
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                        .background(Circle().fill(alert.severityColor))
                }
                .accessibilityLabel("Navigate to alert")

                Button(action: { selectedAlert = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.colors.mutedText)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                }
                .accessibilityLabel("Dismiss")
            }
        }
    }

    // MARK: - Controls

    private var recenterButton: some View {
        Button(action: recenter) {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .medium))
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
        .accessibilityLabel("Recenter map")
    }

    private var legendButton: some View {
        Menu {
            Section("SOS Severity") {
                Label("Critical", systemImage: "circle.fill").foregroundStyle(.red)
                Label("Urgent", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Non-Urgent", systemImage: "circle.fill").foregroundStyle(.green)
            }
            Section("Accuracy") {
                Label("GPS Lock", systemImage: "location.fill")
                Label("Estimated", systemImage: "location.circle")
                Label("Last Known", systemImage: "location.slash")
            }
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .medium))
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
        .accessibilityLabel("Map legend")
    }

    private func recenter() {
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: festivalCenter,
                    latitudinalMeters: festivalRadiusMeters * 2.5,
                    longitudinalMeters: festivalRadiusMeters * 2.5
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
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: false)) {
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

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 18))
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
        .accessibilityLabel("Medical tent: \(tent.name)")
    }
}

// MARK: - ResponderPinView

private struct ResponderPinView: View {

    let responder: ResponderPin

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blipAccentPurple)

            Text(responder.callsign)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.blipAccentPurple))
        }
        .accessibilityLabel("Responder: \(responder.callsign)")
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
    var coordinate: CLLocationCoordinate2D {
        // In production, derived from the alert's GPS data
        CLLocationCoordinate2D(latitude: 51.0043 + Double.random(in: -0.003...0.003),
                               longitude: -2.5856 + Double.random(in: -0.003...0.003))
    }

    var severityColor: Color {
        switch severity {
        case .green: return BlipColors.darkColors.statusGreen
        case .amber: return BlipColors.darkColors.statusAmber
        case .red: return BlipColors.darkColors.statusRed
        }
    }

    var severityLabel: String {
        switch severity {
        case .green: return "Non-Urgent"
        case .amber: return "Urgent"
        case .red: return "Critical"
        }
    }
}

// MARK: - Preview

#Preview("Responder Map") {
    let alerts: [SOSAlertItem] = [
        SOSAlertItem(id: UUID(), shortID: "A7F3", severity: .red, locationDescription: "Near Pyramid Stage", description: nil, accuracy: .precise, acceptedBy: nil, createdAt: Date().addingTimeInterval(-180)),
        SOSAlertItem(id: UUID(), shortID: "B2E1", severity: .amber, locationDescription: "Camping B", description: "Dizzy", accuracy: .estimated, acceptedBy: "Medic-5", createdAt: Date().addingTimeInterval(-420)),
    ]

    let tents: [MedicalTentPin] = [
        MedicalTentPin(id: UUID(), name: "Medical 1", coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5850)),
        MedicalTentPin(id: UUID(), name: "Medical 2", coordinate: CLLocationCoordinate2D(latitude: 51.0050, longitude: -2.5870)),
    ]

    ResponderMapView(
        alerts: alerts,
        medicalTents: tents,
        responderLocations: [
            ResponderPin(id: UUID(), callsign: "Medic-1", coordinate: CLLocationCoordinate2D(latitude: 51.0045, longitude: -2.5858), isOnDuty: true),
        ],
        festivalCenter: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
        festivalRadiusMeters: 3000
    )
    .frame(height: 400)
    .padding()
    .background(GradientBackground())
    .preferredColorScheme(.dark)
}
