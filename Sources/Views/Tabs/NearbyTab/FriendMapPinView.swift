import SwiftUI
import CoreLocation

private enum FriendMapPinViewL10n {
    static let pinAccessibility = String(
        localized: "nearby.friend_finder.pin.accessibility",
        defaultValue: "%1$@, %2$@"
    )
    static let outOfRange = String(
        localized: "nearby.friend_finder.friend.out_of_range",
        defaultValue: "Out of range"
    )
}

// MARK: - FriendMapPinView

/// Custom map annotation for a friend on the Friend Finder map.
///
/// Visual breakdown:
/// - **In-range**: avatar inside a glass backing, with a `PulseGlow` halo whose
///   intensity scales with `FriendMapPin.rssiMeters` (closer/stronger signal →
///   brighter, larger pulse).
/// - **Out-of-range** (`FriendMapPin.isOutOfRange`): dimmed avatar (saturation
///   + opacity reduced), no halo, plus a dashed friend-tinted ring. Communicates
///   "we know they exist but we don't have a fresh fix."
/// - **Selected**: inline chip beneath the avatar with distance + a bearing
///   arrow rotated to point from the current user toward the friend, only when
///   the location is fresh (< 5 min). For stale fixes the chip falls back to
///   the `lastSeenText` (e.g. "10 min ago") so the user knows not to chase.
///
/// `PulseGlow` and the dashed-ring scale animation honour
/// `accessibilityReduceMotion` via the primitive itself / SpringConstants —
/// no extra reduce-motion handling needed here.
struct FriendMapPinView: View {

    let friend: FriendMapPin
    let isSelected: Bool
    /// Current user's coordinate, if available — used to render the bearing
    /// arrow inside the selected-state chip.
    let userLocation: CLLocationCoordinate2D?
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    private static let freshLocationWindow: TimeInterval = 5 * 60

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: BlipSpacing.xs) {
                pinStack
                if isSelected {
                    selectedChip
                }
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pin stack

    private var pinStack: some View {
        ZStack {
            if friend.isOutOfRange {
                outOfRangeRing
            } else {
                signalHalo
            }

            AvatarView(
                imageData: friend.avatarData,
                name: friend.displayName,
                size: avatarSize,
                ringStyle: friend.isOutOfRange ? .none : .friend,
                showOnlineIndicator: !friend.isOutOfRange
            )
            .opacity(friend.isOutOfRange ? 0.45 : 1.0)
            .saturation(friend.isOutOfRange ? 0.30 : 1.0)
            .shadow(color: friend.color.opacity(friend.isOutOfRange ? 0.0 : 0.35), radius: 4)
        }
    }

    /// Out-of-range visual: dashed friend-tinted ring around the dimmed avatar.
    /// No motion — staleness is communicated by the dim + dashed treatment, not
    /// movement. (A pulsing stale pin would falsely signal liveness.)
    private var outOfRangeRing: some View {
        Circle()
            .strokeBorder(
                friend.color.opacity(0.55),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: avatarSize + 12, height: avatarSize + 12)
    }

    /// Signal-strength halo. PulseGlow's opacity + size scales with rssiMeters
    /// so a peer 5m away breathes brightly while a peer 30m away barely glows.
    /// `nil` rssiMeters falls back to a mid-strength halo (we know they're
    /// in-range from `isOutOfRange == false`, just no precise distance).
    private var signalHalo: some View {
        PulseGlow(
            color: friend.color,
            size: haloSize,
            cycleDuration: haloCycle
        )
        .opacity(haloOpacity)
    }

    // MARK: - Selected chip

    @ViewBuilder
    private var selectedChip: some View {
        if isFreshLocation, let distance = friend.distanceText {
            HStack(spacing: BlipSpacing.xs) {
                if let degrees = bearingDegrees {
                    Image(systemName: "arrow.up")
                        .font(theme.typography.caption2)
                        .rotationEffect(.degrees(degrees))
                        .accessibilityHidden(true)
                }
                Text(distance)
                    .font(theme.typography.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, BlipSpacing.sm)
            .padding(.vertical, BlipSpacing.xxs)
            .background(Capsule().fill(friend.color))
        } else {
            // Stale fix — surface "X min ago" rather than a misleading direction.
            Text(friend.lastSeenText)
                .font(theme.typography.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, BlipSpacing.xxs)
                .background(Capsule().fill(friend.color.opacity(0.6)))
        }
    }

    // MARK: - Sizing + intensity

    private var avatarSize: CGFloat {
        isSelected ? 36 : 28
    }

    /// PulseGlow size envelope. Closer signal → bigger halo (48–72pt).
    private var haloSize: CGFloat {
        guard let rssi = friend.rssiMeters else { return 56 }
        let clamped = min(max(rssi, 5), 30)
        let intensity = (30 - clamped) / 25
        return 48 + intensity * 24
    }

    /// PulseGlow opacity envelope. Closer signal → brighter (0.25–0.85).
    private var haloOpacity: Double {
        guard let rssi = friend.rssiMeters else { return 0.5 }
        let clamped = min(max(rssi, 5), 30)
        let intensity = (30 - clamped) / 25
        return 0.25 + intensity * 0.60
    }

    /// PulseGlow cycle. Closer signal → faster pulse (felt as more "alive").
    private var haloCycle: Double {
        guard let rssi = friend.rssiMeters else { return 2.0 }
        let clamped = min(max(rssi, 5), 30)
        // 5m → 1.4s, 30m → 2.6s
        return 1.4 + ((clamped - 5) / 25) * 1.2
    }

    // MARK: - Bearing + freshness

    private var isFreshLocation: Bool {
        Date().timeIntervalSince(friend.lastUpdated) < Self.freshLocationWindow
    }

    /// Bearing in degrees (0 = north, 90 = east) from the current user toward
    /// `friend.coordinate`. Returns nil when the user's location is unknown so
    /// the chip can fall back to distance-only.
    private var bearingDegrees: Double? {
        guard let userLocation else { return nil }
        return Self.bearing(from: userLocation, to: friend.coordinate)
    }

    /// Standard initial-bearing formula (great-circle, plane-approx).
    /// `start` and `end` in degrees lat/lon; result in degrees 0..<360 with
    /// 0 = true north. `Image(systemName: "arrow.up").rotationEffect(.degrees(b))`
    /// then points correctly toward `end`.
    static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let detail = friend.isOutOfRange
            ? FriendMapPinViewL10n.outOfRange
            : friend.lastSeenText
        return String(
            format: FriendMapPinViewL10n.pinAccessibility,
            locale: Locale.current,
            friend.displayName,
            detail
        )
    }
}

// MARK: - Preview

#Preview("FriendMapPinView — in-range, strong") {
    let friend = FriendMapPin(
        id: UUID(),
        displayName: "Sarah",
        coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862),
        precision: .precise,
        color: .blue,
        lastUpdated: Date(),
        accuracyMeters: 8,
        distanceFromUser: 45,
        rssiMeters: 6
    )
    return ZStack {
        Color.gray.ignoresSafeArea()
        FriendMapPinView(
            friend: friend,
            isSelected: false,
            userLocation: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
            onTap: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("FriendMapPinView — selected (fresh)") {
    let friend = FriendMapPin(
        id: UUID(),
        displayName: "Sarah",
        coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862),
        precision: .precise,
        color: .blue,
        lastUpdated: Date(),
        accuracyMeters: 8,
        distanceFromUser: 45,
        rssiMeters: 8
    )
    return ZStack {
        Color.gray.ignoresSafeArea()
        FriendMapPinView(
            friend: friend,
            isSelected: true,
            userLocation: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
            onTap: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("FriendMapPinView — out-of-range") {
    let friend = FriendMapPin(
        id: UUID(),
        displayName: "Alex",
        coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845),
        precision: .precise,
        color: .purple,
        lastUpdated: Date().addingTimeInterval(-3_600),
        accuracyMeters: 80,
        distanceFromUser: 500,
        isOutOfRange: true
    )
    return ZStack {
        Color.gray.ignoresSafeArea()
        FriendMapPinView(
            friend: friend,
            isSelected: false,
            userLocation: nil,
            onTap: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("FriendMapPinView — selected, stale") {
    let friend = FriendMapPin(
        id: UUID(),
        displayName: "Priya",
        coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
        precision: .fuzzy,
        color: .orange,
        lastUpdated: Date().addingTimeInterval(-15 * 60),
        accuracyMeters: 40,
        distanceFromUser: 280,
        rssiMeters: 28
    )
    return ZStack {
        Color.gray.ignoresSafeArea()
        FriendMapPinView(
            friend: friend,
            isSelected: true,
            userLocation: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
            onTap: {}
        )
    }
    .preferredColorScheme(.dark)
}
