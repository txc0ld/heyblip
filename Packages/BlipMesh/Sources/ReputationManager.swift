import Foundation
import BlipProtocol
import os.log

// MARK: - Reputation thresholds

/// Constants for the reputation system.
public enum ReputationThreshold {
    /// Number of block votes to deprioritize a peer's traffic.
    public static let deprioritize = 10
    /// Number of block votes to drop a peer's broadcasts entirely.
    public static let dropBroadcasts = 25
}

// MARK: - Peer reputation

/// Reputation state for a single peer.
struct PeerReputation: Sendable {
    /// The peer's ID.
    let peerID: PeerID
    /// Total block votes received from peers in the cluster.
    var blockVotes: Int
    /// Set of peers that have voted to block this peer (to prevent duplicate votes).
    var voters: Set<PeerID>
    /// Whether this peer is deprioritized (>= 10 votes).
    var isDeprioritized: Bool { blockVotes >= ReputationThreshold.deprioritize }
    /// Whether this peer's broadcasts are dropped (>= 25 votes).
    var isBroadcastDropped: Bool { blockVotes >= ReputationThreshold.dropBroadcasts }
}

// MARK: - ReputationManager

/// Block vote tallying and traffic moderation per cluster (spec Section 8).
///
/// Peers can vote to block disruptive users. Thresholds:
/// - 10 votes: traffic from the peer is deprioritized (moved to low-priority lane).
/// - 25 votes: broadcasts from the peer are dropped entirely.
///
/// SOS traffic is always exempt from reputation filtering.
/// Reputation resets per festival (when a new festival is joined).
public final class ReputationManager: @unchecked Sendable {

    // MARK: - State

    /// Per-peer reputation indexed by PeerID.
    private var reputations: [PeerID: PeerReputation] = [:]

    /// The current festival ID (reputation resets when this changes).
    private var currentFestivalID: String?

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "Reputation")

    // MARK: - Init

    public init() {}

    // MARK: - Voting

    /// Record a block vote from one peer against another.
    ///
    /// Each voter can only vote once per target peer.
    ///
    /// - Parameters:
    ///   - voter: The peer casting the block vote.
    ///   - target: The peer being voted against.
    /// - Returns: The new block vote count for the target.
    @discardableResult
    public func recordBlockVote(from voter: PeerID, against target: PeerID) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var rep = reputations[target] ?? PeerReputation(
            peerID: target,
            blockVotes: 0,
            voters: []
        )

        // Prevent duplicate votes from the same voter.
        guard !rep.voters.contains(voter) else {
            return rep.blockVotes
        }

        rep.voters.insert(voter)
        rep.blockVotes += 1
        reputations[target] = rep

        if rep.blockVotes == ReputationThreshold.deprioritize {
            logger.info("Peer \(target) reached deprioritize threshold (\(rep.blockVotes) votes)")
        }
        if rep.blockVotes == ReputationThreshold.dropBroadcasts {
            logger.info("Peer \(target) reached broadcast drop threshold (\(rep.blockVotes) votes)")
        }

        return rep.blockVotes
    }

    // MARK: - Packet filtering

    /// Check if a packet should be allowed through based on the sender's reputation.
    ///
    /// - Parameter packet: The packet to check.
    /// - Returns: `true` if the packet should be processed, `false` if it should be dropped.
    public func shouldAllow(packet: Packet) -> Bool {
        // SOS is always exempt (spec).
        if packet.type.isSOS { return true }

        lock.lock()
        defer { lock.unlock() }

        guard let rep = reputations[packet.senderID] else {
            return true // No reputation data, allow.
        }

        // 25+ votes: drop all broadcasts from this peer.
        if rep.isBroadcastDropped {
            let isBroadcast = !packet.flags.contains(.hasRecipient)
            if isBroadcast {
                return false
            }
        }

        return true
    }

    /// Check if a peer's traffic should be deprioritized.
    ///
    /// - Parameter peerID: The peer to check.
    /// - Returns: `true` if the peer's traffic should be moved to the low-priority lane.
    public func isDeprioritized(_ peerID: PeerID) -> Bool {
        lock.withLock {
            reputations[peerID]?.isDeprioritized ?? false
        }
    }

    /// Check if a peer's broadcasts should be dropped.
    public func isBroadcastDropped(_ peerID: PeerID) -> Bool {
        lock.withLock {
            reputations[peerID]?.isBroadcastDropped ?? false
        }
    }

    /// Get the current block vote count for a peer.
    public func blockVoteCount(for peerID: PeerID) -> Int {
        lock.withLock {
            reputations[peerID]?.blockVotes ?? 0
        }
    }

    // MARK: - Festival lifecycle

    /// Set the current festival ID. If it changes, reset all reputation data.
    public func setFestival(_ festivalID: String) {
        lock.lock()
        defer { lock.unlock() }

        if currentFestivalID != festivalID {
            logger.info("Festival changed to \(festivalID), resetting reputation data")
            reputations.removeAll()
            currentFestivalID = festivalID
        }
    }

    // MARK: - Reset

    /// Reset all reputation data (e.g., when leaving a festival).
    public func reset() {
        lock.withLock {
            reputations.removeAll()
            currentFestivalID = nil
        }
    }

    /// Remove reputation data for a specific peer.
    public func removeReputation(for peerID: PeerID) {
        lock.lock()
        reputations.removeValue(forKey: peerID)
        lock.unlock()
    }

    /// Current number of peers with reputation data.
    public var trackedPeerCount: Int {
        lock.withLock { reputations.count }
    }
}
