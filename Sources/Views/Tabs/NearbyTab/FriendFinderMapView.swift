import SwiftUI
import MapKit

// MARK: - FriendFinderMapView

/// Full-screen friend finder with map, "I'm Here" beacon toggle,
/// precision radius rings, and a bottom sheet friend list.
///
/// Uses sample data until John wires up LocationService.
struct FriendFinderMapView: View {

    @State private var friends: [FriendMapPin] = Self.sampleFriends
    @State private var beacons: [BeaconPin] = []
    @State private var isSharingLocation = false
    @State private var selectedFriend: FriendMapPin? = nil
    @State private var showFriendList = true
    @State private var showCrowdPulse = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var sharingPulse = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let userLocation = CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856)

    /// Map region for crowd pulse coordinate normalization.
    private var crowdPulseRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: userLocation,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Map layer
            mapLayer

            // Crowd pulse overlay
            if showCrowdPulse {
                CrowdPulseOverlay(
                    pulseData: Self.sampleCrowdPulse,
                    mapRegion: crowdPulseRegion
                )
                .transition(.opacity)
            }

            // Controls
            VStack {
                HStack {
                    Spacer()
                    controlButtons
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.top, BlipSpacing.sm)

                Spacer()
            }

            // Crowd pulse legend
            if showCrowdPulse {
                VStack {
                    CrowdPulseLegend()
                        .padding(.horizontal, BlipSpacing.md)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Spacer()
                }
                .padding(.top, 52)
            }

            // Friend list bottom sheet
            if showFriendList {
                friendListSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Friend Finder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Map Layer

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            // User location with "I'm Here" pulse
            Annotation("You", coordinate: userLocation) {
                userPinView
            }

            // Friend pins
            ForEach(friends.filter({ !$0.isOutOfRange })) { friend in
                Annotation(friend.displayName, coordinate: friend.coordinate) {
                    FriendFinderPinView(
                        friend: friend,
                        isSelected: selectedFriend?.id == friend.id
                    ) {
                        withAnimation(SpringConstants.accessiblePageEntrance) {
                            selectedFriend = friend
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: friend.coordinate,
                                distance: 500
                            ))
                        }
                    }
                }
            }

            // Beacons
            ForEach(beacons) { beacon in
                Annotation(beacon.label, coordinate: beacon.coordinate) {
                    BeaconAnnotationView(beacon: beacon)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - User Pin

    private var userPinView: some View {
        ZStack {
            // Sharing pulse ring
            if isSharingLocation, !SpringConstants.isReduceMotionEnabled {
                Circle()
                    .stroke(.blipAccentPurple.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .scaleEffect(sharingPulse ? 1.8 : 1.0)
                    .opacity(sharingPulse ? 0 : 0.6)
            }

            Circle()
                .fill(.blipAccentPurple.opacity(0.2))
                .frame(width: 44, height: 44)

            Circle()
                .fill(.blipAccentPurple)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .blipAccentPurple.opacity(0.5), radius: 6)
        }
        .onAppear {
            guard isSharingLocation, !SpringConstants.isReduceMotionEnabled else { return }
            startSharingPulse()
        }
        .onChange(of: isSharingLocation) { _, sharing in
            if sharing {
                startSharingPulse()
            } else {
                sharingPulse = false
            }
        }
        .accessibilityLabel(isSharingLocation ? "Your location, sharing active" : "Your location")
    }

    private func startSharingPulse() {
        guard !SpringConstants.isReduceMotionEnabled else { return }
        withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
            sharingPulse = true
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        VStack(spacing: BlipSpacing.sm) {
            // Recenter
            mapButton(icon: "location.fill", label: "Recenter") {
                withAnimation { cameraPosition = .automatic }
            }

            // Toggle location sharing
            mapButton(
                icon: isSharingLocation ? "location.fill.viewfinder" : "location.viewfinder",
                label: isSharingLocation ? "Stop sharing" : "Share location",
                isActive: isSharingLocation
            ) {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    isSharingLocation.toggle()
                }
            }

            // Drop beacon
            mapButton(icon: "mappin.and.ellipse", label: "Drop beacon", isAccent: true) {
                let beacon = BeaconPin(
                    id: UUID(),
                    label: "I'm here!",
                    coordinate: userLocation,
                    createdBy: "You",
                    expiresAt: Date().addingTimeInterval(1800)
                )
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    beacons.append(beacon)
                }
            }

            // Crowd pulse overlay
            mapButton(
                icon: showCrowdPulse ? "aqi.medium" : "aqi.low",
                label: showCrowdPulse ? "Hide crowd" : "Show crowd",
                isActive: showCrowdPulse
            ) {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    showCrowdPulse.toggle()
                }
            }

            // Toggle friend list
            mapButton(
                icon: showFriendList ? "list.bullet.circle.fill" : "list.bullet.circle",
                label: showFriendList ? "Hide list" : "Show list"
            ) {
                withAnimation(SpringConstants.accessiblePageEntrance) {
                    showFriendList.toggle()
                }
            }
        }
    }

    private func mapButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        isAccent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isAccent ? .white : (isActive ? .white : .blipAccentPurple))
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(isAccent ? AnyShapeStyle(LinearGradient.blipAccent) :
                              isActive ? AnyShapeStyle(Color.blipAccentPurple) :
                              AnyShapeStyle(.thickMaterial))
                        .overlay(
                            Circle()
                                .stroke(
                                    colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.1),
                                    lineWidth: BlipSizing.hairline
                                )
                        )
                )
        }
        .accessibilityLabel(label)
    }

    // MARK: - Friend List Sheet

    private var friendListSheet: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(theme.colors.mutedText.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, BlipSpacing.sm)

            // Header
            HStack {
                Text("Friends")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text("\(friends.filter { !$0.isOutOfRange }.count) nearby")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)

            Divider()
                .overlay(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))

            // Friend rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(friends) { friend in
                        friendRow(friend)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(
                    colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08),
                    lineWidth: BlipSizing.hairline
                )
        )
        .padding(.horizontal, BlipSpacing.sm)
        .padding(.bottom, BlipSpacing.sm)
    }

    private func friendRow(_ friend: FriendMapPin) -> some View {
        Button {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                selectedFriend = friend
                if !friend.isOutOfRange {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: friend.coordinate,
                        distance: 500
                    ))
                }
            }
        } label: {
            HStack(spacing: BlipSpacing.md) {
                AvatarView(
                    imageData: friend.avatarData,
                    name: friend.displayName,
                    size: 40,
                    ringStyle: .friend,
                    showOnlineIndicator: !friend.isOutOfRange
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    if friend.isOutOfRange {
                        Text("Out of range")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.statusRed)
                    } else {
                        HStack(spacing: BlipSpacing.xs) {
                            // Accuracy indicator dot
                            Circle()
                                .fill(friend.accuracyColor)
                                .frame(width: 6, height: 6)

                            Text(friend.lastSeenText)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)

                            if let distance = friend.distanceText {
                                Text("·")
                                    .foregroundStyle(theme.colors.mutedText)
                                Text(distance)
                                    .font(theme.typography.caption)
                                    .foregroundStyle(theme.colors.mutedText)
                            }
                        }
                    }
                }

                Spacer()

                if !friend.isOutOfRange {
                    Image(systemName: "location.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.blipAccentPurple)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                selectedFriend?.id == friend.id
                    ? theme.colors.hover
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(friend.displayName), \(friend.isOutOfRange ? "out of range" : friend.lastSeenText)")
    }
}

// MARK: - Friend Finder Pin View (standalone, not using FriendFinderMap's internal)

private struct FriendFinderPinView: View {

    let friend: FriendMapPin
    let isSelected: Bool
    let onTap: () -> Void

    @State private var ringPulsing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Accuracy radius ring
                if friend.precision == .precise, friend.accuracyMeters > 0 {
                    Circle()
                        .fill(friend.accuracyColor.opacity(0.08))
                        .frame(width: ringSize, height: ringSize)
                        .overlay(
                            Circle()
                                .stroke(friend.accuracyColor.opacity(0.3), lineWidth: 1)
                        )
                        .scaleEffect(ringPulsing ? 1.05 : 1.0)
                }

                if friend.precision == .fuzzy {
                    Circle()
                        .fill(friend.color.opacity(0.1))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(friend.color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }

                VStack(spacing: 2) {
                    AvatarView(
                        imageData: friend.avatarData,
                        name: friend.displayName,
                        size: isSelected ? 36 : 28,
                        ringStyle: .friend,
                        showOnlineIndicator: true
                    )
                    .shadow(color: friend.color.opacity(0.4), radius: 4)

                    if isSelected {
                        VStack(spacing: 1) {
                            Text(friend.displayName)
                                .font(.system(size: 10, weight: .semibold))

                            if let distance = friend.distanceText {
                                Text(distance)
                                    .font(.system(size: 9, weight: .regular))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(friend.color))
                    }
                }
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(friend.displayName), \(friend.lastSeenText)")
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled, friend.accuracyMeters > 0 else { return }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                ringPulsing = true
            }
        }
    }

    private var ringSize: CGFloat {
        let clamped = min(max(friend.accuracyMeters, 10), 100)
        return CGFloat(clamped * 0.6 + 20)
    }
}

// MARK: - Beacon Annotation View

private struct BeaconAnnotationView: View {

    let beacon: BeaconPin
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if !SpringConstants.isReduceMotionEnabled {
                Circle()
                    .stroke(.blipAccentPurple.opacity(0.3), lineWidth: 1)
                    .frame(width: 36, height: 36)
                    .scaleEffect(isPulsing ? 1.5 : 1.0)
                    .opacity(isPulsing ? 0 : 0.5)
            }

            VStack(spacing: 0) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blipAccentPurple)

                Text(beacon.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.blipAccentPurple))
            }
        }
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityLabel("Beacon: \(beacon.label)")
    }
}

// MARK: - Sample Data

extension FriendFinderMapView {

    /// Sample crowd density data for simulator testing.
    static let sampleCrowdPulse: [CrowdPulseCell] = [
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), level: .packed, peerCount: 320, geohash: "gcpu2e1"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845), level: .busy, peerCount: 180, geohash: "gcpu2e2"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870), level: .moderate, peerCount: 80, geohash: "gcpu2e3"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0060, longitude: -2.5830), level: .quiet, peerCount: 15, geohash: "gcpu2e4"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0035, longitude: -2.5855), level: .busy, peerCount: 150, geohash: "gcpu2e5"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0050, longitude: -2.5840), level: .moderate, peerCount: 65, geohash: "gcpu2e6"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0042, longitude: -2.5880), level: .packed, peerCount: 280, geohash: "gcpu2e7"),
        CrowdPulseCell(id: UUID(), coordinate: CLLocationCoordinate2D(latitude: 51.0058, longitude: -2.5855), level: .quiet, peerCount: 22, geohash: "gcpu2e8"),
    ]

    static let sampleFriends: [FriendMapPin] = [
        FriendMapPin(
            id: UUID(), displayName: "Sarah Chen",
            coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862),
            precision: .precise, color: .blue,
            lastUpdated: Date().addingTimeInterval(-120),
            accuracyMeters: 5, distanceFromUser: 45
        ),
        FriendMapPin(
            id: UUID(), displayName: "Jake Morrison",
            coordinate: CLLocationCoordinate2D(latitude: 51.0052, longitude: -2.5850),
            precision: .precise, color: .green,
            lastUpdated: Date().addingTimeInterval(-30),
            accuracyMeters: 8, distanceFromUser: 120
        ),
        FriendMapPin(
            id: UUID(), displayName: "Priya Patel",
            coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
            precision: .fuzzy, color: .orange,
            lastUpdated: Date().addingTimeInterval(-600),
            accuracyMeters: 40, distanceFromUser: 280
        ),
        FriendMapPin(
            id: UUID(), displayName: "Alex Rivera",
            coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845),
            precision: .precise, color: .purple,
            lastUpdated: Date().addingTimeInterval(-3600),
            accuracyMeters: 80, distanceFromUser: 500,
            isOutOfRange: true
        ),
        FriendMapPin(
            id: UUID(), displayName: "Mia Kim",
            coordinate: CLLocationCoordinate2D(latitude: 51.0035, longitude: -2.5860),
            precision: .off, color: .gray,
            lastUpdated: Date().addingTimeInterval(-7200),
            isOutOfRange: true
        ),
    ]
}

// MARK: - Preview

#Preview("Friend Finder Map") {
    NavigationStack {
        FriendFinderMapView()
    }
    .preferredColorScheme(.dark)
    .environment(\.theme, Theme.shared)
}

#Preview("Friend Finder Map - Light") {
    NavigationStack {
        FriendFinderMapView()
    }
    .preferredColorScheme(.light)
    .environment(\.theme, Theme.resolved(for: .light))
}
