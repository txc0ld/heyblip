import SwiftUI
import MapKit

private enum FriendFinderMapL10n {
    static let you = String(localized: "nearby.friend_finder.map.you", defaultValue: "You")
    static let yourLocation = String(localized: "nearby.friend_finder.map.your_location", defaultValue: "Your location")
    static let recenterMap = String(localized: "nearby.friend_finder.map.recenter", defaultValue: "Recenter map")
    static let dropBeaconAccessibility = String(localized: "nearby.friend_finder.map.drop_beacon_accessibility_label", defaultValue: "Drop I'm Here beacon")
    static let dropBeaconTitle = String(localized: "nearby.friend_finder.map.drop_beacon.title", defaultValue: "Drop Beacon")
    static let dropHere = String(localized: "nearby.friend_finder.map.drop_beacon.confirm", defaultValue: "Drop Here")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let dropBeaconMessage = String(localized: "nearby.friend_finder.map.drop_beacon.message", defaultValue: "Share your current location as a beacon. It will expire in 30 minutes.")
    static let preciseLocation = String(localized: "nearby.friend_finder.precision.precise", defaultValue: "Precise location")
    static let approximateArea = String(localized: "nearby.friend_finder.precision.fuzzy", defaultValue: "Approximate area")
    static let locationHidden = String(localized: "nearby.friend_finder.precision.off", defaultValue: "Location hidden")
    static let justNow = String(localized: "common.time.just_now", defaultValue: "Just now")
    static let overDayAgo = String(localized: "common.time.over_day_ago", defaultValue: "Over a day ago")
    static let close = String(localized: "common.close", defaultValue: "Close")
    static let previewSarah = "Sarah"
    static let previewJake = "Jake"
    static let previewMeetHere = "Meet here!"

    static func navigateToFriend(_ name: String) -> String {
        String(format: String(localized: "nearby.friend_finder.map.navigate_accessibility_label", defaultValue: "Navigate to %@"), locale: Locale.current, name)
    }

    static func beacon(_ label: String) -> String {
        String(format: String(localized: "nearby.friend_finder.map.beacon_accessibility_label", defaultValue: "Beacon: %@"), locale: Locale.current, label)
    }
}

// MARK: - FriendFinderMap

/// MapKit view showing friend locations on the event map.
///
/// Features:
/// - Colored pins per friend with precision indicators (solid pin vs fuzzy circle)
/// - "I'm here" beacon drop
/// - Navigate button for walking directions
/// - Breadcrumb trails (opt-in)
///
/// All interactive elements have 44pt minimum tap targets and VoiceOver support.
struct FriendFinderMap: View {

    let friends: [FriendMapPin]
    let userLocation: CLLocationCoordinate2D?
    let beacons: [BeaconPin]

    var onDropBeacon: ((CLLocationCoordinate2D) -> Void)?
    var onNavigateToFriend: ((FriendMapPin) -> Void)?
    var onFriendTap: ((FriendMapPin) -> Void)?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedFriend: FriendMapPin?
    @State private var showBeaconConfirm = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mapContent

            // Controls overlay
            VStack(spacing: BlipSpacing.sm) {
                recenterButton
                dropBeaconButton
            }
            .padding(BlipSpacing.md)
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        Map(position: $cameraPosition, selection: $selectedFriend) {
            // User location
            if let userLocation {
                Annotation(FriendFinderMapL10n.you, coordinate: userLocation) {
                    ZStack {
                        Circle()
                            .fill(.blipAccentPurple.opacity(0.2))
                            .frame(width: 44, height: 44)

                        Circle()
                            .fill(.blipAccentPurple)
                            .frame(width: 14, height: 14)

                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                    .accessibilityLabel(FriendFinderMapL10n.yourLocation)
                }
            }

            // Friend pins
            ForEach(friends) { friend in
                Annotation(friend.displayName, coordinate: friend.coordinate) {
                    FriendPinView(
                        friend: friend,
                        isSelected: selectedFriend?.id == friend.id,
                        onTap: {
                            selectedFriend = friend
                            onFriendTap?(friend)
                        }
                    )
                }
                .tag(friend)
            }

            // Beacon pins
            ForEach(beacons) { beacon in
                Annotation(beacon.label, coordinate: beacon.coordinate) {
                    BeaconPinView(beacon: beacon)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
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
            if let selected = selectedFriend {
                friendDetailCard(for: selected)
                    .padding(BlipSpacing.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: selectedFriend?.id)
    }

    // MARK: - Friend Detail Card

    @ViewBuilder
    private func friendDetailCard(for friend: FriendMapPin) -> some View {
        GlassCard(thickness: .thick, cornerRadius: BlipCornerRadius.xl) {
            HStack(spacing: BlipSpacing.md) {
                AvatarView(
                    imageData: friend.avatarData,
                    name: friend.displayName,
                    size: BlipSizing.avatarSmall,
                    ringStyle: .friend,
                    showOnlineIndicator: !friend.isOutOfRange
                )

                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text(friend.displayName)
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    HStack(spacing: BlipSpacing.xs) {
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

                Spacer()

                // Navigate button
                Button(action: { onNavigateToFriend?(friend) }) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                        .background(
                            Circle()
                                .fill(LinearGradient.blipAccent)
                        )
                }
                .accessibilityLabel(FriendFinderMapL10n.navigateToFriend(friend.displayName))

                // Dismiss
                Button(action: { selectedFriend = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.colors.mutedText)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                }
                .accessibilityLabel(FriendFinderMapL10n.close)
            }
        }
    }

    // MARK: - Controls

    private var recenterButton: some View {
        Button(action: {
            withAnimation {
                cameraPosition = .automatic
            }
        }) {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blipAccentPurple)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(.thickMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.1),
                                    lineWidth: BlipSizing.hairline
                                )
                        )
                )
        }
        .accessibilityLabel(FriendFinderMapL10n.recenterMap)
    }

    private var dropBeaconButton: some View {
        Button(action: { showBeaconConfirm = true }) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                .background(
                    Circle()
                        .fill(LinearGradient.blipAccent)
                )
        }
        .accessibilityLabel(FriendFinderMapL10n.dropBeaconAccessibility)
        .alert(FriendFinderMapL10n.dropBeaconTitle, isPresented: $showBeaconConfirm) {
            Button(FriendFinderMapL10n.dropHere) {
                if let userLocation {
                    onDropBeacon?(userLocation)
                }
            }
            Button(FriendFinderMapL10n.cancel, role: .cancel) {}
        } message: {
            Text(FriendFinderMapL10n.dropBeaconMessage)
        }
    }
}

// MARK: - FriendPinView

/// A single friend pin on the map with avatar and precision radius ring.
private struct FriendPinView: View {

    let friend: FriendMapPin
    let isSelected: Bool
    let onTap: () -> Void

    @State private var ringPulsing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Accuracy radius ring (animated)
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

                // Fuzzy area ring for approximate locations
                if friend.precision == .fuzzy {
                    Circle()
                        .fill(friend.color.opacity(0.1))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(friend.color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }

                // Avatar pin
                if friend.precision != .off {
                    VStack(spacing: 2) {
                        AvatarView(
                            imageData: friend.avatarData,
                            name: friend.displayName,
                            size: isSelected ? 36 : 28,
                            ringStyle: .friend,
                            showOnlineIndicator: !friend.isOutOfRange
                        )
                        .shadow(color: friend.color.opacity(0.4), radius: 4)

                        // Name label when selected
                        if isSelected {
                            Text(friend.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, BlipSpacing.sm)
                                .padding(.vertical, BlipSpacing.xxs)
                                .background(Capsule().fill(friend.color))
                        }
                    }
                } else {
                    Circle()
                        .fill(friend.color.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(friend.displayName), \(friend.precisionDescription)")
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled, friend.accuracyMeters > 0 else { return }
            // Ambient loop — easeInOut intentional
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                ringPulsing = true
            }
        }
    }

    /// Maps accuracy meters to a visual ring size (clamped).
    private var ringSize: CGFloat {
        let clamped = min(max(friend.accuracyMeters, 10), 100)
        return CGFloat(clamped * 0.6 + 20)
    }
}

// MARK: - BeaconPinView

/// A beacon pin dropped by a friend or the user.
private struct BeaconPinView: View {

    let beacon: BeaconPin

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulse ring
            if !SpringConstants.isReduceMotionEnabled {
                Circle()
                    .stroke(.blipAccentPurple.opacity(0.3), lineWidth: 1)
                    .frame(width: 36, height: 36)
                    .scaleEffect(isPulsing ? 1.5 : 1.0)
                    .opacity(isPulsing ? 0 : 0.5)
            }

            // Pin
            VStack(spacing: 0) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blipAccentPurple)

                Text(beacon.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, BlipSpacing.xs)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(
                        Capsule()
                            .fill(.blipAccentPurple)
                    )
            }
        }
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled else { return }
            // Ambient loop — easeInOut intentional
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityLabel(FriendFinderMapL10n.beacon(beacon.label))
    }
}

// MARK: - Data Models

/// View-level data for a friend's location on the map.
struct FriendMapPin: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let precision: LocationPinPrecision
    let color: Color
    let lastUpdated: Date
    var avatarData: Data? = nil
    var accuracyMeters: Double = 0
    var distanceFromUser: Double? = nil
    var rssiMeters: Double? = nil
    var isOutOfRange: Bool = false

    var precisionDescription: String {
        switch precision {
        case .precise: return FriendFinderMapL10n.preciseLocation
        case .fuzzy: return FriendFinderMapL10n.approximateArea
        case .off: return FriendFinderMapL10n.locationHidden
        }
    }

    var lastSeenText: String {
        let interval = Date().timeIntervalSince(lastUpdated)
        if interval < 60 { return FriendFinderMapL10n.justNow }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return FriendFinderMapL10n.overDayAgo
    }

    var distanceText: String? {
        guard let d = distanceFromUser else { return nil }
        if d < 1000 { return "\(Int(d))m away" }
        return String(format: "%.1f km away", d / 1000)
    }

    /// Color for accuracy radius ring.
    var accuracyColor: Color {
        if accuracyMeters < 10 { return .green }
        if accuracyMeters < 50 { return .yellow }
        return .red
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FriendMapPin, rhs: FriendMapPin) -> Bool {
        lhs.id == rhs.id
    }
}

enum LocationPinPrecision: String {
    case precise
    case fuzzy
    case off
}

/// View-level data for a beacon pin.
struct BeaconPin: Identifiable {
    let id: UUID
    let label: String
    let coordinate: CLLocationCoordinate2D
    let createdBy: String
    let expiresAt: Date
}

// MARK: - Preview

#Preview("Friend Finder Map") {
    let friends: [FriendMapPin] = [
        FriendMapPin(
            id: UUID(),
            displayName: FriendFinderMapL10n.previewSarah,
            coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862),
            precision: .precise,
            color: .blue,
            lastUpdated: Date(),
            accuracyMeters: 5,
            distanceFromUser: 45
        ),
        FriendMapPin(
            id: UUID(),
            displayName: FriendFinderMapL10n.previewJake,
            coordinate: CLLocationCoordinate2D(latitude: 51.0052, longitude: -2.5850),
            precision: .fuzzy,
            color: .green,
            lastUpdated: Date().addingTimeInterval(-180),
            accuracyMeters: 35,
            distanceFromUser: 120
        ),
    ]

    let beacons: [BeaconPin] = [
        BeaconPin(
            id: UUID(),
            label: FriendFinderMapL10n.previewMeetHere,
            coordinate: CLLocationCoordinate2D(latitude: 51.0045, longitude: -2.5858),
            createdBy: "You",
            expiresAt: Date().addingTimeInterval(1800)
        ),
    ]

    FriendFinderMap(
        friends: friends,
        userLocation: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
        beacons: beacons
    )
    .frame(height: 400)
    .padding()
    .background(GradientBackground())
    .preferredColorScheme(.dark)
}
