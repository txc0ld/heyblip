import Foundation
import os.log

// MARK: - PeerInfo

/// Ephemeral transport-level peer state. Not persisted — rebuilt on every app launch
/// from BLE discovery and announce packets. Matches the BitChat production pattern
/// where peers are pure transport state, not database records.
struct PeerInfo: Sendable {
    let peerID: Data
    var noisePublicKey: Data
    var signingPublicKey: Data
    var username: String?
    var rssi: Int
    var isConnected: Bool
    var lastSeenAt: Date
    var hopCount: Int
}

// MARK: - PeerStore

/// Thread-safe, in-memory peer store for ephemeral transport state.
///
/// All reads use a concurrent queue; writes use barrier blocks for thread safety.
/// Publishes `.peerStoreDidChange` on every mutation so UI can react.
final class PeerStore: @unchecked Sendable {

    static let shared = PeerStore()

    // MARK: - Storage

    private var peers: [Data: PeerInfo] = [:]
    private let queue = DispatchQueue(label: "com.blip.PeerStore", attributes: .concurrent)
    private let logger = Logger(subsystem: "com.blip", category: "PeerStore")

    // MARK: - Read

    /// All peers currently tracked (connected and recently disconnected).
    func allPeers() -> [PeerInfo] {
        queue.sync { Array(peers.values) }
    }

    /// Only peers with `isConnected == true`.
    func connectedPeers() -> [PeerInfo] {
        queue.sync { peers.values.filter(\.isConnected) }
    }

    /// Look up a single peer by its transport peerID bytes.
    func peer(for peerID: Data) -> PeerInfo? {
        queue.sync { peers[peerID] }
    }

    /// Look up a peer by noisePublicKey (handles identity mismatch between transport PeerID and noise PeerID).
    func peer(byNoisePublicKey key: Data) -> PeerInfo? {
        queue.sync { peers.values.first { $0.noisePublicKey == key } }
    }

    /// Look up a peer by username.
    func peer(byUsername username: String) -> PeerInfo? {
        queue.sync { peers.values.first { $0.username == username } }
    }

    /// Find a peer by transport peerID first, then fallback to noisePublicKey.
    /// Find by transport peerID first, then fallback to noisePublicKey.
    func findPeer(byPeerIDBytes peerData: Data) -> PeerInfo? {
        queue.sync {
            if let direct = peers[peerData] {
                return direct
            }
            return peers.values.first { $0.noisePublicKey == peerData }
        }
    }

    // MARK: - Write

    /// Insert or update a peer. Merges fields that the caller provides.
    func upsert(peer info: PeerInfo) {
        queue.async(flags: .barrier) { [self] in
            if var existing = peers[info.peerID] {
                // Merge — caller-provided fields win
                if !info.noisePublicKey.isEmpty {
                    existing.noisePublicKey = info.noisePublicKey
                }
                if !info.signingPublicKey.isEmpty {
                    existing.signingPublicKey = info.signingPublicKey
                }
                if let name = info.username {
                    existing.username = name
                }
                existing.rssi = info.rssi
                existing.isConnected = info.isConnected
                existing.lastSeenAt = info.lastSeenAt
                existing.hopCount = info.hopCount
                peers[info.peerID] = existing
            } else {
                peers[info.peerID] = info
            }
            postDidChange()
        }
    }

    /// Mark a peer as disconnected immediately (fixes ghost peer bug).
    func markDisconnected(peerID: Data) {
        queue.async(flags: .barrier) { [self] in
            guard var existing = peers[peerID] else { return }
            existing.isConnected = false
            peers[peerID] = existing
            postDidChange()
        }
    }

    /// Remove a peer entirely.
    func remove(peerID: Data) {
        queue.async(flags: .barrier) { [self] in
            peers.removeValue(forKey: peerID)
            postDidChange()
        }
    }

    /// Remove peers not seen in the given interval.
    func pruneStale(olderThan interval: TimeInterval) {
        queue.async(flags: .barrier) { [self] in
            let threshold = Date().addingTimeInterval(-interval)
            let before = peers.count
            peers = peers.filter { $0.value.lastSeenAt > threshold }
            let removed = before - peers.count
            if removed > 0 {
                logger.info("Pruned \(removed) stale peer(s)")
                postDidChange()
            }
        }
    }

    /// Mark all connected peers whose peerID is NOT in the given set as disconnected.
    func markDisconnectedExcept(activePeerIDs: Set<Data>) {
        queue.async(flags: .barrier) { [self] in
            var changed = false
            for (key, var peer) in peers {
                if peer.isConnected && !activePeerIDs.contains(key) {
                    peer.isConnected = false
                    peers[key] = peer
                    changed = true
                }
            }
            if changed { postDidChange() }
        }
    }

    /// Remove all peers (e.g. on sign-out).
    func removeAll() {
        queue.async(flags: .barrier) { [self] in
            peers.removeAll()
            postDidChange()
        }
    }

    // MARK: - Notification

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .peerStoreDidChange, object: nil)
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let peerStoreDidChange = Notification.Name("com.blip.peerStoreDidChange")
}
