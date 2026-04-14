import SwiftUI
import SwiftData
import MapKit
#if canImport(UIKit)
import UIKit
#endif

private enum NearbyL10n {
    static let title = String(localized: "nearby.title", defaultValue: "Nearby")
    static let unknown = String(localized: "common.unknown", defaultValue: "Unknown")
    static let you = String(localized: "common.you", defaultValue: "You")
    static let peopleNearby = String(localized: "nearby.people_count.label", defaultValue: "people nearby")
    static let scanning = String(localized: "nearby.transport.scanning", defaultValue: "Scanning...")
    static let visible = String(localized: "nearby.visibility.visible", defaultValue: "Visible to Nearby")
    static let hidden = String(localized: "nearby.visibility.hidden", defaultValue: "Hidden from Nearby")
    static let on = String(localized: "common.on", defaultValue: "ON")
    static let off = String(localized: "common.off", defaultValue: "OFF")
    static let visibleAccessibility = String(localized: "nearby.visibility.visible_accessibility", defaultValue: "Visible to nearby people, tap to hide")
    static let hiddenAccessibility = String(localized: "nearby.visibility.hidden_accessibility", defaultValue: "Hidden from nearby people, tap to show")
    static let peopleNearbyTitle = String(localized: "nearby.people.title", defaultValue: "People Nearby")
    static let friendsNearbyTitle = String(localized: "nearby.friends.title", defaultValue: "Friends Nearby")
    static let scanningTitle = String(localized: "nearby.empty.scanning_title", defaultValue: "Scanning for nearby peers...")
    static let scanningSubtitle = String(localized: "nearby.empty.scanning_subtitle", defaultValue: "Make sure Bluetooth is enabled and you're near other HeyBlip users.")
    static let bluetoothOffTitle = String(localized: "nearby.bluetooth_off.title", defaultValue: "Bluetooth is off")
    static let bluetoothOffSubtitle = String(localized: "nearby.bluetooth_off.subtitle", defaultValue: "Turn on Bluetooth to discover people nearby and join the mesh network.")
    static let openSettings = String(localized: "nearby.bluetooth_off.cta", defaultValue: "Open Settings")
    static let noFriendsNearby = String(localized: "nearby.friends.empty.title", defaultValue: "No friends nearby")
    static let noFriendsNearbySubtitle = String(localized: "nearby.friends.empty.subtitle", defaultValue: "Tap a peer above to send a friend request.")
    static let friendFinder = String(localized: "nearby.friend_finder.title", defaultValue: "Friend Finder")
    static let showMap = String(localized: "nearby.friend_finder.show_map", defaultValue: "Show Map")
    static let hide = String(localized: "common.hide", defaultValue: "Hide")
    static let hideFriendFinder = String(localized: "nearby.friend_finder.hide_accessibility", defaultValue: "Hide friend finder map")
    static let showFriendFinder = String(localized: "nearby.friend_finder.show_accessibility", defaultValue: "Show friend finder map")
    static let locationFixNeeded = String(localized: "nearby.friend_finder.location_fix_needed", defaultValue: "Friend Finder needs a real location fix and shared friend locations before the map can help.")
    static let locationAccessTitle = String(localized: "nearby.friend_finder.location_access_title", defaultValue: "Location access is needed for Friend Finder")
    static let locationAccessSubtitle = String(localized: "nearby.friend_finder.location_access_subtitle", defaultValue: "Enable location access to recenter on you, drop a beacon, and show shared friend locations.")
    static let noSharedLocationsTitle = String(localized: "nearby.friend_finder.no_shared_locations_title", defaultValue: "No shared friend locations yet")
    static let noSharedLocationsSubtitle = String(localized: "nearby.friend_finder.no_shared_locations_subtitle", defaultValue: "Nearby mesh peers can appear above without GPS sharing. The map fills in only when friends opt into location sharing.")
    static let tapToExpand = String(localized: "nearby.friend_finder.tap_to_expand", defaultValue: "Tap to expand")
    static let openFullMap = String(localized: "nearby.friend_finder.open_full_map", defaultValue: "Open full friend finder map")
    static let bluetoothNotActive = String(localized: "nearby.empty.bluetooth_not_active", defaultValue: "Bluetooth discovery is not active yet.")
    static let friendRequestPending = String(localized: "nearby.peer.friend_request_pending", defaultValue: "friend request pending")
    static let openProfile = String(localized: "nearby.peer.open_profile", defaultValue: "open nearby profile")
    static let previewSarahChen = String(localized: "nearby.preview.friend.sarah_chen", defaultValue: "Sarah Chen")
    static let previewJakeMorrison = String(localized: "nearby.preview.friend.jake_morrison", defaultValue: "Jake Morrison")
    static let previewPriyaPatel = String(localized: "nearby.preview.friend.priya_patel", defaultValue: "Priya Patel")
    static let previewAlex = String(localized: "nearby.preview.peer.alex", defaultValue: "Alex")
    static let previewMainField = String(localized: "nearby.preview.channel.main_field", defaultValue: "Main Field")
    static let previewCampingAreaB = String(localized: "nearby.preview.channel.camping_area_b", defaultValue: "Camping Area B")
    static let previewCarPark3 = String(localized: "nearby.preview.channel.car_park_3", defaultValue: "Car Park 3")
    static let previewFoodTruckMessage = String(localized: "nearby.preview.channel.food_trucks_message", defaultValue: "Anyone know where the food trucks moved?")
    static let previewShowersMessage = String(localized: "nearby.preview.channel.showers_message", defaultValue: "Showers open until midnight")
    static let previewSarah = String(localized: "nearby.preview.pin.sarah", defaultValue: "Sarah")
    static let previewJake = String(localized: "nearby.preview.pin.jake", defaultValue: "Jake")

    static func headerAccessibility(peerCount: Int, transportState: String) -> String {
        String(format: String(localized: "nearby.header.accessibility", defaultValue: "%1$d people nearby. Transport: %2$@."), locale: Locale.current, peerCount, transportState)
    }

    static func peerAccessibility(name: String, pending: Bool) -> String {
        let template = pending
            ? String(localized: "nearby.peer.accessibility.pending", defaultValue: "%1$@, %2$@")
            : String(localized: "nearby.peer.accessibility.profile", defaultValue: "%1$@, %2$@")
        let suffix = pending ? friendRequestPending : openProfile
        return String(format: template, locale: Locale.current, name, suffix)
    }
}

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
    // Presence broadcast cadence is owned by AppCoordinator (30s timer).
    // NearbyView only triggers an immediate broadcast on visibility toggle.

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
                        if coordinator.bleService?.isBluetoothDenied == true {
                            BluetoothPermissionBanner()
                                .padding(.horizontal, BlipSpacing.sm)
                        }

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
            .navigationTitle(NearbyL10n.title)
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
                displayName: peer.displayName ?? peer.username ?? NearbyL10n.unknown,
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
            coordinator.bleService?.enableRSSIPolling()
            await resolvedMeshViewModel?.refreshMeshState()
            await resolvedLocationViewModel?.refreshFriendLocationsForDisplay()
            loadVisibilityPreference()
        }
        .onDisappear {
            localMeshViewModel?.stopMonitoring()
            localLocationViewModel?.stopMonitoring()
            coordinator.bleService?.disableRSSIPolling()
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
                isOnline: true,
                hasSignalData: friend.hasSignalData
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
                createdBy: NearbyL10n.you,
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

                        Text(NearbyL10n.peopleNearby)
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

                        Text(resolvedMeshViewModel?.transportState ?? NearbyL10n.scanning)
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

                    Text(isVisible ? NearbyL10n.visible : NearbyL10n.hidden)
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)

                    Spacer()

                    Text(isVisible ? NearbyL10n.on : NearbyL10n.off)
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
            .accessibilityLabel(isVisible ? NearbyL10n.visibleAccessibility : NearbyL10n.hiddenAccessibility)
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

                    Text(NearbyL10n.peopleNearbyTitle)
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
                    let isPending = peer.friendStatus == .pending || friendRequestSent.contains(peer.id)
                    NearbyPeerCard(
                        displayName: peer.displayName ?? peer.username ?? NearbyL10n.unknown,
                        username: peer.username,
                        avatarData: nil,
                        hopCount: peer.isDirectPeer ? 0 : 1,
                        rssi: peer.rssi,
                        isOnline: true,
                        hasSignalData: peer.hasSignalData,
                        friendState: isPending ? .pending : .notFriend,
                        onTap: { selectedPeer = peer },
                        onAddFriend: isPending ? nil : { sendFriendRequest(to: peer) }
                    )
                    .padding(.horizontal, BlipSpacing.md)
                    .staggeredReveal(index: index)
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

                Text(NearbyL10n.friendsNearbyTitle)
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
                if resolvedMeshViewModel?.isBLEActive == true {
                    // Scanning state — glassmorphism card with pulsing indicator
                    GlassCard(thickness: .ultraThin) {
                        VStack(spacing: BlipSpacing.md) {
                            ProgressView()
                                .tint(.blipAccentPurple)
                                .scaleEffect(1.2)

                            Text(NearbyL10n.scanningTitle)
                                .font(theme.typography.secondary)
                                .foregroundStyle(theme.colors.text)

                            Text(NearbyL10n.scanningSubtitle)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.vertical, BlipSpacing.lg)
                    .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
                } else {
                    EmptyStateView(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: NearbyL10n.bluetoothOffTitle,
                        subtitle: NearbyL10n.bluetoothOffSubtitle,
                        ctaTitle: NearbyL10n.openSettings
                    ) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .padding(.vertical, BlipSpacing.lg)
                    .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
                }
            } else if nearbyFriends.isEmpty {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(theme.colors.mutedText)

                        Text(NearbyL10n.noFriendsNearby)
                            .font(theme.typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.colors.text)

                        Text(NearbyL10n.noFriendsNearbySubtitle)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, BlipSpacing.md)
                .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
            } else {
                ForEach(Array(nearbyFriends.enumerated()), id: \.element.id) { index, friend in
                    NearbyPeerCard(
                        displayName: friend.displayName,
                        username: friend.username,
                        avatarData: nil,
                        hopCount: friend.hopCount,
                        rssi: friend.rssi,
                        isOnline: friend.isOnline,
                        hasSignalData: friend.hasSignalData,
                        friendState: .friends
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
            broadcastPresenceOnce()
        } else {
            // Presence stops naturally via AppCoordinator when app backgrounds
        }
    }

    private func loadVisibilityPreference() {
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<UserPreferences>()
        do {
            if let prefs = try context.fetch(descriptor).first {
                isVisible = prefs.nearbyVisibilityEnabled
                if isVisible {
                    broadcastPresenceOnce()
                }
            }
        } catch {
            DebugLogger.shared.log("APP", "Failed to load visibility preference: \(error)", isError: true)
        }
    }

    private func saveVisibilityPreference() {
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<UserPreferences>()
        do {
            if let prefs = try context.fetch(descriptor).first {
                prefs.nearbyVisibilityEnabled = isVisible
                try context.save()
            }
        } catch {
            DebugLogger.shared.log("APP", "Failed to save visibility preference: \(error)", isError: true)
        }
    }

    /// Trigger a single immediate presence broadcast.
    /// The recurring 30s cadence is owned by AppCoordinator.announceTimer.
    private func broadcastPresenceOnce() {
        guard let messageService = coordinator.messageService else { return }
        Task {
            do {
                try await messageService.broadcastPresence()
            } catch {
                DebugLogger.shared.log("PRESENCE", "Immediate broadcast failed: \(error)", isError: true)
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

                Text(NearbyL10n.friendFinder)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Button(action: { withAnimation { showMap.toggle() } }) {
                    Text(showMap ? NearbyL10n.hide : NearbyL10n.showMap)
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
                .accessibilityLabel(showMap ? NearbyL10n.hideFriendFinder : NearbyL10n.showFriendFinder)
            }
            .padding(.horizontal, BlipSpacing.md)

            if showMap {
                VStack(spacing: BlipSpacing.md) {
                    if let locationError = resolvedLocationViewModel?.errorMessage {
                        statusCard(
                            icon: "location.slash.fill",
                            title: locationError,
                            subtitle: NearbyL10n.locationFixNeeded
                        )
                    } else if userLocation == nil {
                        statusCard(
                            icon: "location.circle",
                            title: NearbyL10n.locationAccessTitle,
                            subtitle: NearbyL10n.locationAccessSubtitle
                        )
                    } else if friendPins.isEmpty {
                        statusCard(
                            icon: "person.2.slash",
                            title: NearbyL10n.noSharedLocationsTitle,
                            subtitle: NearbyL10n.noSharedLocationsSubtitle
                        )
                    }

                    NavigationLink {
                        FriendFinderMapView(
                            friendFinderViewModel: coordinator.friendFinderViewModel,
                            locationService: coordinator.locationService,
                            locationViewModel: resolvedLocationViewModel
                        )
                    } label: {
                        FriendFinderMap(
                            friends: friendPins,
                            userLocation: userLocation,
                            beacons: beaconPins,
                            onDropBeacon: { _ in },
                            onNavigateToFriend: { _ in }
                        )
                        .frame(height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xl))
                        .overlay(alignment: .bottom) {
                            Text(NearbyL10n.tapToExpand)
                                .font(theme.typography.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, BlipSpacing.md)
                                .padding(.vertical, BlipSpacing.xs)
                                .background(Capsule().fill(.black.opacity(0.5)))
                                .padding(.bottom, BlipSpacing.sm)
                        }
                        .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NearbyL10n.openFullMap)
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
        NearbyL10n.headerAccessibility(
            peerCount: peerCount,
            transportState: resolvedMeshViewModel?.transportState ?? NearbyL10n.scanning
        )
    }

    private var emptyNearbyStateText: String {
        if let locationError = resolvedLocationViewModel?.errorMessage {
            return locationError
        }

        if resolvedMeshViewModel?.isBLEActive != true {
            return NearbyL10n.bluetoothNotActive
        }

        return NearbyL10n.scanningTitle
    }

    private func peerAccessibilityLabel(_ peer: MeshViewModel.NearbyPeer) -> String {
        let name = peer.displayName ?? peer.username ?? NearbyL10n.unknown
        return NearbyL10n.peerAccessibility(
            name: name,
            pending: peer.friendStatus == .pending || friendRequestSent.contains(peer.id)
        )
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
    let hasSignalData: Bool
}

// MARK: - Sample Data

extension NearbyView {

    static let sampleFriends: [NearbyPeerCard_Data] = [
        NearbyPeerCard_Data(id: UUID(), displayName: NearbyL10n.previewSarahChen, username: "sarahc", hopCount: 0, rssi: -45, isOnline: true, hasSignalData: true),
        NearbyPeerCard_Data(id: UUID(), displayName: NearbyL10n.previewJakeMorrison, username: "jakem", hopCount: 1, rssi: -62, isOnline: true, hasSignalData: true),
        NearbyPeerCard_Data(id: UUID(), displayName: NearbyL10n.previewPriyaPatel, username: "priyap", hopCount: 3, rssi: -78, isOnline: true, hasSignalData: true),
    ]

    static let samplePeers: [NearbyPeerCard_Data] = [
        NearbyPeerCard_Data(id: UUID(), displayName: NearbyL10n.previewAlex, username: nil, hopCount: 2, rssi: -70, isOnline: true, hasSignalData: true),
        NearbyPeerCard_Data(id: UUID(), displayName: "MeshUser_7f3a", username: nil, hopCount: 4, rssi: -85, isOnline: false, hasSignalData: true),
    ]

    static let sampleChannels: [LocationChannelItem] = [
        LocationChannelItem(id: UUID(), name: NearbyL10n.previewMainField, iconName: "mappin.and.ellipse", memberCount: 42, lastMessagePreview: NearbyL10n.previewFoodTruckMessage, lastActivityAt: Date().addingTimeInterval(-120), isAutoJoined: true, geohash: "gcpu2e"),
        LocationChannelItem(id: UUID(), name: NearbyL10n.previewCampingAreaB, iconName: "tent.fill", memberCount: 18, lastMessagePreview: NearbyL10n.previewShowersMessage, lastActivityAt: Date().addingTimeInterval(-300), isAutoJoined: false, geohash: "gcpu2f"),
        LocationChannelItem(id: UUID(), name: NearbyL10n.previewCarPark3, iconName: "car.fill", memberCount: 7, lastMessagePreview: nil, lastActivityAt: nil, isAutoJoined: false, geohash: "gcpu2g"),
    ]

    static let sampleFriendPins: [FriendMapPin] = [
        FriendMapPin(id: UUID(), displayName: NearbyL10n.previewSarah, coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862), precision: .precise, color: .blue, lastUpdated: Date()),
        FriendMapPin(id: UUID(), displayName: NearbyL10n.previewJake, coordinate: CLLocationCoordinate2D(latitude: 51.0052, longitude: -2.5850), precision: .fuzzy, color: .green, lastUpdated: Date().addingTimeInterval(-60)),
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
