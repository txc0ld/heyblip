import Foundation
import BlipProtocol
import os.log

// MARK: - Cluster

/// A group of nearby peers organized by RSSI proximity (spec Section 8.4).
public struct Cluster: Sendable, Identifiable {
    /// Unique cluster identifier.
    public let id: UUID
    /// Peer IDs belonging to this cluster.
    public var members: Set<PeerID>
    /// Average RSSI of members.
    public var averageRSSI: Double
    /// When this cluster was formed.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        members: Set<PeerID> = [],
        averageRSSI: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.members = members
        self.averageRSSI = averageRSSI
        self.createdAt = createdAt
    }
}

// MARK: - ClusterManager

/// Manages RSSI-based clustering of mesh peers (spec Section 8.4).
///
/// Devices self-organize into clusters of 20-60 peers based on RSSI proximity.
/// Bridge nodes (connected to 2+ clusters) relay inter-cluster traffic selectively.
/// Location broadcasts stay within their cluster.
///
/// Clusters split at 80 members to maintain manageable sizes.
public final class ClusterManager: @unchecked Sendable {

    // MARK: - Constants

    /// Minimum cluster size target.
    public static let minClusterSize = 20

    /// Maximum cluster size target.
    public static let maxClusterSize = 60

    /// Cluster split threshold (split when exceeding this count).
    public static let splitThreshold = 80

    /// RSSI similarity threshold: peers within this range are considered in the same cluster.
    public static let rssiSimilarityThreshold: Int = 15

    /// How often to re-evaluate clusters.
    public static let evaluationInterval: TimeInterval = 30.0

    // MARK: - State

    /// Active clusters indexed by cluster ID.
    private var clusters: [UUID: Cluster] = [:]

    /// Peer-to-cluster mapping for quick lookups.
    private var peerCluster: [PeerID: UUID] = [:]

    /// Bridge nodes: peers connected to 2+ clusters.
    private var bridgeNodes: Set<PeerID> = Set()

    /// Peer RSSI readings for clustering decisions.
    private var peerRSSI: [PeerID: Int] = [:]

    /// Callback to notify PeerManager of cluster/bridge updates.
    public var onClusterUpdate: ((PeerID, UUID?) -> Void)?
    public var onBridgeUpdate: ((PeerID, Bool) -> Void)?

    private let lock = NSLock()
    private var evaluationTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blip.cluster", qos: .utility)
    private let logger = Logger(subsystem: "com.blip", category: "ClusterManager")

    // MARK: - Init

    public init() {}

    // MARK: - Peer reporting

    /// Report a peer's RSSI for clustering.
    public func updatePeerRSSI(_ peerID: PeerID, rssi: Int) {
        lock.withLock {
            peerRSSI[peerID] = rssi
        }
    }

    /// Remove a peer from tracking.
    public func removePeer(_ peerID: PeerID) {
        lock.lock()

        peerRSSI.removeValue(forKey: peerID)

        if let clusterID = peerCluster.removeValue(forKey: peerID) {
            clusters[clusterID]?.members.remove(peerID)

            // Remove empty clusters.
            if clusters[clusterID]?.members.isEmpty == true {
                clusters.removeValue(forKey: clusterID)
            }
        }

        bridgeNodes.remove(peerID)

        lock.unlock()
    }

    // MARK: - Cluster queries

    /// Get the cluster ID for a peer.
    public func clusterID(for peerID: PeerID) -> UUID? {
        lock.withLock { peerCluster[peerID] }
    }

    /// Check if a peer is a bridge node.
    public func isBridge(_ peerID: PeerID) -> Bool {
        lock.withLock { bridgeNodes.contains(peerID) }
    }

    /// Get all clusters.
    public var allClusters: [Cluster] {
        lock.withLock { Array(clusters.values) }
    }

    /// Get all bridge nodes.
    public var allBridgeNodes: Set<PeerID> {
        lock.withLock { bridgeNodes }
    }

    /// Get the cluster a peer belongs to.
    public func cluster(for peerID: PeerID) -> Cluster? {
        lock.withLock {
            guard let clusterID = peerCluster[peerID] else { return nil }
            return clusters[clusterID]
        }
    }

    // MARK: - Evaluation

    /// Start periodic cluster evaluation.
    public func startEvaluation() {
        evaluationTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.evaluationInterval,
            repeating: Self.evaluationInterval
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateClusters()
        }
        timer.resume()
        evaluationTimer = timer
    }

    /// Stop periodic evaluation.
    public func stopEvaluation() {
        evaluationTimer?.cancel()
        evaluationTimer = nil
    }

    /// Perform a clustering evaluation cycle.
    ///
    /// Uses a simple RSSI-proximity grouping algorithm:
    /// 1. Sort peers by RSSI.
    /// 2. Group peers with similar RSSI into clusters.
    /// 3. Split clusters exceeding 80 members.
    /// 4. Detect bridge nodes (peers visible to members of 2+ clusters).
    public func evaluateClusters() {
        lock.lock()

        let peersByRSSI = peerRSSI.sorted { $0.value > $1.value } // Strongest first.

        guard !peersByRSSI.isEmpty else {
            lock.unlock()
            return
        }

        // Build clusters by grouping peers with similar RSSI.
        var newClusters: [UUID: Cluster] = [:]
        var newPeerCluster: [PeerID: UUID] = [:]
        var currentCluster = Cluster()
        var currentRSSISum: Double = 0

        for (peerID, rssi) in peersByRSSI {
            if currentCluster.members.isEmpty {
                // Start a new cluster.
                currentCluster.members.insert(peerID)
                currentRSSISum = Double(rssi)
                currentCluster = Cluster(
                    id: currentCluster.id,
                    members: [peerID],
                    averageRSSI: Double(rssi)
                )
            } else {
                let avgRSSI = currentRSSISum / Double(currentCluster.members.count)
                let distance = abs(Double(rssi) - avgRSSI)

                if distance <= Double(Self.rssiSimilarityThreshold) &&
                   currentCluster.members.count < Self.splitThreshold {
                    // Add to current cluster.
                    currentCluster.members.insert(peerID)
                    currentRSSISum += Double(rssi)
                    currentCluster.averageRSSI = currentRSSISum / Double(currentCluster.members.count)
                } else {
                    // Finalize current cluster and start new one.
                    if currentCluster.members.count >= 2 {
                        let finalized = splitIfNeeded(currentCluster)
                        for cluster in finalized {
                            newClusters[cluster.id] = cluster
                            for member in cluster.members {
                                newPeerCluster[member] = cluster.id
                            }
                        }
                    } else {
                        // Single-member cluster, just assign.
                        newClusters[currentCluster.id] = currentCluster
                        for member in currentCluster.members {
                            newPeerCluster[member] = currentCluster.id
                        }
                    }

                    currentCluster = Cluster(members: [peerID], averageRSSI: Double(rssi))
                    currentRSSISum = Double(rssi)
                }
            }
        }

        // Finalize the last cluster.
        if !currentCluster.members.isEmpty {
            let finalized = splitIfNeeded(currentCluster)
            for cluster in finalized {
                newClusters[cluster.id] = cluster
                for member in cluster.members {
                    newPeerCluster[member] = cluster.id
                }
            }
        }

        // Detect bridge nodes: peers that are connected to members of 2+ clusters.
        // Simplified: a peer is a bridge if it appears in neighbors of peers in different clusters.
        var newBridgeNodes = Set<PeerID>()
        for (peerID, clusterID) in newPeerCluster {
            // Check if this peer's RSSI puts it near the boundary of another cluster.
            if let peerRSSIValue = peerRSSI[peerID] {
                for (otherClusterID, otherCluster) in newClusters where otherClusterID != clusterID {
                    let distance = abs(Double(peerRSSIValue) - otherCluster.averageRSSI)
                    if distance <= Double(Self.rssiSimilarityThreshold) {
                        newBridgeNodes.insert(peerID)
                        break
                    }
                }
            }
        }

        // Find changes and notify.
        let oldPeerCluster = self.peerCluster
        let oldBridgeNodes = self.bridgeNodes

        self.clusters = newClusters
        self.peerCluster = newPeerCluster
        self.bridgeNodes = newBridgeNodes

        lock.unlock()

        // Notify of cluster changes.
        for (peerID, newClusterID) in newPeerCluster {
            if oldPeerCluster[peerID] != newClusterID {
                onClusterUpdate?(peerID, newClusterID)
            }
        }

        // Notify of bridge status changes.
        let addedBridges = newBridgeNodes.subtracting(oldBridgeNodes)
        let removedBridges = oldBridgeNodes.subtracting(newBridgeNodes)

        for peerID in addedBridges {
            onBridgeUpdate?(peerID, true)
        }
        for peerID in removedBridges {
            onBridgeUpdate?(peerID, false)
        }
    }

    // MARK: - Splitting

    /// Split a cluster if it exceeds the split threshold.
    ///
    /// Splits into roughly equal halves based on RSSI ordering.
    private func splitIfNeeded(_ cluster: Cluster) -> [Cluster] {
        guard cluster.members.count > Self.splitThreshold else {
            return [cluster]
        }

        let sorted = cluster.members.sorted { a, b in
            (peerRSSI[a] ?? -100) > (peerRSSI[b] ?? -100)
        }

        let midpoint = sorted.count / 2
        let firstHalf = Set(sorted[..<midpoint])
        let secondHalf = Set(sorted[midpoint...])

        let firstRSSI = firstHalf.compactMap { peerRSSI[$0] }
        let secondRSSI = secondHalf.compactMap { peerRSSI[$0] }

        let cluster1 = Cluster(
            members: firstHalf,
            averageRSSI: firstRSSI.isEmpty ? 0 : Double(firstRSSI.reduce(0, +)) / Double(firstRSSI.count)
        )
        let cluster2 = Cluster(
            members: secondHalf,
            averageRSSI: secondRSSI.isEmpty ? 0 : Double(secondRSSI.reduce(0, +)) / Double(secondRSSI.count)
        )

        return [cluster1, cluster2]
    }

    // MARK: - Reset

    /// Clear all cluster state.
    public func reset() {
        lock.withLock {
            clusters.removeAll()
            peerCluster.removeAll()
            bridgeNodes.removeAll()
            peerRSSI.removeAll()
        }
    }
}
