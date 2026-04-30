import SwiftUI

private enum NearbyPeerCardL10n {
    static let add = String(localized: "common.add", defaultValue: "Add")
    static let pending = String(localized: "common.pending", defaultValue: "Pending")
    static let pendingAccessibility = String(localized: "nearby.peer.friend_pending_accessibility_label", defaultValue: "Friend request pending")
    static let alreadyFriends = String(localized: "nearby.peer.already_friends_accessibility_label", defaultValue: "Already friends")
    static let nearby = String(localized: "nearby.peer.distance.nearby", defaultValue: "Nearby")
    static let direct = String(localized: "nearby.peer.hops.direct", defaultValue: "Direct")
    static let excellent = String(localized: "nearby.peer.signal.excellent", defaultValue: "Excellent")
    static let good = String(localized: "nearby.peer.signal.good", defaultValue: "Good")
    static let fair = String(localized: "nearby.peer.signal.fair", defaultValue: "Fair")
    static let weak = String(localized: "nearby.peer.signal.weak", defaultValue: "Weak")
    static let noSignal = String(localized: "nearby.peer.signal.none", defaultValue: "No signal")
    static let friend = String(localized: "common.friend", defaultValue: "friend")
    static let requestPending = String(localized: "nearby.peer.request_pending", defaultValue: "friend request pending")
    static let online = String(localized: "common.online", defaultValue: "online")
    static let previewSarah = "Sarah"
    static let previewAlex = "Alex"
    static let previewPending = "Pending"
    static let previewFarAway = "Far Away"

    static func signalStrength(_ description: String) -> String {
        String(format: String(localized: "nearby.peer.signal_strength", defaultValue: "Signal strength: %@"), locale: Locale.current, description)
    }

    static let oneHop = String(localized: "nearby.peer.hops.one", defaultValue: "1 hop")

    static func hops(_ count: Int) -> String {
        String(format: String(localized: "nearby.peer.hops.count", defaultValue: "%d hops"), locale: Locale.current, count)
    }

    static func addAccessibility(_ name: String) -> String {
        String(format: String(localized: "nearby.peer.add_accessibility_label", defaultValue: "Add %@ as friend"), locale: Locale.current, name)
    }
}

@MainActor
private final class NearbyPeerRSSILogThrottler {
    static let shared = NearbyPeerRSSILogThrottler()

    private let lock = NSLock()
    private var lastLogAtByPeer: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 10

    func logIfNeeded(displayName: String, username: String?, rssi: Int, label: String) {
        let key = username ?? displayName
        let now = Date()
        let shouldLog: Bool = lock.withLock {
            if let lastLogAt = lastLogAtByPeer[key],
               now.timeIntervalSince(lastLogAt) < throttleInterval {
                return false
            }

            lastLogAtByPeer[key] = now
            return true
        }

        guard shouldLog else { return }
        DebugLogger.shared.log("BLE", "Peer \(displayName) RSSI: \(rssi) → \(label)")
    }
}

// MARK: - NearbyPeerCard

/// Glass card displaying a nearby mesh peer or friend.
///
/// Shows avatar (initials fallback), display name, hop distance, distance
/// estimate, RSSI bars, and a friend action button reflecting current state.
struct NearbyPeerCard: View {

    enum FriendState: Sendable {
        case notFriend
        case pending
        case friends
    }

    let displayName: String
    let username: String?
    let avatarData: Data?
    let hopCount: Int
    let rssi: Int
    let isOnline: Bool
    let hasSignalData: Bool
    let friendState: FriendState

    var onTap: (() -> Void)?
    var onAddFriend: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: BlipSpacing.md) {
                avatarView
                peerInfo
                Spacer(minLength: 0)
                rssiIndicator
                friendActionView
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(
            thickness: .regular,
            cornerRadius: BlipCornerRadius.lg,
            borderOpacity: 0.20
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .onChange(of: rssi) { _, newRSSI in
            NearbyPeerRSSILogThrottler.shared.logIfNeeded(
                displayName: displayName,
                username: username,
                rssi: newRSSI,
                label: estimatedDistance
            )
        }
    }

    // MARK: - Avatar

    private var avatarView: some View {
        ZStack {
            if let avatarData, let uiImage = uiImageFromData(avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient.blipAccent)
                    .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                    .overlay(
                        Text(initials)
                            .font(theme.typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    )
            }

            // Online indicator — electricCyan
            if isOnline {
                Circle()
                    .fill(Color.blipElectricCyan)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(colorScheme == .dark ? Color.black : Color.white, lineWidth: 1.5)
                    )
                    .offset(x: 14, y: 14)
            }

            // Friend badge — accent gradient
            if friendState == .friends {
                Circle()
                    .fill(LinearGradient.blipAccent)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(theme.typography.micro)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    )
                    .offset(x: -14, y: 14)
            }
        }
    }

    // MARK: - Peer Info

    private var peerInfo: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(displayName)
                .font(theme.typography.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.colors.text)
                // 2 lines so longer display names stay legible at AX5;
                // peer cards aren't list-dense like ChatListCell so the
                // extra row is fine.
                .lineLimit(2)

            HStack(spacing: BlipSpacing.xs) {
                if let username {
                    Text("@\(username)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Text(hopDescription)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(
                        Capsule()
                            .fill(theme.colors.hover)
                    )

                Text(estimatedDistance)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(
                        Capsule()
                            .fill(theme.colors.hover)
                    )
            }
        }
    }

    // MARK: - RSSI Indicator

    private var rssiIndicator: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: barIndex))
                    .frame(width: 3, height: barHeight(for: barIndex))
            }
        }
        .frame(width: 20, height: 16)
        .accessibilityLabel(NearbyPeerCardL10n.signalStrength(signalDescription))
    }

    private func barColor(for index: Int) -> Color {
        let level = signalLevel
        if index < level {
            switch level {
            case 4: return Color.blipMint       // Excellent
            case 3: return Color.blipMint       // Good
            case 2: return theme.colors.statusAmber  // Fair
            default: return Color.blipWarmCoral  // Weak
            }
        }
        return theme.colors.border
    }

    private func barHeight(for index: Int) -> CGFloat {
        CGFloat(4 + index * 3)
    }

    /// Maps RSSI to 0-4 signal bars.
    private var signalLevel: Int {
        guard hasSignalData else { return 0 }
        switch rssi {
        case -50...0: return 4    // Excellent
        case -65...(-51): return 3 // Good
        case -80...(-66): return 2 // Fair
        case -95...(-81): return 1 // Weak
        default: return 0          // No signal
        }
    }

    // MARK: - Friend Action

    @ViewBuilder
    private var friendActionView: some View {
        switch friendState {
        case .notFriend:
            if let onAddFriend {
                Button(action: onAddFriend) {
                    Text(NearbyPeerCardL10n.add)
                        .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, BlipSpacing.sm + 2)
                        .padding(.vertical, BlipSpacing.xs + 1)
                        .background(Capsule().fill(LinearGradient.blipAccent))
                }
                .buttonStyle(.plain)
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(NearbyPeerCardL10n.addAccessibility(displayName))
            }
        case .pending:
            Text(NearbyPeerCardL10n.pending)
                .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                .foregroundStyle(theme.colors.statusAmber)
                .padding(.horizontal, BlipSpacing.sm + 2)
                .padding(.vertical, BlipSpacing.xs + 1)
                .background(Capsule().fill(theme.colors.statusAmber.opacity(0.12)))
                .accessibilityLabel(NearbyPeerCardL10n.pendingAccessibility)
        case .friends:
            Image(systemName: "checkmark.circle.fill")
                .font(theme.typography.body)
                .foregroundStyle(Color.blipMint)
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(NearbyPeerCardL10n.alreadyFriends)
        }
    }

    // MARK: - Helpers

    /// Estimated distance from RSSI using log-distance path loss model.
    /// Very approximate — BLE RSSI is noisy, especially in crowds.
    private var estimatedDistance: String {
        guard hasSignalData else { return NearbyPeerCardL10n.nearby }
        return RSSIDistance.displayString(fromRSSI: rssi)
    }

    private var initials: String {
        let components = displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    private var hopDescription: String {
        switch hopCount {
        case 0: return NearbyPeerCardL10n.direct
        case 1: return NearbyPeerCardL10n.oneHop
        default: return NearbyPeerCardL10n.hops(hopCount)
        }
    }

    private var signalDescription: String {
        switch signalLevel {
        case 4: return NearbyPeerCardL10n.excellent
        case 3: return NearbyPeerCardL10n.good
        case 2: return NearbyPeerCardL10n.fair
        case 1: return NearbyPeerCardL10n.weak
        default: return NearbyPeerCardL10n.noSignal
        }
    }

    private var accessibilityDescription: String {
        var desc = "\(displayName)"
        if friendState == .friends { desc += ", \(NearbyPeerCardL10n.friend)" }
        if friendState == .pending { desc += ", \(NearbyPeerCardL10n.requestPending)" }
        desc += ", \(hopDescription) away"
        desc += ", approximately \(estimatedDistance)"
        desc += ", signal \(signalDescription)"
        if isOnline { desc += ", \(NearbyPeerCardL10n.online)" }
        return desc
    }

    private func uiImageFromData(_ data: Data) -> UIImage? {
        #if canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}

// MARK: - Preview

#Preview("Peer Cards — All States") {
    ZStack {
        GradientBackground()
        ScrollView {
            VStack(spacing: BlipSpacing.sm) {
                NearbyPeerCard(displayName: NearbyPeerCardL10n.previewSarah, username: "sarahc", avatarData: nil,
                    hopCount: 0, rssi: -45, isOnline: true, hasSignalData: true, friendState: .friends)
                NearbyPeerCard(displayName: NearbyPeerCardL10n.previewAlex, username: "alexr", avatarData: nil,
                    hopCount: 1, rssi: -58, isOnline: true, hasSignalData: true, friendState: .notFriend, onAddFriend: {})
                NearbyPeerCard(displayName: NearbyPeerCardL10n.previewPending, username: "pendp", avatarData: nil,
                    hopCount: 2, rssi: -75, isOnline: true, hasSignalData: true, friendState: .pending)
                NearbyPeerCard(displayName: NearbyPeerCardL10n.previewFarAway, username: nil, avatarData: nil,
                    hopCount: 5, rssi: -90, isOnline: false, hasSignalData: true, friendState: .notFriend)
            }
            .padding()
        }
    }
    .blipTheme()
}
