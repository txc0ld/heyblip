import Foundation
import BlipProtocol
import os.log

// MARK: - GossipRouter delegate

/// Delegate for the gossip router to send relayed packets.
public protocol GossipRouterDelegate: AnyObject, Sendable {
    /// Called when the router decides to relay a packet.
    ///
    /// - Parameters:
    ///   - router: The gossip router.
    ///   - packet: The packet to relay (TTL already decremented).
    ///   - excludedPeer: The peer that originally sent the packet (do not relay back).
    func gossipRouter(_ router: GossipRouter, shouldRelay packet: Packet, excluding excludedPeer: PeerID)
}

// MARK: - GossipRouter

/// Core gossip routing engine for the Blip mesh (spec Section 5.5).
///
/// Receives packets, checks the Bloom filter for duplicates, decrements TTL,
/// and relays with probability determined by the `AdaptiveRelay` calculator.
/// SOS packets are always relayed regardless of probability.
public final class GossipRouter: @unchecked Sendable {

    // MARK: - Dependencies

    /// Multi-tier Bloom filter for packet deduplication.
    public let bloomFilter: MultiTierBloomFilter

    /// Separate Bloom filter for SOS packets (10x lower density per spec 8.9).
    public let sosBloomFilter: MultiTierBloomFilter

    /// Adaptive relay probability calculator.
    public let adaptiveRelay: AdaptiveRelay

    /// Store-and-forward cache for offline delivery.
    public let storeForwardCache: StoreForwardCache

    /// Directed router for targeted DM delivery in Mega/Massive modes.
    public let directedRouter: DirectedRouter

    /// Delegate for sending relayed packets.
    public weak var delegate: GossipRouterDelegate?

    // MARK: - Metrics

    /// Total packets received.
    public private(set) var packetsReceived: UInt64 = 0

    /// Total packets relayed.
    public private(set) var packetsRelayed: UInt64 = 0

    /// Total packets dropped (duplicate or TTL expired).
    public private(set) var packetsDropped: UInt64 = 0

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "GossipRouter")

    // MARK: - Init

    public init(
        bloomFilter: MultiTierBloomFilter = MultiTierBloomFilter(),
        sosBloomFilter: MultiTierBloomFilter = MultiTierBloomFilter(),
        adaptiveRelay: AdaptiveRelay = AdaptiveRelay(),
        storeForwardCache: StoreForwardCache = StoreForwardCache(),
        directedRouter: DirectedRouter = DirectedRouter()
    ) {
        self.bloomFilter = bloomFilter
        self.sosBloomFilter = sosBloomFilter
        self.adaptiveRelay = adaptiveRelay
        self.storeForwardCache = storeForwardCache
        self.directedRouter = directedRouter
    }

    // MARK: - Packet handling

    /// Process an incoming packet through the gossip routing pipeline.
    ///
    /// Steps (spec Section 5.5):
    /// 1. Hash packet ID -> check Bloom filter
    /// 2. If seen: discard
    /// 3. If new: add to Bloom filter, decrement TTL
    /// 4. If TTL > 0: relay to all connected peers except source
    /// 5. Relay probability modulated by crowd-scale mode and packet priority
    ///
    /// - Parameters:
    ///   - packet: The received packet.
    ///   - sourcePeer: The peer that sent this packet to us.
    /// - Returns: `true` if the packet is new and should be processed locally, `false` if duplicate.
    @discardableResult
    public func handleIncoming(packet: Packet, from sourcePeer: PeerID) -> Bool {
        lock.lock()
        packetsReceived += 1
        lock.unlock()

        let packetID = packetIdentifier(for: packet)
        let isSOS = packet.type.isSOS

        // Step 1-2: Check Bloom filter for duplicates.
        let filter = isSOS ? sosBloomFilter : bloomFilter
        if filter.contains(packetID) {
            lock.lock()
            packetsDropped += 1
            lock.unlock()
            logger.debug("Duplicate packet dropped: \(packet.type)")
            return false
        }

        // Step 3: Add to Bloom filter.
        filter.insert(packetID)

        // Cache for store-and-forward delivery.
        storeForwardCache.cache(packet: packet)

        // Update directed routing table from announcement packets.
        if packet.type == .announce {
            directedRouter.processAnnouncement(from: sourcePeer, neighbors: extractNeighbors(from: packet))
        }

        // Step 4: Decrement TTL and relay.
        var relayPacket = packet

        // TTL decrement: always decrement for all packet types.
        // SOS packets skip last-hop suppression so they relay even at TTL=0,
        // giving one extra hop of reach. The always-relay at 100% probability
        // for SOS is handled below (line ~148).
        //
        // Previous code skipped decrement entirely for SOS when TTL > 4,
        // which caused SOS packets to relay indefinitely (BDEV-107).
        guard relayPacket.ttl > 0 else {
            lock.lock()
            packetsDropped += 1
            lock.unlock()
            logger.debug("TTL expired, not relaying: \(packet.type)")
            return true // Packet is new, deliver locally, but don't relay.
        }
        relayPacket.ttl -= 1

        // Last-hop suppression for non-SOS packets only.
        // SOS packets relay even at TTL=0 to maximize reach.
        if !isSOS {
            guard relayPacket.ttl > 0 else {
                logger.debug("Last-hop suppression: TTL=0 after decrement, not relaying \(packet.type)")
                return true
            }
        }

        // SOS: always relay with no probability check.
        if isSOS {
            lock.lock()
            packetsRelayed += 1
            lock.unlock()
            delegate?.gossipRouter(self, shouldRelay: relayPacket, excluding: sourcePeer)
            return true
        }

        // Step 5: Check relay probability.
        // Note: packets with decremented TTL=0 are still relayed — the NEXT hop
        // will see TTL=0 and deliver locally without further relay. This matches
        // standard network behavior (TTL=1 = "one more hop").
        let shouldRelay = adaptiveRelay.shouldRelay(packet: relayPacket)
        if shouldRelay {
            lock.lock()
            packetsRelayed += 1
            lock.unlock()

            // Apply jitter before relaying.
            let jitter = adaptiveRelay.jitterDelay()
            let packetToRelay = relayPacket // Capture immutable copy for Sendable closure.
            if jitter > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + jitter) { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.gossipRouter(self, shouldRelay: packetToRelay, excluding: sourcePeer)
                }
            } else {
                delegate?.gossipRouter(self, shouldRelay: packetToRelay, excluding: sourcePeer)
            }
        } else {
            lock.lock()
            packetsDropped += 1
            lock.unlock()
        }

        return true
    }

    /// Deliver any cached packets for a newly connected peer.
    ///
    /// Called when a peer connects and we may have stored messages for them.
    public func deliverCachedPackets(to peerID: PeerID) -> [Packet] {
        storeForwardCache.retrieve(forPeerID: peerID)
    }

    // MARK: - Packet identification

    /// Generate a unique identifier for a packet based on its content.
    ///
    /// Uses sender ID + timestamp + type as the deduplication key.
    public func packetIdentifier(for packet: Packet) -> Data {
        var data = Data()
        data.append(packet.senderID.bytes)
        var ts = packet.timestamp.bigEndian
        data.append(Data(bytes: &ts, count: 8))
        data.append(packet.type.rawValue)
        data.append(packet.payload.prefix(16)) // First 16 bytes of payload for uniqueness.
        return data
    }

    /// Extract neighbor peer IDs from an announcement packet payload.
    ///
    /// The neighbor list in announcement TLV contains up to 8 peer IDs (8 bytes each).
    private func extractNeighbors(from packet: Packet) -> [PeerID] {
        guard packet.type == .announce else { return [] }

        // Announcement payload is TLV-encoded. The neighbor list is at a known offset.
        // For now, scan for 8-byte aligned PeerID-sized chunks after the fixed fields.
        // A real implementation would use TLVEncoder.decode(), but we extract conservatively.
        let payload = packet.payload
        var neighbors: [PeerID] = []

        // Skip username (variable), noise key (32), signing key (32), capabilities (2), then neighbors.
        // The neighbor list starts after: username_len(1) + username(N) + 32 + 32 + 2 + avatar_hash(32)
        // We approximate by looking for the last section of 8-byte-aligned data.
        let minNeighborOffset = 99 // Minimum: 1 + 1(min username) + 32 + 32 + 2 + 32
        var offset = min(minNeighborOffset, payload.count)

        // Attempt to read up to 8 neighbor PeerIDs.
        while offset + PeerID.length <= payload.count && neighbors.count < 8 {
            if let peerID = PeerID(bytes: Data(payload[offset ..< offset + PeerID.length])) {
                neighbors.append(peerID)
            }
            offset += PeerID.length
        }

        return neighbors
    }

    // MARK: - Reset

    /// Reset all state (Bloom filters, metrics).
    public func reset() {
        bloomFilter.reset()
        sosBloomFilter.reset()
        storeForwardCache.clear()
        directedRouter.clearRoutes()

        lock.lock()
        packetsReceived = 0
        packetsRelayed = 0
        packetsDropped = 0
        lock.unlock()
    }
}
