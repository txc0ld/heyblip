import Foundation
import BlipProtocol
import os.log

// MARK: - Route entry

/// A single routing table entry: "Peer X was last seen via Peer Y at time T."
struct RouteEntry: Sendable {
    /// The next-hop peer to reach the destination.
    let viaPeer: PeerID
    /// When this route was last updated.
    let updatedAt: Date
    /// Estimated hop count to the destination.
    let hopCount: Int
}

// MARK: - DirectedRouter

/// Directed routing for DMs at scale (spec Section 8.5).
///
/// At Mega/Massive crowd modes, DMs use directed routing instead of gossip:
/// - Announcement packets include neighbor peer ID lists.
/// - Nodes build partial routing tables: "Peer X last seen via Peer Y."
/// - DMs route along known paths (unicast over mesh).
/// - Fallback to gossip with reduced TTL if no path known.
/// - Routing entries expire after 5 minutes.
public final class DirectedRouter: @unchecked Sendable {

    // MARK: - Constants

    /// Routing entry expiry time (spec: 5 minutes).
    public static let routeExpiryInterval: TimeInterval = 5 * 60

    // MARK: - State

    /// Routing table: destination PeerID -> RouteEntry (best known route).
    private var routes: [PeerID: RouteEntry] = [:]

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "DirectedRouter")

    // MARK: - Init

    public init() {}

    // MARK: - Route management

    /// Process an announcement from a neighbor, updating the routing table.
    ///
    /// The neighbor's announced peers are reachable through that neighbor.
    ///
    /// - Parameters:
    ///   - neighbor: The peer that sent the announcement.
    ///   - neighbors: The peer IDs that the announcing peer is connected to.
    public func processAnnouncement(from neighbor: PeerID, neighbors: [PeerID]) {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        // The neighbor itself is directly reachable (1 hop).
        routes[neighbor] = RouteEntry(viaPeer: neighbor, updatedAt: now, hopCount: 1)

        // Each of the neighbor's neighbors is reachable via the neighbor (2 hops).
        for peerID in neighbors {
            if let existing = routes[peerID] {
                // Update if our route is older or has more hops.
                if existing.hopCount > 2 || now.timeIntervalSince(existing.updatedAt) > 60 {
                    routes[peerID] = RouteEntry(viaPeer: neighbor, updatedAt: now, hopCount: 2)
                }
            } else {
                routes[peerID] = RouteEntry(viaPeer: neighbor, updatedAt: now, hopCount: 2)
            }
        }
    }

    /// Update a route manually (e.g., from a routing hint in a packet).
    ///
    /// - Parameters:
    ///   - peerID: The destination peer.
    ///   - viaPeer: The next-hop peer to reach the destination.
    ///   - hopCount: Estimated hops to the destination.
    public func updateRoute(peerID: PeerID, viaPeer: PeerID, hopCount: Int = 1) {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if let existing = routes[peerID] {
            // Prefer shorter/fresher routes.
            if hopCount < existing.hopCount || now.timeIntervalSince(existing.updatedAt) > 60 {
                routes[peerID] = RouteEntry(viaPeer: viaPeer, updatedAt: now, hopCount: hopCount)
            }
        } else {
            routes[peerID] = RouteEntry(viaPeer: viaPeer, updatedAt: now, hopCount: hopCount)
        }
    }

    /// Find the best route to a destination peer.
    ///
    /// - Parameter destination: The target peer ID.
    /// - Returns: The next-hop peer ID, or `nil` if no route is known (fallback to gossip).
    public func findRoute(to destination: PeerID) -> PeerID? {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        guard let entry = routes[destination] else { return nil }

        // Check expiry.
        if now.timeIntervalSince(entry.updatedAt) > Self.routeExpiryInterval {
            routes.removeValue(forKey: destination)
            return nil
        }

        return entry.viaPeer
    }

    /// Check if a route exists to a destination (without removing expired routes).
    public func hasRoute(to destination: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = routes[destination] else { return false }
        return Date().timeIntervalSince(entry.updatedAt) <= Self.routeExpiryInterval
    }

    /// Get the estimated hop count to a destination.
    public func hopCount(to destination: PeerID) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = routes[destination] else { return nil }
        guard Date().timeIntervalSince(entry.updatedAt) <= Self.routeExpiryInterval else { return nil }
        return entry.hopCount
    }

    /// Remove all routes via a specific peer (when that peer disconnects).
    public func removeRoutes(viaPeer: PeerID) {
        lock.lock()
        defer { lock.unlock() }

        routes = routes.filter { $0.value.viaPeer != viaPeer }
    }

    /// Clear all routing entries.
    public func clearRoutes() {
        lock.lock()
        defer { lock.unlock() }

        routes.removeAll()
    }

    /// Prune expired routing entries.
    public func pruneExpired() {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        routes = routes.filter { _, entry in
            now.timeIntervalSince(entry.updatedAt) <= Self.routeExpiryInterval
        }
    }

    /// Current number of routing entries.
    public var routeCount: Int {
        lock.withLock { routes.count }
    }

    /// All known destinations (for diagnostics).
    public var knownDestinations: Set<PeerID> {
        lock.withLock { Set(routes.keys) }
    }
}
