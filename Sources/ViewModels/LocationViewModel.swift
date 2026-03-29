import Foundation
import SwiftData
import os.log
import CoreLocation
import MapKit
import FestiChatProtocol

// MARK: - Location View Model

/// Manages the friend finder map state, location sharing, "I'm here" beacons, and navigation.
///
/// Features:
/// - Map displaying friend locations with annotations
/// - Per-friend location sharing toggle with precision control
/// - "I'm here" beacon: drop a labeled pin that broadcasts your location
/// - Navigate to friend (estimated direction and distance)
/// - Breadcrumb trail display for friend movement history
@MainActor
@Observable
final class LocationViewModel {

    // MARK: - Published State

    /// Friend locations for map display.
    var friendAnnotations: [FriendAnnotation] = []

    /// Active "I'm here" beacon, if set.
    var activeBeacon: BeaconInfo?

    /// Meeting points on the map.
    var meetingPoints: [MeetingPointAnnotation] = []

    /// Current map region.
    var mapRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.4545, longitude: -2.5879), // Default: Glastonbury area
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    /// Whether location sharing is globally enabled.
    var isLocationSharingEnabled = false

    /// Current user location for map centering.
    var userLocation: CLLocationCoordinate2D?

    /// Selected friend for navigation.
    var selectedFriend: FriendAnnotation?

    /// Navigation info to selected friend.
    var navigationInfo: NavigationInfo?

    /// Whether the map is following the user's location.
    var isFollowingUser = true

    /// Whether location services are authorized.
    var isLocationAuthorized = false

    /// Error message, if any.
    var errorMessage: String?

    /// Map style from user preferences.
    var mapStyle: MapStyle = .standard

    // MARK: - Supporting Types

    struct FriendAnnotation: Identifiable, Sendable {
        let id: UUID
        let friendID: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
        let precision: LocationPrecision
        let lastUpdated: Date
        let geohash: String?
        let areaName: String?
        let breadcrumbs: [CLLocationCoordinate2D]
    }

    struct BeaconInfo: Identifiable, Sendable {
        let id: UUID
        let label: String
        let coordinate: CLLocationCoordinate2D
        let createdAt: Date
        let expiresAt: Date

        var isExpired: Bool { Date() > expiresAt }
    }

    struct MeetingPointAnnotation: Identifiable, Sendable {
        let id: UUID
        let label: String
        let coordinate: CLLocationCoordinate2D
        let creatorName: String
        let expiresAt: Date
    }

    struct NavigationInfo: Sendable {
        let friendName: String
        let distance: CLLocationDistance
        let bearing: Double // Degrees from north
        let estimatedWalkTime: TimeInterval // Assuming 5km/h walking speed
        let lastUpdated: Date

        var distanceDisplay: String {
            if distance < 100 {
                return "\(Int(distance))m"
            } else if distance < 1000 {
                return "\(Int(distance / 10) * 10)m"
            } else {
                return String(format: "%.1fkm", distance / 1000)
            }
        }

        var bearingDisplay: String {
            let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            let index = Int((bearing + 22.5) / 45.0) % 8
            return directions[index]
        }

        var walkTimeDisplay: String {
            let minutes = Int(estimatedWalkTime / 60)
            if minutes < 1 { return "< 1 min" }
            if minutes < 60 { return "\(minutes) min" }
            return "\(minutes / 60)h \(minutes % 60)m"
        }
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.festichat", category: "LocationViewModel")
    private let modelContainer: ModelContainer
    private let locationService: LocationService
    nonisolated(unsafe) private var refreshTimer: Timer?

    // MARK: - Constants

    /// "I'm here" beacon default expiration (1 hour).
    private static let beaconExpiration: TimeInterval = 3600

    /// Walking speed assumption for ETA (5 km/h).
    private static let walkingSpeedMPS: Double = 5.0 / 3.6

    /// Refresh interval for friend locations.
    private static let refreshInterval: TimeInterval = 10.0

    // MARK: - Init

    init(modelContainer: ModelContainer, locationService: LocationService) {
        self.modelContainer = modelContainer
        self.locationService = locationService
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Start monitoring friend locations and user position.
    func startMonitoring() {
        isLocationAuthorized = locationService.isAuthorized

        if isLocationAuthorized {
            locationService.startUpdating(accuracy: .friendSharing)
        }

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshFriendLocations()
                self?.updateUserLocation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        Task {
            await refreshFriendLocations()
            updateUserLocation()
        }
    }

    /// Stop monitoring.
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Location Sharing

    /// Toggle global location sharing.
    func toggleLocationSharing() {
        isLocationSharingEnabled.toggle()

        if isLocationSharingEnabled {
            locationService.startUpdating(accuracy: .friendSharing)
        } else {
            locationService.stopUpdating()
        }
    }

    /// Toggle location sharing for a specific friend.
    func toggleSharingWithFriend(friendID: UUID) async {
        let context = ModelContext(modelContainer)
        let idStr = friendID.uuidString
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id.uuidString == idStr })

        do {
            guard let friend = try context.fetch(descriptor).first else { return }
            friend.locationSharingEnabled.toggle()
            try context.save()
        } catch {
            logger.error("Failed to toggle location sharing for friend: \(error.localizedDescription)")
            errorMessage = "Failed to update sharing: \(error.localizedDescription)"
        }
    }

    /// Update location precision for a friend.
    func setFriendPrecision(friendID: UUID, precision: LocationPrecision) async {
        let context = ModelContext(modelContainer)
        let idStr = friendID.uuidString
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id.uuidString == idStr })

        do {
            guard let friend = try context.fetch(descriptor).first else { return }
            friend.locationPrecision = precision
            try context.save()
        } catch {
            logger.error("Failed to set friend precision: \(error.localizedDescription)")
            errorMessage = "Failed to update precision: \(error.localizedDescription)"
        }
    }

    // MARK: - "I'm Here" Beacon

    /// Drop an "I'm here" beacon at the current location.
    func dropBeacon(label: String) async {
        guard let location = locationService.currentLocation else {
            errorMessage = "Location unavailable"
            return
        }

        let beacon = BeaconInfo(
            id: UUID(),
            label: label.isEmpty ? "I'm here" : label,
            coordinate: location.coordinate,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(Self.beaconExpiration)
        )

        activeBeacon = beacon

        // Create a meeting point in SwiftData
        let context = ModelContext(modelContainer)
        let meetingPoint = MeetingPoint(
            coordinates: GeoPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            label: beacon.label,
            expiresAt: beacon.expiresAt
        )
        context.insert(meetingPoint)
        do {
            try context.save()
        } catch {
            logger.error("Failed to save beacon meeting point: \(error.localizedDescription)")
            errorMessage = "Failed to save beacon: \(error.localizedDescription)"
        }

        // Broadcast beacon via mesh (handled by transport layer)
        NotificationCenter.default.post(
            name: .didDropBeacon,
            object: nil,
            userInfo: [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "label": beacon.label,
                "beaconID": beacon.id.uuidString
            ]
        )
    }

    /// Remove the active beacon.
    func removeBeacon() {
        activeBeacon = nil
    }

    // MARK: - Navigation

    /// Select a friend for navigation guidance.
    func navigateToFriend(_ annotation: FriendAnnotation) {
        selectedFriend = annotation
        updateNavigationInfo()
        isFollowingUser = false

        // Center map between user and friend
        if let userLoc = userLocation {
            let centerLat = (userLoc.latitude + annotation.coordinate.latitude) / 2
            let centerLon = (userLoc.longitude + annotation.coordinate.longitude) / 2
            let latSpan = abs(userLoc.latitude - annotation.coordinate.latitude) * 1.5
            let lonSpan = abs(userLoc.longitude - annotation.coordinate.longitude) * 1.5
            mapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(
                    latitudeDelta: max(latSpan, 0.005),
                    longitudeDelta: max(lonSpan, 0.005)
                )
            )
        }
    }

    /// Stop navigation.
    func stopNavigation() {
        selectedFriend = nil
        navigationInfo = nil
        isFollowingUser = true
    }

    /// Center map on user location.
    func centerOnUser() {
        guard let location = userLocation else { return }
        isFollowingUser = true
        mapRegion = MKCoordinateRegion(
            center: location,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )
    }

    // MARK: - Private: Refresh

    private func refreshFriendLocations() async {
        let context = ModelContext(modelContainer)

        let descriptor = FetchDescriptor<FriendLocation>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let locations: [FriendLocation]
        do {
            locations = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch friend locations: \(error.localizedDescription)")
            errorMessage = "Failed to load friend locations: \(error.localizedDescription)"
            return
        }

        // Group by friend, take most recent
        var latestByFriend: [UUID: FriendLocation] = [:]
        for location in locations {
            guard let friend = location.friend else { continue }
            if latestByFriend[friend.id] == nil {
                latestByFriend[friend.id] = location
            }
        }

        friendAnnotations = latestByFriend.compactMap { (friendID, location) -> FriendAnnotation? in
            guard let lat = location.latitude, let lon = location.longitude else { return nil }
            guard let friend = location.friend else { return nil }

            // Build breadcrumb trail
            let crumbs = location.breadcrumbs
                .sorted { $0.timestamp < $1.timestamp }
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

            return FriendAnnotation(
                id: location.id,
                friendID: friendID,
                name: friend.nickname ?? friend.user?.resolvedDisplayName ?? "Unknown",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                precision: location.precisionLevel,
                lastUpdated: location.timestamp,
                geohash: location.geohash,
                areaName: location.areaName,
                breadcrumbs: crumbs
            )
        }

        // Refresh meeting points
        let mpDescriptor = FetchDescriptor<MeetingPoint>()
        do {
            let mps = try context.fetch(mpDescriptor)
            meetingPoints = mps.filter { !$0.isExpired }.map { mp in
                MeetingPointAnnotation(
                    id: mp.id,
                    label: mp.label,
                    coordinate: CLLocationCoordinate2D(
                        latitude: mp.coordinates.latitude,
                        longitude: mp.coordinates.longitude
                    ),
                    creatorName: mp.creator?.resolvedDisplayName ?? "Unknown",
                    expiresAt: mp.expiresAt
                )
            }
        } catch {
            logger.error("Failed to fetch meeting points: \(error.localizedDescription)")
        }

        // Update navigation if active
        if selectedFriend != nil {
            updateNavigationInfo()
        }
    }

    private func updateUserLocation() {
        if let loc = locationService.currentLocation {
            userLocation = loc.coordinate
            if isFollowingUser {
                mapRegion = MKCoordinateRegion(
                    center: loc.coordinate,
                    span: mapRegion.span
                )
            }
        }
    }

    private func updateNavigationInfo() {
        guard let selected = selectedFriend, let userLoc = userLocation else {
            navigationInfo = nil
            return
        }

        let userCL = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
        let friendCL = CLLocation(latitude: selected.coordinate.latitude, longitude: selected.coordinate.longitude)

        let distance = userCL.distance(from: friendCL)
        let bearing = computeBearing(from: userLoc, to: selected.coordinate)
        let walkTime = distance / Self.walkingSpeedMPS

        navigationInfo = NavigationInfo(
            friendName: selected.name,
            distance: distance,
            bearing: bearing,
            estimatedWalkTime: walkTime,
            lastUpdated: selected.lastUpdated
        )
    }

    /// Compute bearing in degrees from north between two coordinates.
    private func computeBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let didDropBeacon = Notification.Name("com.festichat.didDropBeacon")
}
