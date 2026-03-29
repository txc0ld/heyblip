import Foundation
import BlipProtocol
import os.log

// MARK: - Cache entry

/// A cached packet with metadata for store-and-forward delivery.
struct CacheEntry: Sendable {
    let packet: Packet
    let cachedAt: Date
    let expiresAt: Date
    let size: Int

    /// Whether this entry has expired.
    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

// MARK: - StoreForwardCache

/// Tiered store-and-forward cache for the mesh network (spec Section 5.6).
///
/// Caches packets for peers that are currently unreachable so they can be
/// delivered when the peer connects. Different content types have different
/// cache durations:
///
/// | Type              | Duration    |
/// |-------------------|-------------|
/// | DMs               | 2 hours     |
/// | Group messages    | 30 minutes  |
/// | Location channels | 5 minutes   |
/// | Announcements     | 1 hour      |
/// | SOS alerts        | Until resolved |
///
/// Total cache is capped at 10 MB with LRU eviction.
public final class StoreForwardCache: @unchecked Sendable {

    // MARK: - Duration constants (seconds)

    /// Cache duration for DMs: 2 hours.
    public static let dmDuration: TimeInterval = 2 * 60 * 60

    /// Cache duration for group messages: 30 minutes.
    public static let groupDuration: TimeInterval = 30 * 60

    /// Cache duration for location/stage channel messages: 5 minutes.
    public static let channelDuration: TimeInterval = 5 * 60

    /// Cache duration for organizer announcements: 1 hour.
    public static let announcementDuration: TimeInterval = 60 * 60

    /// SOS alerts are cached indefinitely (until resolved or festival ends).
    public static let sosDuration: TimeInterval = .infinity

    /// Maximum cache size in bytes: 10 MB.
    public static let maxCacheSizeBytes = 10 * 1024 * 1024

    // MARK: - State

    /// All cached entries, ordered by insertion time (oldest first for LRU).
    private var entries: [CacheEntry] = []

    /// Current total cache size in bytes.
    private var currentSize: Int = 0

    /// Set of resolved SOS sender IDs to stop caching their alerts.
    private var resolvedSOSSenders: Set<PeerID> = Set()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "StoreForwardCache")

    // MARK: - Init

    public init() {}

    // MARK: - Cache operations

    /// Cache a packet for later delivery.
    ///
    /// Determines the appropriate cache duration based on the packet type,
    /// evicts expired entries and applies LRU eviction if the cache is full.
    public func cache(packet: Packet) {
        let duration = cacheDuration(for: packet)
        guard duration > 0 else { return } // Not cacheable (e.g., voice/images).

        // Don't cache SOS for resolved senders.
        if packet.type.isSOS {
            lock.lock()
            if resolvedSOSSenders.contains(packet.senderID) {
                lock.unlock()
                return
            }
            lock.unlock()
        }

        let now = Date()
        let expiresAt = duration.isInfinite ? Date.distantFuture : now.addingTimeInterval(duration)
        let entrySize = estimateSize(of: packet)

        let entry = CacheEntry(
            packet: packet,
            cachedAt: now,
            expiresAt: expiresAt,
            size: entrySize
        )

        lock.lock()
        defer { lock.unlock() }

        // Evict expired entries first.
        evictExpired(now: now)

        // LRU eviction if needed to fit the new entry.
        while currentSize + entrySize > Self.maxCacheSizeBytes && !entries.isEmpty {
            let removed = entries.removeFirst()
            currentSize -= removed.size
        }

        // If the single entry exceeds the cache, skip it.
        guard entrySize <= Self.maxCacheSizeBytes else {
            logger.warning("Packet too large to cache: \(entrySize) bytes")
            return
        }

        entries.append(entry)
        currentSize += entrySize
    }

    /// Retrieve all cached packets addressed to a specific peer.
    ///
    /// Removes retrieved entries from the cache.
    public func retrieve(forPeerID peerID: PeerID) -> [Packet] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        evictExpired(now: now)

        var result: [Packet] = []
        var kept: [CacheEntry] = []

        for entry in entries {
            if entry.packet.recipientID == peerID {
                result.append(entry.packet)
                currentSize -= entry.size
            } else {
                kept.append(entry)
            }
        }

        entries = kept
        return result
    }

    /// Retrieve all cached broadcast packets (no specific recipient).
    public func retrieveBroadcasts() -> [Packet] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        evictExpired(now: now)

        return entries
            .filter { $0.packet.recipientID == nil || $0.packet.recipientID == PeerID.broadcast }
            .map(\.packet)
    }

    /// Mark an SOS alert as resolved, removing cached SOS packets from that sender.
    public func resolveSOSAlert(senderID: PeerID) {
        lock.lock()
        defer { lock.unlock() }

        resolvedSOSSenders.insert(senderID)

        entries.removeAll { entry in
            if entry.packet.type.isSOS && entry.packet.senderID == senderID {
                currentSize -= entry.size
                return true
            }
            return false
        }
    }

    /// Clear all cached entries.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
        currentSize = 0
        resolvedSOSSenders.removeAll()
    }

    /// Current number of cached entries.
    public var entryCount: Int {
        lock.withLock { entries.count }
    }

    /// Current cache size in bytes.
    public var cacheSizeBytes: Int {
        lock.withLock { currentSize }
    }

    // MARK: - Internals

    /// Determine the cache duration for a packet type (spec Section 5.6).
    private func cacheDuration(for packet: Packet) -> TimeInterval {
        switch packet.type {
        // DMs are typically sent as noiseEncrypted with hasRecipient flag.
        case .noiseEncrypted:
            if packet.flags.contains(.hasRecipient) {
                return Self.dmDuration
            }
            return Self.groupDuration

        case .meshBroadcast, .channelUpdate:
            return Self.channelDuration

        case .orgAnnouncement:
            return Self.announcementDuration

        case .sosAlert, .sosAccept, .sosPreciseLocation, .sosNearbyAssist:
            return Self.sosDuration

        case .sosResolve:
            return Self.announcementDuration // Shorter, it's a resolution notice.

        case .announce, .leave, .noiseHandshake:
            return Self.channelDuration // Short cache for protocol messages.

        case .syncRequest:
            return Self.channelDuration

        case .fragment:
            return Self.groupDuration

        // Voice, images, files: not cached on relay nodes (too large).
        case .fileTransfer, .pttAudio:
            return 0

        case .locationShare, .locationRequest, .proximityPing, .iAmHereBeacon:
            return Self.channelDuration
        }
    }

    /// Estimate the byte size of a packet for cache accounting.
    private func estimateSize(of packet: Packet) -> Int {
        // Header + sender + payload + optional recipient + optional signature.
        packet.wireSize
    }

    /// Remove expired entries (called under lock).
    private func evictExpired(now: Date) {
        entries.removeAll { entry in
            if entry.isExpired(now: now) {
                currentSize -= entry.size
                return true
            }
            return false
        }
    }
}
