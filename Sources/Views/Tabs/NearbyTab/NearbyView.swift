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
    static let friendsNearbyLabel = String(localized: "nearby.friends_count.label", defaultValue: "friends nearby")
    static let scanning = String(localized: "nearby.transport.scanning", defaultValue: "Scanning...")
    static let visible = String(localized: "nearby.visibility.visible", defaultValue: "Visible to Nearby")
    static let hidden = String(localized: "nearby.visibility.hidden", defaultValue: "Hidden from Nearby")
    static let on = String(localized: "common.on", defaultValue: "ON")
    static let off = String(localized: "common.off", defaultValue: "OFF")
    static let visibleAccessibility = String(localized: "nearby.visibility.visible_accessibility", defaultValue: "Visible to nearby people, tap to hide")
    static let hiddenAccessibility = String(localized: "nearby.visibility.hidden_accessibility", defaultValue: "Hidden from nearby people, tap to show")
    static let friendsNearbyTitle = String(localized: "nearby.friends.title", defaultValue: "Friends Nearby")
    static let scanningTitle = String(localized: "nearby.empty.scanning_title", defaultValue: "Scanning for nearby peers...")
    static let scanningSubtitle = String(localized: "nearby.empty.scanning_subtitle", defaultValue: "Make sure Bluetooth is enabled and you're near other HeyBlip users.")
    static let bluetoothOffTitle = String(localized: "nearby.bluetooth_off.title", defaultValue: "Bluetooth is off")
    static let bluetoothOffSubtitle = String(localized: "nearby.bluetooth_off.subtitle", defaultValue: "Turn on Bluetooth to discover people nearby and join the mesh network.")
    static let openSettings = String(localized: "nearby.bluetooth_off.cta", defaultValue: "Open Settings")
    static let noFriendsNearby = String(localized: "nearby.friends.empty.title", defaultValue: "No friends nearby")
    static let noFriendsNearbySubtitle = String(localized: "nearby.friends.empty.subtitle", defaultValue: "Tap a peer above to send a friend request.")
    static let hideFriendFinder = String(localized: "nearby.friend_finder.hide_accessibility", defaultValue: "Hide friend finder map")
    static let showFriendFinder = String(localized: "nearby.friend_finder.show_accessibility", defaultValue: "Show friend finder map")
    static let locationFixNeeded = String(localized: "nearby.friend_finder.location_fix_needed", defaultValue: "Friend Finder needs a real location fix and shared friend locations before the map can help.")
    static let locationAccessTitle = String(localized: "nearby.friend_finder.location_access_title", defaultValue: "Location access is needed for Friend Finder")
    static let locationAccessSubtitle = String(localized: "nearby.friend_finder.location_access_subtitle", defaultValue: "Enable location access to recenter on you, drop a beacon, and show shared friend locations.")
    static let noSharedLocationsTitle = String(localized: "nearby.friend_finder.no_shared_locations_title", defaultValue: "No shared friend locations yet")
    static let noSharedLocationsSubtitle = String(localized: "nearby.friend_finder.no_shared_locations_subtitle", defaultValue: "Nearby mesh peers can appear above without GPS sharing. The map fills in only when friends opt into location sharing.")
    static let tapToExpand = String(localized: "nearby.friend_finder.tap_to_expand", defaultValue: "Tap to expand")
    static let openFullMap = String(localized: "nearby.friend_finder.open_full_map", defaultValue: "Open full friend finder map")
    static let previewSarah = "Sarah"
    static let previewJake = "Jake"

    static func headerAccessibility(friendCount: Int, transportState: String) -> String {
        String(format: String(localized: "nearby.header.accessibility", defaultValue: "%1$d friends nearby. Transport: %2$@."), locale: Locale.current, friendCount, transportState)
    }

}

// MARK: - NearbyView

/// Main view for the Nearby tab.
///
/// Friends-only surface: "X friends nearby" header, visibility toggle, and a
/// single unified Friends Nearby section that contains both the friend-finder
/// map and the list of mesh-reachable friends. Non-friend peer cards and the
/// location channels list were removed — they belong to other surfaces now.
struct NearbyView: View {

    var meshViewModel: MeshViewModel? = nil
    var locationViewModel: LocationViewModel? = nil

    @State private var localMeshViewModel: MeshViewModel?
    @State private var localLocationViewModel: LocationViewModel?
    @State private var showMap = false
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

                // Ambient mesh particles behind content. We still pass the
                // friends-nearby count so the visual density scales with
                // actual friend presence.
                MeshParticleView(peerCount: friendsNearbyCount)
                    .opacity(0.6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                        if coordinator.bleService?.isBluetoothDenied == true {
                            BluetoothPermissionBanner()
                                .padding(.horizontal, BlipSpacing.sm)
                        }

                        headerSection
                            .staggeredReveal(index: 0)

                        // Unified "Friends Nearby" section. Holds a tappable
                        // map preview (Friend Finder) and the list of nearby
                        // friends below it. Non-friend peers and location
                        // channels live in other surfaces.
                        friendsNearbySection
                            .staggeredReveal(index: 1)

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

    /// The friends-only peer count shown in the header card and used for
    /// accessibility. Formerly a mesh-wide peer count — now scoped to friends
    /// because the Nearby tab is friends/contacts only.
    private var friendsNearbyCount: Int {
        resolvedMeshViewModel?.nearbyFriends.count ?? 0
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

    private var friendPins: [FriendMapPin] {
        guard let vm = resolvedLocationViewModel else { return [] }
        let userCoordinate = vm.userLocation

        return vm.friendAnnotations.map { friend in
            FriendMapPin(
                id: friend.friendID,
                displayName: friend.name,
                coordinate: friend.coordinate,
                precision: mapPrecision(friend.precision),
                color: FriendMapPin.trailColor(for: friend.friendID),
                lastUpdated: friend.lastUpdated,
                accuracyMeters: friend.precision == .precise ? 12 : 60,
                distanceFromUser: userCoordinate.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: CLLocation(latitude: friend.coordinate.latitude, longitude: friend.coordinate.longitude))
                },
                isOutOfRange: Date().timeIntervalSince(friend.lastUpdated) > 1_800,
                breadcrumbs: friend.breadcrumbs
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
                    // Animated friend count (friends reachable on mesh)
                    VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                        Text("\(friendsNearbyCount)")
                            .font(theme.typography.display)
                            .foregroundStyle(.blipAccentPurple)
                            .contentTransition(.numericText())

                        Text(NearbyL10n.friendsNearbyLabel)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.colors.text)
                    }

                    Spacer()

                    // Signal indicator
                    VStack(spacing: BlipSpacing.xs) {
                        Image(systemName: resolvedMeshViewModel?.isBLEActive == true ? "wave.3.right" : "wave.3.right.circle")
                            .font(theme.typography.title2)
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
                        .font(theme.typography.secondary)

                    Text(isVisible ? NearbyL10n.visible : NearbyL10n.hidden)
                        .font(theme.typography.secondary)
                        .fontWeight(.medium)

                    Spacer()

                    Text(isVisible ? NearbyL10n.on : NearbyL10n.off)
                        .font(theme.typography.caption)
                        .fontWeight(.bold)
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

    // MARK: - Friends Nearby (unified Friend Finder + list)

    /// Unified friends section: a tappable Friend Finder map preview on top
    /// and a list of mesh-reachable friends underneath. Supersedes the old
    /// separate "People Nearby" + "Friends Nearby" + "Friend Finder" sections
    /// — the Nearby tab is friends/contacts only, no non-friend peers and
    /// no location-channel chrome.
    @ViewBuilder
    private var friendsNearbySection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            sectionHeader

            mapPreview

            friendList
        }
    }

    private var sectionHeader: some View {
        HStack {
            Image(systemName: "person.2.fill")
                .font(theme.typography.secondary)
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

            Button(action: { withAnimation(SpringConstants.gentleAnimation) { showMap.toggle() } }) {
                Image(systemName: showMap ? "map.fill" : "map")
                    .font(theme.typography.secondary)
                    .foregroundStyle(.blipAccentPurple)
                    .padding(BlipSpacing.xs)
                    .background(Capsule().fill(.blipAccentPurple.opacity(0.12)))
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
            .accessibilityLabel(showMap ? NearbyL10n.hideFriendFinder : NearbyL10n.showFriendFinder)
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    @ViewBuilder
    private var mapPreview: some View {
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
                    .frame(height: 220)
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
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    @ViewBuilder
    private var friendList: some View {
        if nearbyFriends.isEmpty {
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
                .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
            } else if coordinator.bleService?.isBluetoothDenied == true {
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
                .padding(.horizontal, BlipSpacing.md)
                .transition(.opacity.animation(SpringConstants.accessiblePageEntrance))
            } else {
                GlassCard(thickness: .ultraThin) {
                    VStack(spacing: BlipSpacing.sm) {
                        Image(systemName: "person.2.slash")
                            .font(theme.typography.title2)
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
            }
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
                    friendState: .friends,
                    onTap: {
                        // Tap a friend → drop the user straight into the DM with them.
                        // The card was previously a "no-op button" — visually a button
                        // but tapping did nothing, which feels broken in a chat app.
                        guard let username = friend.username else { return }
                        Task { await coordinator.openDM(withUsername: username) }
                    }
                )
                .padding(.horizontal, BlipSpacing.md)
                .staggeredReveal(index: index)
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

    // MARK: - Status Card

    private func statusCard(icon: String, title: String, subtitle: String) -> some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.xl) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: icon)
                        .font(theme.typography.secondary)
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
            friendCount: friendsNearbyCount,
            transportState: resolvedMeshViewModel?.transportState ?? NearbyL10n.scanning
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

    // Used by other previews (e.g. StageMapView).
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
