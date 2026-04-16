import SwiftUI
import MapKit

private enum StageMapViewL10n {
    static let recenter = String(localized: "events.map.recenter", defaultValue: "Recenter map on event")
    static let openStageChannel = String(localized: "events.map.stage.open_channel", defaultValue: "Tap to open stage channel")
    static let previewPyramid = "Pyramid"
    static let previewBicep = "Bicep"
    static let previewOther = "Other"
    static let previewWestHolts = "West Holts"
    static let previewFloatingPoints = "Floating Points"
    static let previewMeetingPoint = "Meet at tent"
    static let previewSarah = "Sarah"

    static func meetingPoint(_ label: String) -> String {
        String(
            format: String(localized: "events.map.meeting_point.accessibility", defaultValue: "Meeting point: %@"),
            locale: Locale.current,
            label
        )
    }
}

// MARK: - StageMapView

/// Interactive MapKit view rendering event grounds with stage hotspots,
/// friend dots overlay, and meeting point pins.
///
/// Stage hotspots are tappable and navigate to the corresponding stage channel.
/// Friend locations appear as colored dots with precision indicators.
struct StageMapView: View {

    let stages: [StageMapItem]
    let friends: [FriendMapPin]
    let meetingPoints: [MeetingPointMapItem]
    let eventCenter: CLLocationCoordinate2D
    let eventRadiusMeters: Double

    var onStageTap: ((StageMapItem) -> Void)?
    var onMeetingPointTap: ((MeetingPointMapItem) -> Void)?
    var onFriendTap: ((FriendMapPin) -> Void)?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedStage: StageMapItem?
    /// True after the very first `onAppear` recenter; used to skip the recenter
    /// when the user navigates back to this view, so we preserve their pan/zoom.
    @State private var didInitialCenter = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mapView

            // Recenter control
            Button(action: recenter) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .background(
                        Circle()
                            .fill(.thickMaterial)
                            .overlay(
                                Circle()
                                    .stroke(colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.1),
                                            lineWidth: BlipSizing.hairline)
                            )
                    )
            }
            .padding(BlipSpacing.md)
            .accessibilityLabel(StageMapViewL10n.recenter)
        }
        .onAppear {
            // Only recenter on the very first appearance. Re-appearing (after the
            // user pushes a stage detail and pops back) used to reset the map back
            // to the event boundary, throwing away their pan/zoom — frustrating
            // behaviour if they were studying a specific stage.
            guard !didInitialCenter else { return }
            didInitialCenter = true
            recenter()
        }
    }

    // MARK: - Map

    private var mapView: some View {
        Map(position: $cameraPosition) {
            // Event boundary circle
            MapCircle(center: eventCenter, radius: eventRadiusMeters)
                .foregroundStyle(.blipAccentPurple.opacity(0.05))
                .stroke(.blipAccentPurple.opacity(0.2), lineWidth: 1)

            // Stage hotspots
            ForEach(stages) { stage in
                Annotation(stage.name, coordinate: stage.coordinate, anchor: .bottom) {
                    StageHotspotView(stage: stage, isSelected: selectedStage?.id == stage.id) {
                        selectedStage = stage
                        onStageTap?(stage)
                    }
                }
            }

            // Friend dots
            ForEach(friends) { friend in
                Annotation(friend.displayName, coordinate: friend.coordinate) {
                    Button(action: { onFriendTap?(friend) }) {
                        Circle()
                            .fill(friend.color)
                            .frame(width: friend.precision == .precise ? 12 : 8, height: friend.precision == .precise ? 12 : 8)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: 1.5)
                            )
                            .shadow(color: friend.color.opacity(0.4), radius: 3)
                            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(friend.displayName), \(friend.precisionDescription)")
                }
            }

            // Meeting point pins
            ForEach(meetingPoints) { point in
                Annotation(point.label, coordinate: point.coordinate) {
                    Button(action: { onMeetingPointTap?(point) }) {
                        VStack(spacing: 0) {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.blipAccentPurple)

                            Text(point.label)
                                .font(theme.typography.caption)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 96)
                                .padding(.horizontal, BlipSpacing.xs)
                                .padding(.vertical, BlipSpacing.xxs)
                                .background(Capsule().fill(.blipAccentPurple))
                        }
                        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(StageMapViewL10n.meetingPoint(point.label))
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
    }

    // MARK: - Helpers

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

// MARK: - StageHotspotView

/// Tappable stage hotspot marker on the map.
private struct StageHotspotView: View {

    let stage: StageMapItem
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: isSelected ? 22 : 18, weight: .bold))
                    .foregroundStyle(.blipAccentPurple)
                    .shadow(color: .blipAccentPurple.opacity(0.5), radius: isSelected ? 6 : 2)

                Text(stage.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(
                        Capsule()
                            .fill(.thickMaterial)
                    )
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stage.name) stage")
        .accessibilityHint(StageMapViewL10n.openStageChannel)
    }
}

// MARK: - Data Models

struct StageMapItem: Identifiable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let isLive: Bool
    let currentArtist: String?
}

struct MeetingPointMapItem: Identifiable {
    let id: UUID
    let label: String
    let coordinate: CLLocationCoordinate2D
    let createdBy: String
    let expiresAt: Date
}

// MARK: - Preview

#Preview("Stage Map") {
    let stages: [StageMapItem] = [
        StageMapItem(id: UUID(), name: StageMapViewL10n.previewPyramid, coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), isLive: true, currentArtist: StageMapViewL10n.previewBicep),
        StageMapItem(id: UUID(), name: StageMapViewL10n.previewOther, coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845), isLive: false, currentArtist: nil),
        StageMapItem(id: UUID(), name: StageMapViewL10n.previewWestHolts, coordinate: CLLocationCoordinate2D(latitude: 51.0038, longitude: -2.5870), isLive: true, currentArtist: StageMapViewL10n.previewFloatingPoints),
    ]

    StageMapView(
        stages: stages,
        friends: NearbyView.sampleFriendPins,
        meetingPoints: [
            MeetingPointMapItem(id: UUID(), label: StageMapViewL10n.previewMeetingPoint, coordinate: CLLocationCoordinate2D(latitude: 51.0042, longitude: -2.5855), createdBy: StageMapViewL10n.previewSarah, expiresAt: Date().addingTimeInterval(1800)),
        ],
        eventCenter: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
        eventRadiusMeters: 3000
    )
    .frame(height: 400)
    .padding()
    .background(GradientBackground())
    .preferredColorScheme(.dark)
}
