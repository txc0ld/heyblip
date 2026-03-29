import Foundation
import BlipProtocol
import os.log

// MARK: - Peripheral state

/// Tracks the state of a discovered peer (spec Section 5.4).
public struct PeripheralState: Sendable {
    /// The BLE peripheral's UUID (from CoreBluetooth).
    public let peripheralUUID: UUID

    /// The Blip PeerID derived from the peer's Noise public key.
    public var peerID: PeerID

    /// Current RSSI reading.
    public var rssi: Int

    /// When this peer was first seen.
    public let firstSeen: Date

    /// When this peer was last heard from.
    public var lastSeen: Date

    /// Whether this peer is connected (vs. just discovered).
    public var isConnected: Bool

    /// The cluster ID this peer belongs to (set by ClusterManager).
    public var clusterID: UUID?

    /// Whether this peer is a bridge node (connected to 2+ clusters).
    public var isBridge: Bool

    /// The peer's announced neighbor list (peer IDs of its direct connections).
    public var neighbors: [PeerID]

    /// Connection stability: how many consecutive evaluation cycles this peer has been connected.
    public var stabilityScore: Int

    public init(
        peripheralUUID: UUID,
        peerID: PeerID,
        rssi: Int,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        clusterID: UUID? = nil,
        isBridge: Bool = false,
        neighbors: [PeerID] = [],
        stabilityScore: Int = 0
    ) {
        self.peripheralUUID = peripheralUUID
        self.peerID = peerID
        self.rssi = rssi
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.clusterID = clusterID
        self.isBridge = isBridge
        self.neighbors = neighbors
        self.stabilityScore = stabilityScore
    }
}

// MARK: - Peer role

/// Role-based connection limit.
public enum PeerRole: Sendable {
    case normal
    case bridge
    case medical

    public var maxConnections: Int {
        switch self {
        case .normal:  return BLEConstants.maxCentralConnectionsNormal
        case .bridge:  return BLEConstants.maxCentralConnectionsBridge
        case .medical: return BLEConstants.maxCentralConnectionsMedical
        }
    }
}

// MARK: - PeerManager

/// Manages the peer table and connection selection for the mesh network (spec Section 5.3-5.4).
///
/// Tracks discovered and connected peers, scores them for connection priority,
/// and periodically evaluates whether to swap connections. Uses a 20% hysteresis
/// threshold to prevent connection churn.
public final class PeerManager: @unchecked Sendable {

    // MARK: - Properties

    /// All known peers indexed by PeerID.
    private var peers: [PeerID: PeripheralState] = [:]

    /// Bidirectional mapping: peripheral UUID <-> PeerID.
    private var uuidToPeerID: [UUID: PeerID] = [:]

    /// The local device's role (affects connection limits).
    public var role: PeerRole = .normal

    /// Currently connected peer IDs.
    public var connectedPeerIDs: [PeerID] {
        lock.withLock {
            peers.values.filter(\.isConnected).map(\.peerID)
        }
    }

    /// Total number of unique peers seen (connected + discovered).
    public var totalPeerCount: Int {
        lock.withLock { peers.count }
    }

    /// All known peers (snapshot).
    public var allPeers: [PeripheralState] {
        lock.withLock { Array(peers.values) }
    }

    // MARK: - Concurrency

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "PeerManager")
    private var evaluationTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blip.peerManager", qos: .utility)

    /// Callback invoked when the manager recommends disconnecting a peer to make room.
    public var onShouldDisconnect: ((PeerID) -> Void)?

    /// Callback invoked when the manager recommends connecting to a discovered peer.
    public var onShouldConnect: ((UUID) -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - Peer lifecycle

    /// Register a newly discovered peer.
    public func addDiscoveredPeer(
        peripheralUUID: UUID,
        peerID: PeerID,
        rssi: Int
    ) {
        lock.withLock {
            if var existing = peers[peerID] {
                existing.rssi = rssi
                existing.lastSeen = Date()
                peers[peerID] = existing
            } else {
                let state = PeripheralState(
                    peripheralUUID: peripheralUUID,
                    peerID: peerID,
                    rssi: rssi
                )
                peers[peerID] = state
                uuidToPeerID[peripheralUUID] = peerID
            }
        }
    }

    /// Mark a peer as connected.
    public func markConnected(peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.isConnected = true
            peers[peerID]?.lastSeen = Date()
        }
    }

    /// Mark a peer as disconnected.
    public func markDisconnected(peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.isConnected = false
            peers[peerID]?.stabilityScore = 0
        }
    }

    /// Update a peer's RSSI.
    public func updateRSSI(_ rssi: Int, for peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.rssi = rssi
            peers[peerID]?.lastSeen = Date()
        }
    }

    /// Update a peer's neighbor list (from announcement packet).
    public func updateNeighbors(_ neighbors: [PeerID], for peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.neighbors = neighbors
        }
    }

    /// Update a peer's bridge status.
    public func updateBridgeStatus(_ isBridge: Bool, for peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.isBridge = isBridge
        }
    }

    /// Update a peer's cluster assignment.
    public func updateCluster(_ clusterID: UUID?, for peerID: PeerID) {
        lock.withLock {
            peers[peerID]?.clusterID = clusterID
        }
    }

    /// Remove a peer entirely (e.g., received leave packet).
    public func removePeer(_ peerID: PeerID) {
        lock.withLock {
            if let state = peers.removeValue(forKey: peerID) {
                uuidToPeerID.removeValue(forKey: state.peripheralUUID)
            }
        }
    }

    /// Look up a peer by PeerID.
    public func peer(for peerID: PeerID) -> PeripheralState? {
        lock.withLock { peers[peerID] }
    }

    /// Look up a peer by peripheral UUID.
    public func peer(forPeripheralUUID uuid: UUID) -> PeripheralState? {
        lock.withLock {
            guard let peerID = uuidToPeerID[uuid] else { return nil }
            return peers[peerID]
        }
    }

    /// Get all unique peer IDs from both direct peers and their announced neighbors.
    public func allKnownPeerIDs() -> Set<PeerID> {
        lock.withLock {
            var result = Set(peers.keys)
            for state in peers.values {
                result.formUnion(state.neighbors)
            }
            return result
        }
    }

    // MARK: - Scoring (spec Section 5.4)

    /// Score a peer for connection priority.
    ///
    /// Components:
    /// - RSSI: sweet spot -60 to -70 dBm scores highest (40 points max).
    /// - Diversity: peers in different clusters preferred (20 points max).
    /// - Stability: longer connections preferred (20 points max).
    /// - Bridge: bridge nodes get a bonus (20 points max).
    ///
    /// Returns a score from 0 to 100.
    public func score(for peerID: PeerID) -> Double {
        lock.withLock {
            guard let state = peers[peerID] else { return 0 }
            return computeScore(state)
        }
    }

    /// Compute the score for a peer state (called under lock).
    private func computeScore(_ state: PeripheralState) -> Double {
        var total: Double = 0

        // RSSI component (0-40 points): sweet spot is -60 to -70 dBm.
        let rssi = Double(state.rssi)
        if rssi >= -70 && rssi <= -60 {
            total += 40.0 // Perfect range
        } else if rssi > -60 {
            // Too close, slightly less ideal but still good.
            total += max(20.0, 40.0 - (rssi - (-60)) * 2.0)
        } else if rssi < -70 {
            // Getting farther, score decreases linearly.
            let distance = -70.0 - rssi
            total += max(0.0, 40.0 - distance * 1.5)
        }

        // Diversity component (0-20 points): different clusters preferred.
        let connectedClusters = Set(
            peers.values
                .filter { $0.isConnected }
                .compactMap(\.clusterID)
        )
        if let clusterID = state.clusterID {
            if !connectedClusters.contains(clusterID) {
                total += 20.0 // New cluster diversity.
            } else {
                total += 5.0 // Same cluster, still some value.
            }
        } else {
            total += 10.0 // Unknown cluster, moderate value.
        }

        // Stability component (0-20 points): capped at 10 cycles.
        let stabilityClamped = min(state.stabilityScore, 10)
        total += Double(stabilityClamped) * 2.0

        // Bridge component (0-20 points).
        if state.isBridge {
            total += 20.0
        }

        return min(total, 100.0)
    }

    // MARK: - Evaluation (spec: 30s interval, 20% hysteresis)

    /// Start the periodic peer evaluation timer.
    public func startEvaluation() {
        evaluationTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + BLEConstants.peerEvaluationInterval,
            repeating: BLEConstants.peerEvaluationInterval
        )
        timer.setEventHandler { [weak self] in
            self?.evaluatePeers()
        }
        timer.resume()
        evaluationTimer = timer
    }

    /// Stop the periodic evaluation.
    public func stopEvaluation() {
        evaluationTimer?.cancel()
        evaluationTimer = nil
    }

    /// Perform a peer evaluation cycle.
    ///
    /// Increments stability scores for connected peers, prunes stale peers,
    /// and recommends connection swaps when a discovered peer scores 20%+ higher
    /// than the worst connected peer.
    public func evaluatePeers() {
        lock.lock()

        let now = Date()

        // Increment stability for connected peers.
        for (peerID, _) in peers where peers[peerID]?.isConnected == true {
            peers[peerID]?.stabilityScore += 1
        }

        // Prune stale peers (not connected and not seen recently).
        let staleIDs = peers.filter { _, state in
            !state.isConnected &&
            now.timeIntervalSince(state.lastSeen) > BLEConstants.peerStaleTimeout
        }.map(\.key)

        for id in staleIDs {
            if let state = peers.removeValue(forKey: id) {
                uuidToPeerID.removeValue(forKey: state.peripheralUUID)
            }
        }

        // Find the worst connected peer.
        let connected = peers.values.filter(\.isConnected)
        let worstConnected = connected.min(by: { computeScore($0) < computeScore($1) })

        // Find the best disconnected peer.
        let disconnected = peers.values.filter { !$0.isConnected }
        let bestDisconnected = disconnected.max(by: { computeScore($0) < computeScore($1) })

        let maxConnections = role.maxConnections
        let currentConnectionCount = connected.count

        // If we have room, just recommend connecting.
        if currentConnectionCount < maxConnections, let best = bestDisconnected {
            let uuid = best.peripheralUUID
            lock.unlock()
            onShouldConnect?(uuid)
            return
        }

        // If at capacity, check if a swap is warranted (20% hysteresis).
        if let worst = worstConnected, let best = bestDisconnected {
            let worstScore = computeScore(worst)
            let bestScore = computeScore(best)
            let hysteresisThreshold = worstScore * 1.2

            if bestScore > hysteresisThreshold {
                let disconnectPeerID = worst.peerID
                let connectUUID = best.peripheralUUID
                lock.unlock()
                logger.info("Swap: disconnect \(disconnectPeerID) (score \(worstScore)) for \(best.peerID) (score \(bestScore))")
                onShouldDisconnect?(disconnectPeerID)
                onShouldConnect?(connectUUID)
                return
            }
        }

        lock.unlock()
    }
}
