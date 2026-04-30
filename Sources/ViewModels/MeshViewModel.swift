import Foundation
import SwiftData
import os.log
import BlipProtocol
import BlipMesh
import BlipCrypto

// MARK: - Crowd Scale Mode (UI representation)

enum CrowdScaleDisplay: String, Sendable {
    case gather = "Gather"
    case event = "Event"
    case mega = "Mega"
    case massive = "Massive"

    var peerRange: String {
        switch self {
        case .gather: return "< 500"
        case .event: return "500 - 5K"
        case .mega: return "5K - 25K"
        case .massive: return "25K+"
        }
    }

    var description: String {
        switch self {
        case .gather: return "Full features, all media types"
        case .event: return "Moderate throttle, text + voice"
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

    /// All connected mesh peers with their friend status.
    var nearbyPeers: [NearbyPeer] = []

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
        let hasSignalData: Bool
    }

    /// A connected mesh peer with optional friend status.
    struct NearbyPeer: Identifiable, Sendable {
        let id: UUID
        let peerID: Data
        let username: String?
        let displayName: String?
        let rssi: Int
        let lastSeen: Date
        let isDirectPeer: Bool
        let hasSignalData: Bool
        let friendStatus: FriendStatus?
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

    private let logger = Logger(subsystem: "com.blip", category: "MeshViewModel")
    private let modelContainer: ModelContainer
    private let context: ModelContext
    private let peerStore: PeerStore
    @ObservationIgnored nonisolated(unsafe) private var refreshTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var peerObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var peerStoreObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var transportObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var friendListObservation: NSObjectProtocol?

    // MARK: - Constants

    /// Peer count thresholds for crowd scale detection.
    private static let gatherThreshold = 500
    private static let eventThreshold = 5_000
    private static let megaThreshold = 25_000

    /// Maximum events to keep in the log.
    private static let maxEventLogSize = 100

    private static let nearbyRSSIThreshold = -75
    private static let nearbyRecencyWindow: TimeInterval = 30

    // MARK: - Init

    private let notificationService: NotificationService
    private var previousNearbyFriendIDs: Set<UUID> = []

    init(modelContainer: ModelContainer, peerStore: PeerStore = .shared, notificationService: NotificationService = NotificationService()) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
        self.peerStore = peerStore
        self.notificationService = notificationService
        setupObservers()
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = peerObservation { NotificationCenter.default.removeObserver(obs) }
        if let obs = peerStoreObservation { NotificationCenter.default.removeObserver(obs) }
        if let obs = transportObservation { NotificationCenter.default.removeObserver(obs) }
        if let obs = friendListObservation { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Lifecycle

    /// Start periodic mesh state refresh.
    func startMonitoring() {
        refreshTimer?.invalidate()
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

    /// Pull the latest mesh state from PeerStore (in-memory) + SwiftData (channels/friends).
    func refreshMeshState() async {
        let connected = peerStore.connectedBLEPeers()
        let allTracked = peerStore.allPeers()

        connectedPeerCount = connected.count

        // Calculate average RSSI — only over peers with valid signal data.
        // `PeerInfo.rssi` defaults to `Int.min` (the `noSignalRSSI` sentinel)
        // for connected BLE peers whose first `peripheral.readRSSI()` sample
        // hasn't arrived yet. Summing `Int + Int.min` underflow-traps the
        // process (`EXC_BREAKPOINT 'overflow'`), which is BDEV-438 / Sentry
        // APPLE-IOS-28. Filter on `hasSignalData` first so we average only
        // over real samples and fall back to the existing -100 floor when
        // no peer has reported signal yet.
        let withSignal = connected.filter { $0.hasSignalData }
        if !withSignal.isEmpty {
            let totalRSSI = withSignal.reduce(0) { $0 + $1.rssi }
            averageRSSI = totalRSSI / withSignal.count
        } else {
            averageRSSI = -100
        }

        // Estimate mesh size — only count peers seen in the last 5 minutes
        let recentThreshold = Date().addingTimeInterval(-300)
        let recentPeers = allTracked.filter { $0.lastSeenAt > recentThreshold }
        estimatedMeshSize = recentPeers.count

        // Update crowd scale
        updateCrowdScale(peerEstimate: estimatedMeshSize)

        // Detect bridge node status
        isBridgeNode = connected.count >= 6

        let context = self.context

        // Refresh nearby friends and all peers
        await refreshNearbyFriends(peers: connected, context: context)
        await refreshNearbyPeers(peers: connected, context: context)

        // Refresh location channels
        await refreshLocationChannels(context: context)

        // Update transport state
        updateTransportState()

        // Update health
        isMeshHealthy = connectedPeerCount > 0
    }

    // MARK: - Crowd Scale

    private func updateCrowdScale(peerEstimate: Int) {
        let newScale: CrowdScaleDisplay
        if peerEstimate >= Self.megaThreshold {
            newScale = .massive
        } else if peerEstimate >= Self.eventThreshold {
            newScale = .mega
        } else if peerEstimate >= Self.gatherThreshold {
            newScale = .event
        } else {
            newScale = .gather
        }

        if newScale != crowdScale {
            crowdScale = newScale
            logEvent("Crowd scale changed to \(newScale.rawValue) (~\(peerEstimate) peers)")
        }
    }

    // MARK: - Nearby Friends

    private func refreshNearbyFriends(peers: [PeerInfo], context: ModelContext) async {
        let friends: [Friend]
        do {
            friends = try context.fetch(FetchDescriptor<Friend>())
                .filter { $0.statusRaw == "accepted" }
        } catch {
            logger.error("Failed to fetch friends for nearby refresh: \(error.localizedDescription)")
            errorMessage = "Failed to fetch friends: \(error.localizedDescription)"
            return
        }

        var nearby: [NearbyFriend] = []

        for friend in friends {
            guard let user = friend.user else { continue }

            // Match by noisePublicKey (handles both 32-byte real key and legacy 8-byte PeerID)
            let friendNoiseKey = user.noisePublicKey
            if let peer = peers.first(where: { $0.noisePublicKey == friendNoiseKey }) {
                nearby.append(NearbyFriend(
                    id: friend.id,
                    username: user.username,
                    displayName: user.resolvedDisplayName,
                    rssi: peer.rssi,
                    lastSeen: peer.lastSeenAt,
                    isDirectPeer: peer.hopCount == 1,
                    hasSignalData: peer.hasSignalData
                ))
            }
        }

        nearbyFriends = nearby.sorted { $0.rssi > $1.rssi }

        let currentIDs = Set(nearby.map(\.id))
        let newFriendIDs = currentIDs.subtracting(previousNearbyFriendIDs)
        let now = Date()
        for friend in nearby where
            newFriendIDs.contains(friend.id)
            && friend.isDirectPeer
            && friend.rssi > Self.nearbyRSSIThreshold
            && now.timeIntervalSince(friend.lastSeen) < Self.nearbyRecencyWindow
        {
            notificationService.notifyFriendNearby(
                friendName: friend.displayName,
                friendID: friend.id
            )
        }
        previousNearbyFriendIDs = currentIDs
    }

    // MARK: - Nearby Peers (All)

    private func refreshNearbyPeers(peers: [PeerInfo], context: ModelContext) async {
        // Fetch all friends to determine status
        let friendDescriptor = FetchDescriptor<Friend>()
        let allFriends: [Friend]
        do {
            allFriends = try context.fetch(friendDescriptor)
        } catch {
            logger.error("Failed to fetch friends for peer refresh: \(error.localizedDescription)")
            return
        }

        // Build a lookup: noisePublicKey -> FriendStatus
        var friendStatusByKey: [Data: FriendStatus] = [:]
        for friend in allFriends {
            guard let user = friend.user else { continue }
            friendStatusByKey[user.noisePublicKey] = friend.status
        }

        var allPeers: [NearbyPeer] = []
        for peer in peers {
            let status = friendStatusByKey[peer.noisePublicKey]
            allPeers.append(NearbyPeer(
                id: UUID(),
                peerID: peer.peerID,
                username: peer.username,
                displayName: peer.username,
                rssi: peer.rssi,
                lastSeen: peer.lastSeenAt,
                isDirectPeer: peer.hopCount == 1,
                hasSignalData: peer.hasSignalData,
                friendStatus: status
            ))
        }

        nearbyPeers = allPeers.sorted { $0.rssi > $1.rssi }
    }

    // MARK: - Location Channels

    private func refreshLocationChannels(context: ModelContext) async {
        let channels: [Channel]
        do {
            channels = try context.fetch(FetchDescriptor<Channel>())
                .filter { $0.typeRaw == "locationChannel" || $0.typeRaw == "stageChannel" }
        } catch {
            logger.error("Failed to fetch location channels: \(error.localizedDescription)")
            errorMessage = "Failed to fetch channels: \(error.localizedDescription)"
            return
        }

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
        let context = self.context
        do {
            if let channel = try context.fetch(FetchDescriptor<Channel>())
                .first(where: { $0.id == channelInfo.id }) {
                channel.isAutoJoined = true
                try context.save()
                logEvent("Joined channel: \(channelInfo.name)")
            }
        } catch {
            logger.error("Failed to join location channel: \(error.localizedDescription)")
            errorMessage = "Failed to join channel: \(error.localizedDescription)"
        }
        await refreshMeshState()
    }

    /// Leave a location channel.
    func leaveLocationChannel(_ channelInfo: LocationChannelInfo) async {
        let context = self.context
        do {
            if let channel = try context.fetch(FetchDescriptor<Channel>())
                .first(where: { $0.id == channelInfo.id }) {
                channel.isAutoJoined = false
                try context.save()
                logEvent("Left channel: \(channelInfo.name)")
            }
        } catch {
            logger.error("Failed to leave location channel: \(error.localizedDescription)")
            errorMessage = "Failed to leave channel: \(error.localizedDescription)"
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

        peerStoreObservation = NotificationCenter.default.addObserver(
            forName: .peerStoreDidChange,
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

        friendListObservation = NotificationCenter.default.addObserver(
            forName: .friendListDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshMeshState()
            }
        }
    }
}

// Notification names (.meshPeerStateChanged, .meshTransportStateChanged)
// are defined in BlipMesh/BLEService.swift
