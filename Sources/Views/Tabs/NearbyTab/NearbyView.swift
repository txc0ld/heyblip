import SwiftUI
import SwiftData
import MapKit

// MARK: - NearbyView

/// Main view for the Nearby tab.
///
/// Combines: "X people nearby" header, mesh particle background,
/// peers section (with add-friend), friends section, channels, and friend finder map.
struct NearbyView: View {

    var meshViewModel: MeshViewModel? = nil
    var locationViewModel: LocationViewModel? = nil

    @State private var localMeshViewModel: MeshViewModel?
    @State private var localLocationViewModel: LocationViewModel?
    @State private var showMap = false
    @State private var selectedPeer: MeshViewModel.NearbyPeer?
    @State private var friendRequestSent: Set<UUID> = []
    @State private var isVisible = false
    @State private var presenceTimer: Timer?

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

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

                        peersSection
                            .staggeredReveal(index: 1)

                        friendsSection
                            .staggeredReveal(index: 2)

                        channelsSection
                            .staggeredReveal(index: 3)

                        mapSection
                            .staggeredReveal(index: 4)

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
        .bleDebugOverlay()
        .sheet(item: $selectedPeer) { peer in
            ProfileSheet(
                isPresented: Binding(
                    get: { selectedPeer != nil },
                    set: { if !$0 { selectedPeer = nil } }
                ),
                displayName: peer.displayName ?? peer.username ?? "Unknown",
                username: peer.username ?? "",
                bio: "",
                isFriend: peer.friendStatus == .accepted,
                isOnline: true,
                onAddFriend: {
                    sendFriendRequest(to: peer)
                    selectedPeer = nil
                }
            )
            .presentationDetents([.medium])
        }
        .task {
            if resolvedMeshViewModel == nil {
                localMeshViewModel = MeshViewModel(modelContainer: modelContext.container)
            }
            if resolvedLocationViewModel == nil {
                localLocationViewModel = LocationViewModel(
                    modelContainer: modelContext.container,
                    locationService: coordinator.locationService
                )
            }
            localMeshViewModel?.startMonitoring()
            localLocationViewModel?.startMonitoring()
            await resolvedMeshViewModel?.refreshMeshState()
            await resolvedLocationViewModel?.refreshFriendLocationsForDisplay()
            loadVisibilityPreference()
        }
        .onDisappear {
            localMeshViewModel?.stopMonitoring()
            localLocationViewModel?.stopMonitoring()
            stopPresenceBroadcast()
        }
    }

    // MARK: - ViewModel Bindings

    private var resolvedMeshViewModel: MeshViewModel? {
        meshViewModel ?? localMeshViewModel
    }

    private var resolvedLocationViewModel: LocationViewModel? {
        locationViewModel ?? localLocationViewModel
    }

    private var peerCount: Int {
        resolvedMeshViewModel?.connectedPeerCount ?? 0
    }

    /// Connected peers who opted into visibility (have a username) and are NOT already friends or blocked.
    private var nonFriendPeers: [MeshViewModel.NearbyPeer] {
        guard let vm = resolvedMeshViewModel else { return [] }
        return vm.nearbyPeers.filter { peer in
            guard let username = peer.username, !username.isEmpty else { return false }
            return peer.friendStatus != .accepted && peer.friendStatus != .blocked
        }
    }

    private var nearbyFriends: [NearbyPeerCard_Data] {
        guard let vm = resolvedMeshViewModel else { return [] }
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
        guard let vm = resolvedMeshViewModel else { return [] }
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
        guard let vm = resolvedLocationViewModel else { return [] }
        let userCoordinate = vm.userLocation

        return vm.friendAnnotations.map { friend in
            FriendMapPin(
                id: friend.friendID,
                displayName: friend.name,
                coordinate: friend.coordinate,
                precision: mapPrecision(friend.precision),
                color: .blue,
                lastUpdated: friend.lastUpdated,
                accuracyMeters: friend.precision == .precise ? 12 : 60,
                distanceFromUser: userCoordinate.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: CLLocation(latitude: friend.coordinate.latitude, longitude: friend.coordinate.longitude))
                },
                isOutOfRange: Date().timeIntervalSince(friend.lastUpdated) > 1_800
            )
        }
    }

    private var beaconPins: [BeaconPin] {
        guard let beacon = resolvedLocationViewModel?.activeBeacon else { return [] }
        return [
            BeaconPin(
                id: beacon.id,
                label: beacon.label,
                coordinate: beacon.coordinate,
                createdBy: "You",
                expiresAt: beacon.expiresAt
            )
        ]
    }

    private var userLocation: CLLocationCoordinate2D? {
        resolvedLocationViewModel?.userLocation ?? coordinator.locationService.currentLocation?.coordinate
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: BlipSpacing.sm) {
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
                        Image(systemName: resolvedMeshViewModel?.isBLEActive == true ? "wave.3.right" : "wave.3.right.circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.blipAccentPurple)
                            .symbolEffect(.pulse, options: .repeating)

                        Text(resolvedMeshViewModel?.transportState ?? "Scanning...")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerAccessibilityLabel)

            // Visibility toggle
            Button(action: { toggleVisibility() }) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 14, weight: .medium))

                    Text(isVisible ? "Visible to Nearby" : "Hidden from Nearby")
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)

                    Spacer()

                    Text(isVisible ? "ON" : "OFF")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isVisible ? .white : theme.colors.mutedText)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(
                            Capsule()
                                .fill(isVisible ? AnyShapeStyle(LinearGradient.blipAccent) : AnyShapeStyle(theme.colors.hover))
                        )
                }
                .foregroundStyle(isVisible ? .blipAccentPurple : theme.colors.mutedText)
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.sm)
            }
            .buttonStyle(.plain)
            .glassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.lg, borderOpacity: 0.1)
            .padding(.horizontal, BlipSpacing.md)
            .frame(minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(isVisible ? "Visible to nearby people, tap to hide" : "Hidden from nearby people, tap to show")
        }
    }

    // MARK: - Peers Section (Non-Friends)

    @ViewBuilder
    private var peersSection: some View {
        if !nonFriendPeers.isEmpty {
            VStack(alignment: .leading, spacing: BlipSpacing.md) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blipAccentPurple)

                    Text("People Nearby")
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Spacer()

                    Text("\(nonFriendPeers.count)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(theme.colors.hover))
                }
                .padding(.horizontal, BlipSpacing.md)

                ForEach(Array(nonFriendPeers.enumerated()), id: \.element.id) { index, peer in
                    NearbyPeerCard(
                        displayName: peer.displayName ?? peer.username ?? "Unknown",
                        username: peer.username,
                        avatarData: nil,
                        hopCount: peer.isDirectPeer ? 0 : 1,
                        rssi: peer.rssi,
                        isOnline: true,
                        isFriend: false,
                        onTap: { selectedPeer = peer },
                        onAddFriend: peer.friendStatus == .pending || friendRequestSent.contains(peer.id)
                            ? nil  // No button if already pending
                            : { sendFriendRequest(to: peer) }
                    )
                    .overlay(alignment: .trailing) {
                        if peer.friendStatus == .pending || friendRequestSent.contains(peer.id) {
                            Text("Pending")
                                .font(theme.typography.caption)
                                .foregroundStyle(BlipColors.darkColors.statusAmber)
                                .padding(.horizontal, BlipSpacing.sm)
                                .padding(.vertical, BlipSpacing.xs)
                                .background(Capsule().fill(BlipColors.darkColors.statusAmber.opacity(0.12)))
                                .padding(.trailing, BlipSpacing.md + BlipSpacing.sm)
                        }
                    }
                    .padding(.horizontal, BlipSpacing.md)
                    .staggeredReveal(index: index)
                    .accessibilityLabel(peerAccessibilityLabel(peer))
                }
            }
        }
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

            if nearbyFriends.isEmpty && nonFriendPeers.isEmpty {
                HStack(spacing: BlipSpacing.sm) {
                    if resolvedMeshViewModel?.isBLEActive == true {
                        ProgressView()
                            .tint(theme.colors.mutedText)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    Text(emptyNearbyStateText)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, BlipSpacing.lg)
            } else if nearbyFriends.isEmpty {
                Text("No friends nearby yet. Tap a peer above to add them.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.md)
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

    // MARK: - Actions

    private func sendFriendRequest(to peer: MeshViewModel.NearbyPeer) {
        guard let messageService = coordinator.messageService else { return }
        friendRequestSent.insert(peer.id)
        Task {
            do {
                try await messageService.sendFriendRequest(toPeerData: peer.peerID)
            } catch {
                friendRequestSent.remove(peer.id)
            }
        }
    }

    // MARK: - Visibility

    private func toggleVisibility() {
        withAnimation(SpringConstants.accessiblePageEntrance) {
            isVisible.toggle()
        }
        saveVisibilityPreference()

        if isVisible {
            startPresenceBroadcast()
        } else {
            stopPresenceBroadcast()
        }
    }

    private func loadVisibilityPreference() {
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<UserPreferences>()
        if let prefs = try? context.fetch(descriptor).first {
            isVisible = prefs.nearbyVisibilityEnabled
            if isVisible {
                startPresenceBroadcast()
            }
        }
    }

    private func saveVisibilityPreference() {
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<UserPreferences>()
        if let prefs = try? context.fetch(descriptor).first {
            prefs.nearbyVisibilityEnabled = isVisible
            try? context.save()
        }
    }

    private func startPresenceBroadcast() {
        stopPresenceBroadcast()
        // Broadcast immediately, then every 10 seconds
        broadcastPresenceOnce()
        guard let messageService = coordinator.messageService else { return }
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak messageService] _ in
            Task { @MainActor in
                guard let messageService else { return }
                try? await messageService.broadcastPresence()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    private func stopPresenceBroadcast() {
        presenceTimer?.invalidate()
        presenceTimer = nil
    }

    private func broadcastPresenceOnce() {
        guard let messageService = coordinator.messageService else { return }
        Task {
            try? await messageService.broadcastPresence()
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

                NavigationLink {
                    FriendFinderMapView(
                        friendFinderViewModel: coordinator.friendFinderViewModel,
                        locationService: coordinator.locationService
                    )
                } label: {
                    Text("Open Full Map")
                        .font(theme.typography.caption)
                        .foregroundStyle(.blipAccentPurple)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(
                            Capsule()
                                .fill(.blipAccentPurple.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel("Open the full friend finder map")

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
                VStack(spacing: BlipSpacing.md) {
                    if let locationError = resolvedLocationViewModel?.errorMessage {
                        statusCard(
                            icon: "location.slash.fill",
                            title: locationError,
                            subtitle: "Friend Finder needs a real location fix and shared friend locations before the map can help."
                        )
                    } else if userLocation == nil {
                        statusCard(
                            icon: "location.circle",
                            title: "Location access is needed for Friend Finder",
                            subtitle: "Enable location access to recenter on you, drop a beacon, and show shared friend locations."
                        )
                    } else if friendPins.isEmpty {
                        statusCard(
                            icon: "person.2.slash",
                            title: "No shared friend locations yet",
                            subtitle: "Nearby mesh peers can appear above without GPS sharing. The map fills in only when friends opt into location sharing."
                        )
                    }

                    FriendFinderMap(
                        friends: friendPins,
                        userLocation: userLocation,
                        beacons: beaconPins,
                        onDropBeacon: { _ in
                            Task {
                                await resolvedLocationViewModel?.dropBeacon(label: "I'm here!")
                            }
                        }
                    )
                    .frame(height: 350)
                }
                .padding(.horizontal, BlipSpacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    private func statusCard(icon: String, title: String, subtitle: String) -> some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.xl) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blipAccentPurple)

                    Text(title)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)
                }

                Text(subtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mapPrecision(_ precision: LocationPrecision) -> LocationPinPrecision {
        switch precision {
        case .precise:
            return .precise
        case .fuzzy:
            return .fuzzy
        case .off:
            return .off
        }
    }

    private var headerAccessibilityLabel: String {
        "\(peerCount) people nearby. Transport: \(resolvedMeshViewModel?.transportState ?? "Scanning")."
    }

    private var emptyNearbyStateText: String {
        if let locationError = resolvedLocationViewModel?.errorMessage {
            return locationError
        }

        if resolvedMeshViewModel?.isBLEActive != true {
            return "Bluetooth discovery is not active yet."
        }

        return "Scanning for nearby peers..."
    }

    private func peerAccessibilityLabel(_ peer: MeshViewModel.NearbyPeer) -> String {
        let name = peer.displayName ?? peer.username ?? "Unknown"
        if peer.friendStatus == .pending || friendRequestSent.contains(peer.id) {
            return "\(name), friend request pending"
        }

        return "\(name), open nearby profile"
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
        .blipTheme()
        .environment(AppCoordinator())
}

#Preview("Nearby Tab - Light") {
    NearbyView()
        .preferredColorScheme(.light)
        .blipTheme()
        .environment(AppCoordinator())
}
