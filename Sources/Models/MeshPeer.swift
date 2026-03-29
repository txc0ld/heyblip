import Foundation
import SwiftData

// MARK: - Enums

enum PeerConnectionState: String, Codable, CaseIterable {
    case discovered
    case connecting
    case connected
    case disconnected
}

enum BatteryTier: String, Codable, CaseIterable {
    case performance
    case balanced
    case powerSaver
    case ultraLow
}

// MARK: - Model

@Model
final class MeshPeer {
    @Attribute(.unique)
    var id: UUID

    var peerID: Data
    var noisePublicKey: Data
    var signingPublicKey: Data
    var username: String?
    var rssi: Int
    var connectionStateRaw: String
    var lastSeenAt: Date
    var hopCount: Int
    var isRelaying: Bool
    var batteryTierRaw: String

    // MARK: - Computed Properties

    var connectionState: PeerConnectionState {
        get { PeerConnectionState(rawValue: connectionStateRaw) ?? .disconnected }
        set { connectionStateRaw = newValue.rawValue }
    }

    var batteryTier: BatteryTier {
        get { BatteryTier(rawValue: batteryTierRaw) ?? .balanced }
        set { batteryTierRaw = newValue.rawValue }
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    var isDirectPeer: Bool {
        hopCount == 1
    }

    /// Returns true if this peer hasn't been seen in over 24 hours (stale cleanup threshold).
    var isStale: Bool {
        Date().timeIntervalSince(lastSeenAt) > 86_400
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        peerID: Data,
        noisePublicKey: Data,
        signingPublicKey: Data,
        username: String? = nil,
        rssi: Int = -100,
        connectionState: PeerConnectionState = .discovered,
        lastSeenAt: Date = Date(),
        hopCount: Int = 0,
        isRelaying: Bool = false,
        batteryTier: BatteryTier = .balanced
    ) {
        self.id = id
        self.peerID = peerID
        self.noisePublicKey = noisePublicKey
        self.signingPublicKey = signingPublicKey
        self.username = username
        self.rssi = rssi
        self.connectionStateRaw = connectionState.rawValue
        self.lastSeenAt = lastSeenAt
        self.hopCount = hopCount
        self.isRelaying = isRelaying
        self.batteryTierRaw = batteryTier.rawValue
    }
}
