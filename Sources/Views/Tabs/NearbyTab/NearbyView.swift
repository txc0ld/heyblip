import SwiftUI
import SwiftData
import MapKit

// MARK: - NearbyView

/// Main view for the Nearby tab.
///
/// Combines: "X people nearby" header, mesh particle background,
/// friends section, location channels section, and friend finder map.
/// Uses staggered reveal for section entrance and glassmorphism throughout.
struct NearbyView: View {

    @State private var meshViewModel: MeshViewModel?
    @State private var beacons: [BeaconPin] = []
    @State private var showMap = false

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                // Ambient mesh particles behind content
                MeshParticleView(peerCount: peerCount)
                    .opacity(0.6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                        headerSection
                            .staggeredReveal(index: 0)

                        friendsSection
                            .staggeredReveal(index: 1)

                        channelsSection
                            .staggeredReveal(index: 2)

                        mapSection
                            .staggeredReveal(index: 3)

                        // Bottom spacer for tab bar
                        Spacer().frame(height: BlipSpacing.xxl)
                    }
                    .padding(.top, BlipSpacing.md)
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task {
            if meshViewModel == nil {
                meshViewModel = MeshViewModel(modelContainer: modelContext.container)
            }
            meshViewModel?.startMonitoring()
            await meshViewModel?.refreshMeshState()
        }
        .onDisappear {
            meshViewModel?.stopMonitoring()
        }
    }

    // MARK: - ViewModel Bindings

    private var peerCount: Int {
        meshViewModel?.connectedPeerCount ?? 0
    }

    private var nearbyFriends: [NearbyPeerCard_Data] {
        guard let vm = meshViewModel else { return [] }
        return vm.nearbyFriends.map { friend in
            NearbyPeerCard_Data(
                id: friend.id,
                displayName: friend.displayName,
                username: friend.username,
                hopCount: friend.isDirectPeer ? 0 : 1,
                rssi: friend.rssi,
                isOnline: true
            )
        }
    }

    private var channels: [LocationChannelItem] {
        guard let vm = meshViewModel else { return [] }
        return vm.locationChannels.map { channel in
            LocationChannelItem(
                id: channel.id,
                name: channel.name,
                iconName: "mappin.and.ellipse",
                memberCount: channel.peerCount,
                lastMessagePreview: nil,
                lastActivityAt: nil,
                isAutoJoined: channel.isJoined,
                geohash: channel.geohash
            )
        }
    }

    private var friendPins: [FriendMapPin] {
        guard let vm = meshViewModel else { return [] }
        return vm.nearbyFriends.map { friend in
            FriendMapPin(
                id: friend.id,
                displayName: friend.displayName,
                coordinate: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
                precision: friend.isDirectPeer ? .precise : .fuzzy,
                color: .blue,
                lastUpdated: friend.lastSeen
            )
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.xl) {
            HStack(spacing: BlipSpacing.md) {
                // Animated peer count
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    Text("\(peerCount)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.blipAccentPurple)
                        .contentTransition(.numericText())

                    Text("people nearby")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)
                }

                Spacer()

                // Signal indicator
                VStack(spacing: BlipSpacing.xs) {
                    Image(systemName: meshViewModel?.isBLEActive == true ? "wave.3.right" : "wave.3.right.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.blipAccentPurple)
                        .symbolEffect(.pulse, options: .repeating)

                    Text(meshViewModel?.transportState ?? "Scanning...")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peerCount) people nearby, mesh active")
    }

    // MARK: - Friends Section

    @ViewBuilder
    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)

                Text("Friends Nearby")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                if !nearbyFriends.isEmpty {
                    Text("\(nearbyFriends.count)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(theme.colors.hover))
                }
            }
            .padding(.horizontal, BlipSpacing.md)

            if nearbyFriends.isEmpty {
                HStack(spacing: BlipSpacing.sm) {
                    ProgressView()
                        .tint(theme.colors.mutedText)
                    Text("Scanning for nearby peers...")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, BlipSpacing.lg)
            } else {
                ForEach(Array(nearbyFriends.enumerated()), id: \.element.id) { index, friend in
                    NearbyPeerCard(
                        displayName: friend.displayName,
                        username: friend.username,
                        avatarData: nil,
                        hopCount: friend.hopCount,
                        rssi: friend.rssi,
                        isOnline: friend.isOnline,
                        isFriend: true
                    )
                    .padding(.horizontal, BlipSpacing.md)
                    .staggeredReveal(index: index)
                }
            }
        }
    }

    // MARK: - Channels Section

    private var channelsSection: some View {
        LocationChannelList(channels: channels)
    }

    // MARK: - Map Section

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            HStack {
                Image(systemName: "map.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)

                Text("Friend Finder")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Button(action: { withAnimation { showMap.toggle() } }) {
                    Text(showMap ? "Hide Map" : "Show Map")
                        .font(theme.typography.caption)
                        .foregroundStyle(.blipAccentPurple)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(
                            Capsule()
                                .fill(.blipAccentPurple.opacity(0.12))
                        )
                }
                .frame(minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(showMap ? "Hide friend finder map" : "Show friend finder map")
            }
            .padding(.horizontal, BlipSpacing.md)

            if showMap {
                FriendFinderMap(
                    friends: friendPins,
                    userLocation: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856),
                    beacons: beacons,
                    onDropBeacon: { coordinate in
                        let beacon = BeaconPin(
                            id: UUID(),
                            label: "I'm here!",
                            coordinate: coordinate,
                            createdBy: "You",
                            expiresAt: Date().addingTimeInterval(1800)
                        )
                        beacons.append(beacon)
                    }
                )
                .frame(height: 350)
                .padding(.horizontal, BlipSpacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}

// MARK: - Peer Card Data

/// Lightweight view-level struct for peer card display.
struct NearbyPeerCard_Data: Identifiable {
    let id: UUID
    let displayName: String
    let username: String?
    let hopCount: Int
    let rssi: Int
    let isOnline: Bool
}

// MARK: - Sample Data

extension NearbyView {

    static let sampleFriends: [NearbyPeerCard_Data] = [
        NearbyPeerCard_Data(id: UUID(), displayName: "Sarah Chen", username: "sarahc", hopCount: 0, rssi: -45, isOnline: true),
        NearbyPeerCard_Data(id: UUID(), displayName: "Jake Morrison", username: "jakem", hopCount: 1, rssi: -62, isOnline: true),
        NearbyPeerCard_Data(id: UUID(), displayName: "Priya Patel", username: "priyap", hopCount: 3, rssi: -78, isOnline: true),
    ]

    static let samplePeers: [NearbyPeerCard_Data] = [
        NearbyPeerCard_Data(id: UUID(), displayName: "Alex", username: nil, hopCount: 2, rssi: -70, isOnline: true),
        NearbyPeerCard_Data(id: UUID(), displayName: "MeshUser_7f3a", username: nil, hopCount: 4, rssi: -85, isOnline: false),
    ]

    static let sampleChannels: [LocationChannelItem] = [
        LocationChannelItem(id: UUID(), name: "Main Field", iconName: "mappin.and.ellipse", memberCount: 42, lastMessagePreview: "Anyone know where the food trucks moved?", lastActivityAt: Date().addingTimeInterval(-120), isAutoJoined: true, geohash: "gcpu2e"),
        LocationChannelItem(id: UUID(), name: "Camping Area B", iconName: "tent.fill", memberCount: 18, lastMessagePreview: "Showers open until midnight", lastActivityAt: Date().addingTimeInterval(-300), isAutoJoined: false, geohash: "gcpu2f"),
        LocationChannelItem(id: UUID(), name: "Car Park 3", iconName: "car.fill", memberCount: 7, lastMessagePreview: nil, lastActivityAt: nil, isAutoJoined: false, geohash: "gcpu2g"),
    ]

    static let sampleFriendPins: [FriendMapPin] = [
        FriendMapPin(id: UUID(), displayName: "Sarah", coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), precision: .precise, color: .blue, lastUpdated: Date()),
        FriendMapPin(id: UUID(), displayName: "Jake", coordinate: CLLocationCoordinate2D(latitude: 51.0052, longitude: -2.5850), precision: .fuzzy, color: .green, lastUpdated: Date().addingTimeInterval(-60)),
    ]
}

// MARK: - Preview

#Preview("Nearby Tab") {
    NearbyView()
        .preferredColorScheme(.dark)
        .festiChatTheme()
}

#Preview("Nearby Tab - Light") {
    NearbyView()
        .preferredColorScheme(.light)
        .festiChatTheme()
}
