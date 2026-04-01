import Foundation
import CoreLocation
import SwiftData
import os

// MARK: - Location Service Error

enum LocationServiceError: Error, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case locationUnavailable
    case geofenceLimit
    case monitoringFailed(String)
}

// MARK: - Location Accuracy Level

enum LocationAccuracyLevel: Sendable {
    /// Precise GPS for SOS (best accuracy available).
    case sos
    /// Standard GPS for friend sharing.
    case friendSharing
    /// Reduced accuracy for general proximity.
    case proximity
    /// Geohash-only for channel assignment.
    case geohash
}

// MARK: - Location Service Delegate

protocol LocationServiceDelegate: AnyObject, Sendable {
    func locationService(_ service: LocationService, didUpdateLocation location: CLLocation)
    func locationService(_ service: LocationService, didUpdateGeohash geohash: String)
    func locationService(_ service: LocationService, didEnterFestivalRegion festivalID: UUID)
    func locationService(_ service: LocationService, didExitFestivalRegion festivalID: UUID)
    func locationService(_ service: LocationService, didChangeAuthorization status: CLAuthorizationStatus)
    func locationService(_ service: LocationService, didFailWithError error: Error)
}

// MARK: - Location Service

/// CLLocationManager wrapper providing GPS for SOS, friend sharing, geofencing, and geohash computation.
///
/// Features:
/// - Precise GPS for SOS alerts
/// - Configurable-precision friend location sharing
/// - Festival geofence monitoring (enter/exit regions)
/// - Geohash computation for location channel assignment
/// - 15-minute periodic background location checks
/// - Battery-aware accuracy adjustments
final class LocationService: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private let locationManager: CLLocationManager
    weak var delegate: (any LocationServiceDelegate)?

    /// Last known location.
    private(set) var currentLocation: CLLocation?

    /// Current computed geohash (precision 7 = ~150m).
    private(set) var currentGeohash: String?

    /// Current authorization status.
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Whether location updates are actively running.
    private(set) var isUpdating = false

    /// Currently monitored festival region identifiers.
    private var monitoredRegions: [String: UUID] = [:]

    /// Current accuracy mode.
    private var currentAccuracyLevel: LocationAccuracyLevel = .proximity

    // MARK: - Constants

    /// Geohash precision for location channels (~150m).
    private static let channelGeohashPrecision = 7

    /// Geohash precision for friend sharing (~1.2km fuzzy).
    private static let fuzzyGeohashPrecision = 5

    /// Periodic update interval for background checks.
    private static let periodicInterval: TimeInterval = 900 // 15 minutes

    /// Maximum monitored regions (iOS limit is 20, reserve some).
    private static let maxMonitoredRegions = 15

    // MARK: - Init

    override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
        locationManager.pausesLocationUpdatesAutomatically = false
        // Only enable background location if the "location" background mode is declared
        // in Info.plist. Without it, setting allowsBackgroundLocationUpdates = true
        // crashes with NSInternalInconsistencyException.
        let bgModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if bgModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
    }

    // MARK: - Authorization

    /// Request location authorization (when-in-use first, then always).
    func requestAuthorization() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Check if location services are available and authorized.
    var isAuthorized: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Check if background location is available.
    var hasBackgroundAccess: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    // MARK: - Location Updates

    /// Start location updates with the specified accuracy level.
    func startUpdating(accuracy: LocationAccuracyLevel = .proximity) {
        guard isAuthorized else { return }

        currentAccuracyLevel = accuracy
        configureAccuracy(accuracy)
        locationManager.startUpdatingLocation()
        isUpdating = true
    }

    /// Stop location updates.
    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        isUpdating = false
    }

    /// Request a single high-accuracy location for SOS.
    ///
    /// Returns the best location obtained within the timeout.
    func requestSOSLocation() async throws -> CLLocation {
        guard isAuthorized else {
            throw LocationServiceError.authorizationDenied
        }

        configureAccuracy(.sos)
        locationManager.startUpdatingLocation()

        return try await withCheckedThrowingContinuation { continuation in
            // Atomic flag to ensure only one resume (BDEV-96)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            var observation: NSObjectProtocol?

            observation = NotificationCenter.default.addObserver(
                forName: .locationServiceDidGetSOSFix,
                object: self,
                queue: .main
            ) { notification in
                if let obs = observation {
                    NotificationCenter.default.removeObserver(obs)
                }
                if let location = notification.userInfo?["location"] as? CLLocation {
                    resumed.withLock { alreadyResumed in
                        guard !alreadyResumed else { return }
                        alreadyResumed = true
                        continuation.resume(returning: location)
                    }
                } else {
                    resumed.withLock { alreadyResumed in
                        guard !alreadyResumed else { return }
                        alreadyResumed = true
                        continuation.resume(throwing: LocationServiceError.locationUnavailable)
                    }
                }
            }

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if let obs = observation {
                    NotificationCenter.default.removeObserver(obs)
                }
                resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return }
                    alreadyResumed = true
                    if let location = self?.currentLocation {
                        continuation.resume(returning: location)
                    } else {
                        continuation.resume(throwing: LocationServiceError.locationUnavailable)
                    }
                }
            }
        }
    }

    /// Start periodic background location checks (every 15 minutes).
    func startPeriodicChecks() {
        guard hasBackgroundAccess else { return }
        locationManager.startMonitoringSignificantLocationChanges()
    }

    /// Stop periodic background location checks.
    func stopPeriodicChecks() {
        locationManager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: - Geofencing

    /// Add a geofence for a festival location.
    func monitorFestival(id: UUID, center: CLLocationCoordinate2D, radius: CLLocationDistance) throws {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            throw LocationServiceError.monitoringFailed("Region monitoring not available")
        }

        guard monitoredRegions.count < Self.maxMonitoredRegions else {
            throw LocationServiceError.geofenceLimit
        }

        let regionID = "festival_\(id.uuidString)"
        let region = CLCircularRegion(
            center: center,
            radius: min(radius, locationManager.maximumRegionMonitoringDistance),
            identifier: regionID
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true

        monitoredRegions[regionID] = id
        locationManager.startMonitoring(for: region)
    }

    /// Remove festival geofence monitoring.
    func stopMonitoringFestival(id: UUID) {
        let regionID = "festival_\(id.uuidString)"
        monitoredRegions.removeValue(forKey: regionID)

        for region in locationManager.monitoredRegions {
            if region.identifier == regionID {
                locationManager.stopMonitoring(for: region)
                break
            }
        }
    }

    /// Stop monitoring all festival geofences.
    func stopMonitoringAllFestivals() {
        for region in locationManager.monitoredRegions {
            if region.identifier.hasPrefix("festival_") {
                locationManager.stopMonitoring(for: region)
            }
        }
        monitoredRegions.removeAll()
    }

    // MARK: - Geohash Computation

    /// Compute a geohash from a coordinate at the specified precision.
    ///
    /// Default precision 7 gives ~150m accuracy, suitable for location channels.
    func computeGeohash(latitude: Double, longitude: Double, precision: Int? = nil) -> String {
        let targetPrecision = precision ?? Self.channelGeohashPrecision
        return Geohash.encode(latitude: latitude, longitude: longitude, precision: targetPrecision)
    }

    /// Compute a fuzzy geohash (precision 5, ~1.2km) for approximate friend locations.
    func computeFuzzyGeohash(latitude: Double, longitude: Double) -> String {
        return Geohash.encode(latitude: latitude, longitude: longitude, precision: Self.fuzzyGeohashPrecision)
    }

    /// Get the current location as a GeoPoint.
    var currentGeoPoint: GeoPoint? {
        guard let loc = currentLocation else { return nil }
        return GeoPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
    }

    /// Compute the distance in meters between two GeoPoints.
    func distance(from point1: GeoPoint, to point2: GeoPoint) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: point1.latitude, longitude: point1.longitude)
        let loc2 = CLLocation(latitude: point2.latitude, longitude: point2.longitude)
        return loc1.distance(from: loc2)
    }

    // MARK: - Private: Accuracy Configuration

    private func configureAccuracy(_ level: LocationAccuracyLevel) {
        switch level {
        case .sos:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
        case .friendSharing:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
        case .proximity:
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 50
        case .geohash:
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 100
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Filter out stale or inaccurate locations
        let age = -location.timestamp.timeIntervalSinceNow
        guard age < 30, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 500 else {
            return
        }

        currentLocation = location

        // Compute geohash
        let newGeohash = computeGeohash(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let geohashChanged = newGeohash != currentGeohash
        currentGeohash = newGeohash

        // Notify delegate
        delegate?.locationService(self, didUpdateLocation: location)

        if geohashChanged {
            delegate?.locationService(self, didUpdateGeohash: newGeohash)
        }

        // Post SOS fix notification if in SOS mode
        if currentAccuracyLevel == .sos && location.horizontalAccuracy <= 20 {
            NotificationCenter.default.post(
                name: .locationServiceDidGetSOSFix,
                object: self,
                userInfo: ["location": location]
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        delegate?.locationService(self, didChangeAuthorization: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        delegate?.locationService(self, didFailWithError: error)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if let festivalID = monitoredRegions[region.identifier] {
            delegate?.locationService(self, didEnterFestivalRegion: festivalID)
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if let festivalID = monitoredRegions[region.identifier] {
            delegate?.locationService(self, didExitFestivalRegion: festivalID)
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        delegate?.locationService(self, didFailWithError: error)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let locationServiceDidGetSOSFix = Notification.Name("com.blip.locationServiceDidGetSOSFix")
}

// MARK: - Geohash Encoder

/// Pure Swift Geohash encoder implementing the standard Base32 geohash algorithm.
enum Geohash {

    private static let base32Alphabet: [Character] = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Encode a latitude/longitude pair to a geohash string.
    ///
    /// - Parameters:
    ///   - latitude: Latitude in degrees (-90 to 90).
    ///   - longitude: Longitude in degrees (-180 to 180).
    ///   - precision: Number of characters in the resulting geohash (1-12).
    /// - Returns: Geohash string of the requested precision.
    static func encode(latitude: Double, longitude: Double, precision: Int) -> String {
        let clampedPrecision = max(1, min(precision, 12))

        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bits = 0
        var currentChar: UInt8 = 0
        var isLon = true

        while hash.count < clampedPrecision {
            if isLon {
                let mid = (lonRange.0 + lonRange.1) / 2.0
                if longitude >= mid {
                    currentChar = (currentChar << 1) | 1
                    lonRange.0 = mid
                } else {
                    currentChar = currentChar << 1
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2.0
                if latitude >= mid {
                    currentChar = (currentChar << 1) | 1
                    latRange.0 = mid
                } else {
                    currentChar = currentChar << 1
                    latRange.1 = mid
                }
            }
            isLon.toggle()
            bits += 1

            if bits == 5 {
                hash.append(base32Alphabet[Int(currentChar)])
                bits = 0
                currentChar = 0
            }
        }

        return hash
    }

    /// Decode a geohash string back to a (latitude, longitude) center point.
    static func decode(_ hash: String) -> (latitude: Double, longitude: Double)? {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isLon = true

        for char in hash.lowercased() {
            guard let idx = base32Alphabet.firstIndex(of: char) else { return nil }
            let value = UInt8(idx)

            for bit in stride(from: 4, through: 0, by: -1) {
                let mask = UInt8(1 << bit)
                if isLon {
                    let mid = (lonRange.0 + lonRange.1) / 2.0
                    if value & mask != 0 {
                        lonRange.0 = mid
                    } else {
                        lonRange.1 = mid
                    }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2.0
                    if value & mask != 0 {
                        latRange.0 = mid
                    } else {
                        latRange.1 = mid
                    }
                }
                isLon.toggle()
            }
        }

        let latitude = (latRange.0 + latRange.1) / 2.0
        let longitude = (lonRange.0 + lonRange.1) / 2.0
        return (latitude, longitude)
    }

    /// Compute all 8 neighboring geohashes for a given geohash.
    static func neighbors(of hash: String) -> [String] {
        guard let center = decode(hash) else { return [] }
        let precision = hash.count

        // Estimate cell size based on precision
        let latDelta: Double
        let lonDelta: Double
        switch precision {
        case 1: latDelta = 22.5; lonDelta = 45.0
        case 2: latDelta = 2.8; lonDelta = 5.6
        case 3: latDelta = 0.7; lonDelta = 0.7
        case 4: latDelta = 0.087; lonDelta = 0.18
        case 5: latDelta = 0.022; lonDelta = 0.022
        case 6: latDelta = 0.0027; lonDelta = 0.0055
        case 7: latDelta = 0.00068; lonDelta = 0.00068
        default: latDelta = 0.000086; lonDelta = 0.00017
        }

        let offsets: [(Double, Double)] = [
            (-latDelta, -lonDelta), (-latDelta, 0), (-latDelta, lonDelta),
            (0, -lonDelta), (0, lonDelta),
            (latDelta, -lonDelta), (latDelta, 0), (latDelta, lonDelta)
        ]

        return offsets.map { offset in
            encode(
                latitude: center.latitude + offset.0,
                longitude: center.longitude + offset.1,
                precision: precision
            )
        }
    }
}
