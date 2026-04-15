import SwiftUI
import MapKit
import SwiftData
import CoreLocation

private enum FriendFinderMapViewL10n {
    static let title = String(localized: "nearby.friend_finder.title", defaultValue: "Friend Finder")
    static let dropBeaconTitle = String(localized: "nearby.friend_finder.drop_beacon.title", defaultValue: "Drop Beacon")
    static let dropHere = String(localized: "nearby.friend_finder.drop_beacon.confirm", defaultValue: "Drop Here")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let dropBeaconMessage = String(localized: "nearby.friend_finder.drop_beacon.message", defaultValue: "Share your current location as a beacon. It will expire in 30 minutes.")
    static let you = String(localized: "common.you", defaultValue: "You")
    static let userLocationSharing = String(localized: "nearby.friend_finder.user_location.sharing", defaultValue: "Your location, sharing active")
    static let userLocation = String(localized: "nearby.friend_finder.user_location", defaultValue: "Your location")
    static let recenter = String(localized: "nearby.friend_finder.control.recenter", defaultValue: "Recenter")
    static let stopSharing = String(localized: "nearby.friend_finder.control.stop_sharing", defaultValue: "Stop sharing")
    static let shareLocation = String(localized: "nearby.friend_finder.control.share_location", defaultValue: "Share location")
    static let dropBeacon = String(localized: "nearby.friend_finder.control.drop_beacon", defaultValue: "Drop beacon")
    static let hideList = String(localized: "nearby.friend_finder.control.hide_list", defaultValue: "Hide list")
    static let showList = String(localized: "nearby.friend_finder.control.show_list", defaultValue: "Show list")
    static let friends = String(localized: "common.friends", defaultValue: "Friends")
    static let noLocations = String(localized: "nearby.friend_finder.empty.title", defaultValue: "No shared friend locations yet")
    static let noLocationsSubtitle = String(localized: "nearby.friend_finder.empty.subtitle", defaultValue: "Only friends who actively share location over the mesh appear here.")
    static let outOfRange = String(localized: "nearby.friend_finder.friend.out_of_range", defaultValue: "Out of range")
    static let locationPermissionNeeded = String(localized: "nearby.friend_finder.banner.location_needed", defaultValue: "Location permission or a fresh GPS fix is still needed.")
    static let waitingForFriends = String(localized: "nearby.friend_finder.banner.waiting", defaultValue: "Waiting for friends to share their live location over the mesh.")
    static let liveSharingActive = String(localized: "nearby.friend_finder.banner.active", defaultValue: "Live location sharing is active for this session.")
    static let close = String(localized: "common.close", defaultValue: "Close")
    static let imHere = String(localized: "nearby.friend_finder.beacon.default_label", defaultValue: "I'm here!")
    static let previewSarahChen = "Sarah Chen"
    static let previewJakeMorrison = "Jake Morrison"
    static let previewPriyaPatel = "Priya Patel"
    static let previewAlexRivera = "Alex Rivera"
    static let previewMiaKim = "Mia Kim"

    static func nearbyCount(_ count: Int) -> String {
        String(format: String(localized: "nearby.friend_finder.count_nearby", defaultValue: "%d nearby"), locale: Locale.current, count)
    }

    static func navigateTo(_ name: String) -> String {
        String(format: String(localized: "nearby.friend_finder.navigate_accessibility_label", defaultValue: "Navigate to %@"), locale: Locale.current, name)
    }

    static func friendRowAccessibility(name: String, detail: String) -> String {
        String(format: String(localized: "nearby.friend_finder.friend_row.accessibility_label", defaultValue: "%@, %@"), locale: Locale.current, name, detail)
    }

    static func beacon(_ label: String) -> String {
        String(format: String(localized: "nearby.friend_finder.beacon_accessibility_label", defaultValue: "Beacon: %@"), locale: Locale.current, label)
    }
}

// MARK: - FriendFinderMapView

/// Full-screen friend finder with map, "I'm Here" beacon toggle,
/// precision radius rings, and a bottom sheet friend list.
///
/// Displays real friend locations from LocationViewModel (SwiftData) merged
/// with live mesh peers from FriendFinderViewModel. Falls back to sample
/// data only in `#Preview` blocks.
struct FriendFinderMapView: View {

    var friendFinderViewModel: FriendFinderViewModel? = nil
    var locationService: LocationService? = nil
    var locationViewModel: LocationViewModel? = nil

    @State private var localLocationViewModel: LocationViewModel?
    @State private var fallbackFriends: [FriendMapPin]
    @State private var fallbackBeacons: [BeaconPin]

    /// Standard initializer for runtime use with real data sources.
    init(
        friendFinderViewModel: FriendFinderViewModel? = nil,
        locationService: LocationService? = nil,
        locationViewModel: LocationViewModel? = nil
    ) {
        self.friendFinderViewModel = friendFinderViewModel
        self.locationService = locationService
        self.locationViewModel = locationViewModel
        _fallbackFriends = State(initialValue: [])
        _fallbackBeacons = State(initialValue: [])
    }

    /// Preview-only initializer that injects sample friends for Xcode previews.
    init(previewFriends: [FriendMapPin], previewBeacons: [BeaconPin] = []) {
        self.friendFinderViewModel = nil
        self.locationService = nil
        self.locationViewModel = nil
        _fallbackFriends = State(initialValue: previewFriends)
        _fallbackBeacons = State(initialValue: previewBeacons)
    }
    @State private var isSharingLocation = false
    @State private var selectedFriend: FriendMapPin? = nil
    @State private var showFriendList = true
    @State private var showBeaconConfirm = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var sharingPulse = false
    @State private var currentUserLocation: CLLocationCoordinate2D? = nil
    @State private var locationRefreshTimer: Timer?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack(alignment: .bottom) {
            // Map layer
            mapLayer

            // Controls
            VStack {
                if friendFinderViewModel != nil || resolvedLocationViewModel != nil {
                    availabilityBanner
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.top, BlipSpacing.sm)
                }

                HStack {
                    Spacer()
                    controlButtons
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.top, BlipSpacing.sm)

                Spacer()
            }

            // Friend list bottom sheet
            if showFriendList {
                friendListSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(FriendFinderMapViewL10n.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await initializeLiveState()
        }
        .onDisappear {
            stopLocationRefresh()
            localLocationViewModel?.stopMonitoring()
        }
        .alert(FriendFinderMapViewL10n.dropBeaconTitle, isPresented: $showBeaconConfirm) {
            Button(FriendFinderMapViewL10n.dropHere) { performDropBeacon() }
            Button(FriendFinderMapViewL10n.cancel, role: .cancel) {}
        } message: {
            Text(FriendFinderMapViewL10n.dropBeaconMessage)
        }
    }

    // MARK: - Map Layer

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            // User location with "I'm Here" pulse
            if let resolvedUserLocation {
                Annotation(FriendFinderMapViewL10n.you, coordinate: resolvedUserLocation) {
                    userPinView
                }
            }

            // Friend pins
            ForEach(displayFriends.filter({ !$0.isOutOfRange })) { friend in
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
            ForEach(displayBeacons) { beacon in
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
        .overlay(alignment: .bottom) {
            if let selectedFriend {
                friendDetailCard(for: selectedFriend)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.bottom, showFriendList ? 260 : BlipSpacing.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: selectedFriend?.id)
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
        .accessibilityLabel(isSharingLocation ? FriendFinderMapViewL10n.userLocationSharing : FriendFinderMapViewL10n.userLocation)
    }

    private func startSharingPulse() {
        guard !SpringConstants.isReduceMotionEnabled else { return }
        withAnimation(SpringConstants.gentleAnimation.repeatForever(autoreverses: false)) {
            sharingPulse = true
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        VStack(spacing: BlipSpacing.sm) {
            // Recenter
            mapButton(icon: "location.fill", label: FriendFinderMapViewL10n.recenter) {
                withAnimation { cameraPosition = .automatic }
            }

            // Toggle location sharing
            mapButton(
                icon: isSharingLocation ? "location.fill.viewfinder" : "location.viewfinder",
                label: isSharingLocation ? FriendFinderMapViewL10n.stopSharing : FriendFinderMapViewL10n.shareLocation,
                isActive: isSharingLocation
            ) {
                toggleLocationSharing()
            }

            // Drop beacon
            mapButton(icon: "mappin.and.ellipse", label: FriendFinderMapViewL10n.dropBeacon, isAccent: true) {
                showBeaconConfirm = true
            }

            // Toggle friend list
            mapButton(
                icon: showFriendList ? "list.bullet.circle.fill" : "list.bullet.circle",
                label: showFriendList ? FriendFinderMapViewL10n.hideList : FriendFinderMapViewL10n.showList
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
                Text(FriendFinderMapViewL10n.friends)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text(FriendFinderMapViewL10n.nearbyCount(displayFriends.filter { !$0.isOutOfRange }.count))
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
                    if displayFriends.isEmpty {
                        emptyFriendListState
                    } else {
                        ForEach(displayFriends) { friend in
                            friendRow(friend)
                        }
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

    private var emptyFriendListState: some View {
        VStack(spacing: BlipSpacing.sm) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 24))
                .foregroundStyle(theme.colors.mutedText)

            Text(FriendFinderMapViewL10n.noLocations)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)

            Text(FriendFinderMapViewL10n.noLocationsSubtitle)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BlipSpacing.lg)
        .padding(.horizontal, BlipSpacing.md)
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
                        Text(FriendFinderMapViewL10n.outOfRange)
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
        .accessibilityLabel(FriendFinderMapViewL10n.friendRowAccessibility(name: friend.displayName, detail: friend.isOutOfRange ? FriendFinderMapViewL10n.outOfRange.lowercased() : friend.lastSeenText))
    }

    private var availabilityBanner: some View {
        Group {
            if resolvedUserLocation == nil {
                statusBanner(
                    icon: "location.slash.fill",
                    title: FriendFinderMapViewL10n.locationPermissionNeeded,
                    tint: theme.colors.statusAmber
                )
            } else if displayFriends.isEmpty {
                statusBanner(
                    icon: "dot.radiowaves.left.and.right",
                    title: FriendFinderMapViewL10n.waitingForFriends,
                    tint: theme.colors.mutedText
                )
            } else {
                statusBanner(
                    icon: "location.fill.viewfinder",
                    title: FriendFinderMapViewL10n.liveSharingActive,
                    tint: theme.colors.statusGreen
                )
            }
        }
    }

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

                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: friend.coordinate))
                    item.name = friend.displayName
                    item.openInMaps(launchOptions: [
                        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
                    ])
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                        .background(Circle().fill(LinearGradient.blipAccent))
                }
                .accessibilityLabel(FriendFinderMapViewL10n.navigateTo(friend.displayName))

                Button {
                    selectedFriend = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.colors.mutedText)
                        .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                }
                .accessibilityLabel(FriendFinderMapViewL10n.close)
            }
            .padding(BlipSpacing.md)
        }
    }

    private func statusBanner(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)

            Text(title)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.text)

            Spacer()
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
    }

    // MARK: - Resolved ViewModels

    private var resolvedLocationViewModel: LocationViewModel? {
        locationViewModel ?? localLocationViewModel
    }

    /// Friend pins built from SwiftData via LocationViewModel, matching NearbyView's pattern.
    private var swiftDataFriendPins: [FriendMapPin] {
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

    private var displayFriends: [FriendMapPin] {
        // Merge live mesh friends (from FriendFinderViewModel) with
        // SwiftData friends (from LocationViewModel). Mesh data takes
        // priority when both exist for the same friend (by ID).
        let meshFriends = friendFinderViewModel?.friends ?? []
        let storedFriends = swiftDataFriendPins

        if meshFriends.isEmpty && storedFriends.isEmpty {
            return fallbackFriends
        }

        var merged: [UUID: FriendMapPin] = [:]
        for pin in storedFriends {
            merged[pin.id] = pin
        }
        // Mesh data overwrites stored data when present (fresher).
        for pin in meshFriends {
            merged[pin.id] = pin
        }
        return Array(merged.values)
    }

    private var displayBeacons: [BeaconPin] {
        let meshBeacons = friendFinderViewModel?.beacons ?? []
        let storedBeacons: [BeaconPin] = {
            guard let beacon = resolvedLocationViewModel?.activeBeacon else { return [] }
            return [
                BeaconPin(
                    id: beacon.id,
                    label: beacon.label,
                    coordinate: beacon.coordinate,
                    createdBy: FriendFinderMapViewL10n.you,
                    expiresAt: beacon.expiresAt
                )
            ]
        }()

        if meshBeacons.isEmpty && storedBeacons.isEmpty {
            return fallbackBeacons
        }

        var merged: [UUID: BeaconPin] = [:]
        for pin in storedBeacons {
            merged[pin.id] = pin
        }
        for pin in meshBeacons {
            merged[pin.id] = pin
        }
        return Array(merged.values)
    }

    private var resolvedUserLocation: CLLocationCoordinate2D? {
        currentUserLocation
            ?? friendFinderViewModel?.userLocation
            ?? resolvedLocationViewModel?.userLocation
    }

    private func initializeLiveState() async {
        guard let locationService else { return }

        // Create a local LocationViewModel to query SwiftData friend locations
        // if one was not injected (mirrors the pattern used in NearbyView).
        if resolvedLocationViewModel == nil {
            localLocationViewModel = LocationViewModel(
                modelContainer: modelContext.container,
                locationService: locationService
            )
        }
        localLocationViewModel?.startMonitoring()
        await resolvedLocationViewModel?.refreshFriendLocationsForDisplay()

        locationService.requestAuthorization()
        locationService.startUpdating(accuracy: .friendSharing)
        refreshLocationSnapshot()
        startLocationRefresh()
        friendFinderViewModel?.sendProximityPing()
    }

    private func refreshLocationSnapshot() {
        guard let locationService else { return }
        guard let location = locationService.currentLocation else { return }

        currentUserLocation = location.coordinate
        friendFinderViewModel?.updateUserLocation(location)
    }

    private func startLocationRefresh() {
        stopLocationRefresh()

        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                refreshLocationSnapshot()
                await resolvedLocationViewModel?.refreshFriendLocationsForDisplay()
                if isSharingLocation {
                    friendFinderViewModel?.broadcastLocation()
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        locationRefreshTimer = timer
    }

    private func stopLocationRefresh() {
        locationRefreshTimer?.invalidate()
        locationRefreshTimer = nil
    }

    private func toggleLocationSharing() {
        if !isSharingLocation && resolvedUserLocation == nil {
            return
        }

        withAnimation(SpringConstants.accessiblePageEntrance) {
            isSharingLocation.toggle()
        }

        friendFinderViewModel?.isSharingLocation = isSharingLocation
        refreshLocationSnapshot()

        if isSharingLocation {
            friendFinderViewModel?.broadcastLocation()
        }
    }

    private func performDropBeacon() {
        guard friendFinderViewModel != nil else {
            guard let resolvedUserLocation else { return }
            withAnimation(SpringConstants.accessiblePageEntrance) {
                fallbackBeacons.append(
                    BeaconPin(
                        id: UUID(),
                        label: FriendFinderMapViewL10n.imHere,
                        coordinate: resolvedUserLocation,
                        createdBy: FriendFinderMapViewL10n.you,
                        expiresAt: Date().addingTimeInterval(1800)
                    )
                )
            }
            return
        }

        refreshLocationSnapshot()
        friendFinderViewModel?.dropBeacon()
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
}

// MARK: - Friend Finder Pin View (standalone, not using FriendFinderMap's internal)

private struct FriendFinderPinView: View {

    let friend: FriendMapPin
    let isSelected: Bool
    let onTap: () -> Void

    @State private var ringPulsing = false

    var body: some View {
        let baseSize: CGFloat = {
            guard !isSelected else { return 36 }
            guard let rssi = friend.rssiMeters else { return 28 }
            let clamped = min(max(rssi, 2), 30)
            return CGFloat(34 - (clamped - 2) * (12.0 / 28.0))
        }()

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
                        size: baseSize,
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
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xxs)
                        .background(Capsule().fill(friend.color))
                    }
                }
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FriendFinderMapViewL10n.friendRowAccessibility(name: friend.displayName, detail: friend.lastSeenText))
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled, friend.accuracyMeters > 0 else { return }
            // Ambient loop — easeInOut intentional
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
                    .padding(.horizontal, BlipSpacing.xs)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(Capsule().fill(.blipAccentPurple))
            }
        }
        .onAppear {
            guard !SpringConstants.isReduceMotionEnabled else { return }
            // Ambient loop — easeInOut intentional
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityLabel(FriendFinderMapViewL10n.beacon(beacon.label))
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
            id: UUID(), displayName: FriendFinderMapViewL10n.previewSarahChen,
            coordinate: CLLocationCoordinate2D(latitude: 51.0048, longitude: -2.5862),
            precision: .precise, color: .blue,
            lastUpdated: Date().addingTimeInterval(-120),
            accuracyMeters: 5, distanceFromUser: 45
        ),
        FriendMapPin(
            id: UUID(), displayName: FriendFinderMapViewL10n.previewJakeMorrison,
            coordinate: CLLocationCoordinate2D(latitude: 51.0052, longitude: -2.5850),
            precision: .precise, color: .green,
            lastUpdated: Date().addingTimeInterval(-30),
            accuracyMeters: 8, distanceFromUser: 120
        ),
        FriendMapPin(
            id: UUID(), displayName: FriendFinderMapViewL10n.previewPriyaPatel,
            coordinate: CLLocationCoordinate2D(latitude: 51.0040, longitude: -2.5870),
            precision: .fuzzy, color: .orange,
            lastUpdated: Date().addingTimeInterval(-600),
            accuracyMeters: 40, distanceFromUser: 280
        ),
        FriendMapPin(
            id: UUID(), displayName: FriendFinderMapViewL10n.previewAlexRivera,
            coordinate: CLLocationCoordinate2D(latitude: 51.0055, longitude: -2.5845),
            precision: .precise, color: .purple,
            lastUpdated: Date().addingTimeInterval(-3600),
            accuracyMeters: 80, distanceFromUser: 500,
            isOutOfRange: true
        ),
        FriendMapPin(
            id: UUID(), displayName: FriendFinderMapViewL10n.previewMiaKim,
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
        FriendFinderMapView(
            previewFriends: FriendFinderMapView.sampleFriends
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.theme, Theme.shared)
}

#Preview("Friend Finder Map - Light") {
    NavigationStack {
        FriendFinderMapView(
            previewFriends: FriendFinderMapView.sampleFriends
        )
    }
    .preferredColorScheme(.light)
    .environment(\.theme, Theme.resolved(for: .light))
}
