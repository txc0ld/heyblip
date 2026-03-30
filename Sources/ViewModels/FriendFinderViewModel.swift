import Foundation
import CoreLocation
import SwiftUI
import CryptoKit
import BlipProtocol
import BlipMesh
import BlipCrypto
import os.log

/// Bridges real mesh location data to FriendFinderMapView.
///
/// Listens for `.didReceiveLocationPacket` notifications from MessageService,
/// deserializes LocationPayloads, and publishes live [FriendMapPin] state.
/// Also handles broadcasting the user's own location and "I'm Here" beacons.
@MainActor
@Observable
final class FriendFinderViewModel {

    // MARK: - Published State

    /// Live friend locations for the map.
    var friends: [FriendMapPin] = []

    /// Active beacons (user's + received).
    var beacons: [BeaconPin] = []

    /// User's current location.
    var userLocation: CLLocationCoordinate2D?

    /// Whether the user is actively sharing their location.
    var isSharingLocation = false

    // MARK: - Dependencies

    private let locationService: LocationService
    private let logger = Logger(subsystem: "com.blip", category: "FriendFinder")

    /// Tracked peer locations: PeerID hex → most recent location data.
    private var peerLocations: [String: PeerLocationEntry] = [:]

    nonisolated(unsafe) private var locationObservation: NSObjectProtocol?
    nonisolated(unsafe) private var beaconObservation: NSObjectProtocol?
    nonisolated(unsafe) private var cleanupTimer: Timer?

    private struct PeerLocationEntry {
        let peerID: PeerID
        let payload: LocationPayload
        let receivedAt: Date
    }

    // MARK: - Init

    init(locationService: LocationService = LocationService()) {
        self.locationService = locationService
        setupObservers()
        startCleanupTimer()
    }

    deinit {
        if let obs = locationObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = beaconObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        cleanupTimer?.invalidate()
    }

    // MARK: - Observers

    private func setupObservers() {
        locationObservation = NotificationCenter.default.addObserver(
            forName: .didReceiveLocationPacket,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let packet = notification.userInfo?["packet"] as? Packet,
                  let peerID = notification.userInfo?["peerID"] as? PeerID else { return }

            Task { @MainActor in
                self?.handleLocationPacket(packet, from: peerID)
            }
        }
    }

    // MARK: - Location Packet Handling

    private func handleLocationPacket(_ packet: Packet, from peerID: PeerID) {
        guard let payload = LocationPayload.deserialize(from: packet.payload) else {
            logger.warning("Failed to deserialize location payload from \(peerID)")
            return
        }

        let key = peerID.description

        if payload.isBeacon {
            handleBeacon(payload, from: peerID)
            return
        }

        // Update or insert peer location.
        peerLocations[key] = PeerLocationEntry(
            peerID: peerID,
            payload: payload,
            receivedAt: Date()
        )

        rebuildFriendPins()
    }

    private func handleBeacon(_ payload: LocationPayload, from peerID: PeerID) {
        let beacon = BeaconPin(
            id: UUID(),
            label: "I'm here!",
            coordinate: CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude),
            createdBy: peerID.description,
            expiresAt: Date().addingTimeInterval(LocationPayload.beaconTTL)
        )

        // Replace existing beacon from same peer or append.
        beacons.removeAll { $0.createdBy == peerID.description }
        beacons.append(beacon)
    }

    // MARK: - Pin Building

    private func rebuildFriendPins() {
        let userCoord = userLocation

        friends = peerLocations.values.map { entry in
            let coord = CLLocationCoordinate2D(
                latitude: entry.payload.latitude,
                longitude: entry.payload.longitude
            )
            let accuracy = Double(entry.payload.accuracy)
            let distance: Double? = userCoord.map { user in
                CLLocation(latitude: user.latitude, longitude: user.longitude)
                    .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            }

            let precision: LocationPinPrecision
            if accuracy < 20 {
                precision = .precise
            } else if accuracy < 100 {
                precision = .fuzzy
            } else {
                precision = .off
            }

            return FriendMapPin(
                id: stableUUID(for: entry.peerID),
                displayName: String(entry.peerID.description.prefix(8)),
                coordinate: coord,
                precision: precision,
                color: .blue,
                lastUpdated: entry.receivedAt,
                accuracyMeters: accuracy,
                distanceFromUser: distance,
                isOutOfRange: entry.payload.age > LocationPayload.updateInterval * 2
            )
        }
    }

    // MARK: - Stale Cleanup

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStalePeers()
            }
        }
    }

    private func cleanupStalePeers() {
        let staleThreshold = LocationPayload.updateInterval * 2 // 60s
        let now = Date()

        let before = peerLocations.count
        peerLocations = peerLocations.filter { _, entry in
            now.timeIntervalSince(entry.receivedAt) < staleThreshold
        }

        // Clean expired beacons.
        beacons.removeAll { $0.expiresAt < now }

        if peerLocations.count != before {
            rebuildFriendPins()
        }
    }

    // MARK: - Broadcast Own Location

    /// Broadcast user's location over the mesh. Called when sharing is enabled.
    func broadcastLocation() {
        guard isSharingLocation,
              let location = locationService.currentLocation else { return }

        let payload = LocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: Float(location.horizontalAccuracy)
        )

        let data = payload.serialize()
        NotificationCenter.default.post(
            name: .shouldBroadcastPacket,
            object: nil,
            userInfo: ["data": buildLocationPacketData(payload: data, type: .locationShare)]
        )
    }

    /// Drop an "I'm Here" beacon at the user's current location.
    func dropBeacon() {
        guard let location = locationService.currentLocation else { return }

        let payload = LocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: Float(location.horizontalAccuracy),
            isBeacon: true
        )

        let data = payload.serialize()
        NotificationCenter.default.post(
            name: .shouldBroadcastPacket,
            object: nil,
            userInfo: ["data": buildLocationPacketData(payload: data, type: .iAmHereBeacon)]
        )

        // Add to local beacons too.
        beacons.append(BeaconPin(
            id: UUID(),
            label: "I'm here!",
            coordinate: location.coordinate,
            createdBy: "You",
            expiresAt: Date().addingTimeInterval(LocationPayload.beaconTTL)
        ))
    }

    // MARK: - Helpers

    private func buildLocationPacketData(payload: Data, type: BlipProtocol.MessageType) -> Data {
        guard let identity = try? KeyManager.shared.loadIdentity() else {
            logger.error("No identity for location broadcast")
            return Data()
        }

        let packet = Packet(
            type: type,
            ttl: 3,
            timestamp: Packet.currentTimestamp(),
            flags: PacketFlags(),
            senderID: identity.peerID,
            payload: payload
        )

        do {
            return try PacketSerializer.encode(packet)
        } catch {
            logger.error("Failed to encode location packet: \(error.localizedDescription)")
            return Data()
        }
    }

    /// Update user's own coordinate from LocationService.
    func updateUserLocation(_ location: CLLocation) {
        userLocation = location.coordinate
    }

    private func stableUUID(for peerID: PeerID) -> UUID {
        let digest = SHA256.hash(data: peerID.bytes)
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// Notification names (.didReceiveLocationPacket, .didReceivePTTAudio)
// are defined in MessageService.swift
