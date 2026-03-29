import Foundation
import SwiftData
import FestiChatProtocol
import FestiChatMesh
import FestiChatCrypto

// MARK: - Crowd Scale Mode (UI representation)

enum CrowdScaleDisplay: String, Sendable {
    case gather = "Gather"
    case festival = "Festival"
    case mega = "Mega"
    case massive = "Massive"

    var peerRange: String {
        switch self {
        case .gather: return "< 500"
        case .festival: return "500 - 5K"
        case .mega: return "5K - 25K"
        case .massive: return "25K+"
        }
    }

    var description: String {
        switch self {
        case .gather: return "Full features, all media types"
        case .festival: return "Moderate throttle, text + voice"
        case .mega: return "Text-first, tight relay"
        case .massive: return "Text-only, aggressive clustering"
        }
    }
}

// MARK: - Mesh View Model

/// Observes BLEService and PeerManager to present mesh network state to the UI.
///
/// Publishes:
/// - Connected peer count and crowd scale mode
/// - Nearby friends detected on mesh
/// - Location channels available by proximity
/// - Transport state (BLE, WebSocket, offline)
/// - Mesh health indicators
@MainActor
@Observable
final class MeshViewModel {

    // MARK: - Published State

    /// Number of directly connected BLE peers.
    var connectedPeerCount: Int = 0

    /// Estimated total peers in the mesh (direct + announced neighbors).
    var estimatedMeshSize: Int = 0

    /// Current crowd scale mode.
    var crowdScale: CrowdScaleDisplay = .gather

    /// List of nearby friends detected on the mesh.
    var nearbyFriends: [NearbyFriend] = []

    /// Available location channels based on proximity.
    var locationChannels: [LocationChannelInfo] = []

    /// Current transport state description.
    var transportState: String = "Connecting..."

    /// Whether BLE is currently active and scanning.
    var isBLEActive = false

    /// Whether WebSocket fallback is connected.
    var isWebSocketConnected = false

    /// Whether the mesh is in a healthy state (has peers, can relay).
    var isMeshHealthy = false

    /// Average RSSI of connected peers (for signal strength indicator).
    var averageRSSI: Int = -100

    /// Recent mesh event log for diagnostics.
    var recentEvents: [MeshEvent] = []

    /// Battery tier of this device.
    var localBatteryTier: String = "Balanced"

    /// Whether the device is acting as a bridge node.
    var isBridgeNode = false

    /// Error message, if any.
    var errorMessage: String?

    // MARK: - Supporting Types

    struct NearbyFriend: Identifiable, Sendable {
        let id: UUID
        let username: String
        let displayName: String
        let rssi: Int
        let lastSeen: Date
        let isDirectPeer: Bool
    }

    struct LocationChannelInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let geohash: String
        let peerCount: Int
        let isJoined: Bool
    }

    struct MeshEvent: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let description: String
        let isError: Bool

        init(description: String, isError: Bool = false) {
            self.id = UUID()
            self.timestamp = Date()
            self.description = description
            self.isError = isError
        }
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var peerObservation: NSObjectProtocol?
    nonisolated(unsafe) private var transportObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Peer count thresholds for crowd scale detection.
    private static let gatherThreshold = 500
    private static let festivalThreshold = 5_000
    private static let megaThreshold = 25_000

    /// Maximum events to keep in the log.
    private static let maxEventLogSize = 100

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        setupObservers()
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = peerObservation { NotificationCenter.default.removeObserver(obs) }
        if let obs = transportObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Lifecycle

    /// Start periodic mesh state refresh.
    func startMonitoring() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshMeshState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        Task { await refreshMeshState() }
    }

    /// Stop monitoring.
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - State Refresh

    /// Pull the latest mesh state from SwiftData.
    func refreshMeshState() async {
        let context = ModelContext(modelContainer)

        do {
            // Fetch connected peers
            let connectedPredicate = #Predicate<MeshPeer> { $0.connectionStateRaw == "connected" }
            let peerDescriptor = FetchDescriptor<MeshPeer>(predicate: connectedPredicate)
            let connectedPeers = try context.fetch(peerDescriptor)

            connectedPeerCount = connectedPeers.count

            // Calculate average RSSI
            if !connectedPeers.isEmpty {
                let totalRSSI = connectedPeers.reduce(0) { $0 + $1.rssi }
                averageRSSI = totalRSSI / connectedPeers.count
            } else {
                averageRSSI = -100
            }

            // Estimate mesh size (direct peers + their announced neighbors)
            let allPeersDescriptor = FetchDescriptor<MeshPeer>()
            let allPeers = try context.fetch(allPeersDescriptor)
            estimatedMeshSize = allPeers.count

            // Update crowd scale
            updateCrowdScale(peerEstimate: estimatedMeshSize)

            // Detect bridge node status
            isBridgeNode = connectedPeers.count >= 6

            // Refresh nearby friends
            await refreshNearbyFriends(peers: connectedPeers, context: context)

            // Refresh location channels
            await refreshLocationChannels(context: context)

            // Update transport state
            updateTransportState()

            // Update health
            isMeshHealthy = connectedPeerCount > 0

        } catch {
            errorMessage = "Mesh refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Crowd Scale

    private func updateCrowdScale(peerEstimate: Int) {
        let newScale: CrowdScaleDisplay
        if peerEstimate >= Self.megaThreshold {
            newScale = .massive
        } else if peerEstimate >= Self.festivalThreshold {
            newScale = .mega
        } else if peerEstimate >= Self.gatherThreshold {
            newScale = .festival
        } else {
            newScale = .gather
        }

        if newScale != crowdScale {
            crowdScale = newScale
            logEvent("Crowd scale changed to \(newScale.rawValue) (~\(peerEstimate) peers)")
        }
    }

    // MARK: - Nearby Friends

    private func refreshNearbyFriends(peers: [MeshPeer], context: ModelContext) async {
        let friendDescriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.statusRaw == "accepted" })
        guard let friends = try? context.fetch(friendDescriptor) else { return }

        var nearby: [NearbyFriend] = []

        for friend in friends {
            guard let user = friend.user else { continue }
            let friendPeerData = PeerID(noisePublicKey: user.noisePublicKey).bytes

            if let peer = peers.first(where: { $0.peerID == friendPeerData }) {
                nearby.append(NearbyFriend(
                    id: friend.id,
                    username: user.username,
                    displayName: user.resolvedDisplayName,
                    rssi: peer.rssi,
                    lastSeen: peer.lastSeenAt,
                    isDirectPeer: peer.isDirectPeer
                ))
            }
        }

        nearbyFriends = nearby.sorted { $0.rssi > $1.rssi }
    }

    // MARK: - Location Channels

    private func refreshLocationChannels(context: ModelContext) async {
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
            $0.typeRaw == "locationChannel" || $0.typeRaw == "stageChannel"
        })
        guard let channels = try? context.fetch(descriptor) else { return }

        locationChannels = channels.map { channel in
            LocationChannelInfo(
                id: channel.id,
                name: channel.name ?? "Nearby",
                geohash: channel.geohash ?? "",
                peerCount: channel.memberships.count,
                isJoined: channel.isAutoJoined
            )
        }
    }

    // MARK: - Transport State

    private func updateTransportState() {
        if isBLEActive && connectedPeerCount > 0 {
            transportState = "Mesh: \(connectedPeerCount) peers"
        } else if isBLEActive {
            transportState = "Scanning for peers..."
        } else if isWebSocketConnected {
            transportState = "Internet relay"
        } else {
            transportState = "Offline"
        }
    }

    // MARK: - Event Log

    func logEvent(_ description: String, isError: Bool = false) {
        let event = MeshEvent(description: description, isError: isError)
        recentEvents.insert(event, at: 0)
        if recentEvents.count > Self.maxEventLogSize {
            recentEvents.removeLast()
        }
    }

    /// Clear the event log.
    func clearEventLog() {
        recentEvents.removeAll()
    }

    // MARK: - Actions

    /// Force a mesh scan refresh.
    func forceRefresh() async {
        logEvent("Manual mesh refresh triggered")
        await refreshMeshState()
    }

    /// Request to join a location channel.
    func joinLocationChannel(_ channelInfo: LocationChannelInfo) async {
        let context = ModelContext(modelContainer)
        let idStr = channelInfo.id.uuidString
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id.uuidString == idStr })
        if let channel = try? context.fetch(descriptor).first {
            channel.isAutoJoined = true
            try? context.save()
            logEvent("Joined channel: \(channelInfo.name)")
        }
        await refreshMeshState()
    }

    /// Leave a location channel.
    func leaveLocationChannel(_ channelInfo: LocationChannelInfo) async {
        let context = ModelContext(modelContainer)
        let idStr = channelInfo.id.uuidString
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id.uuidString == idStr })
        if let channel = try? context.fetch(descriptor).first {
            channel.isAutoJoined = false
            try? context.save()
            logEvent("Left channel: \(channelInfo.name)")
        }
        await refreshMeshState()
    }

    // MARK: - Private: Observers

    private func setupObservers() {
        peerObservation = NotificationCenter.default.addObserver(
            forName: .meshPeerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshMeshState()
            }
        }

        transportObservation = NotificationCenter.default.addObserver(
            forName: .meshTransportStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                if let isActive = notification.userInfo?["bleActive"] as? Bool {
                    self?.isBLEActive = isActive
                }
                if let isWS = notification.userInfo?["wsConnected"] as? Bool {
                    self?.isWebSocketConnected = isWS
                }
                self?.updateTransportState()
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let meshPeerStateChanged = Notification.Name("com.festichat.meshPeerStateChanged")
    static let meshTransportStateChanged = Notification.Name("com.festichat.meshTransportStateChanged")
}
