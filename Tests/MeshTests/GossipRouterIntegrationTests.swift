import XCTest
@testable import BlipMesh
@testable import BlipProtocol

/// Integration tests for the gossip router: 10-node mesh simulation, Bloom dedup,
/// TTL decrement, and SOS always-relay override.
final class GossipRouterIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// A simulated mesh node with its own gossip router and peer identity.
    private final class SimulatedNode: GossipRouterDelegate, @unchecked Sendable {
        let peerID: PeerID
        let router: GossipRouter
        var neighbors: [PeerID: SimulatedNode] = [:]
        var receivedPackets: [Packet] = []
        var relayedPackets: [Packet] = []
        private let lock = NSLock()

        init(seed: UInt8) {
            self.peerID = PeerID(bytes: Data([seed, seed, seed, seed, seed, seed, seed, seed]))!
            self.router = GossipRouter(
                bloomFilter: MultiTierBloomFilter(),
                sosBloomFilter: MultiTierBloomFilter(),
                adaptiveRelay: AdaptiveRelay(),
                storeForwardCache: StoreForwardCache(),
                directedRouter: DirectedRouter()
            )
            self.router.delegate = self
        }

        /// Connect this node bidirectionally to another node.
        func connect(to other: SimulatedNode) {
            neighbors[other.peerID] = other
            other.neighbors[peerID] = self
        }

        /// Inject a packet into this node as if received from a given source.
        @discardableResult
        func injectPacket(_ packet: Packet, from source: PeerID) -> Bool {
            let isNew = router.handleIncoming(packet: packet, from: source)
            if isNew {
                lock.lock()
                receivedPackets.append(packet)
                lock.unlock()
            }
            return isNew
        }

        /// Propagate relayed packets to neighbors (simulating BLE mesh relay).
        /// Returns the total number of relay deliveries made.
        func drainRelayQueue() -> Int {
            lock.lock()
            let toRelay = relayedPackets
            relayedPackets.removeAll()
            lock.unlock()

            var deliveries = 0
            for (relayPacket, excludedPeer) in toRelay.map({ ($0, $0.senderID) }) {
                for (neighborID, neighbor) in neighbors {
                    // The delegate already excluded the source peer;
                    // in our simulation we just relay to all neighbors.
                    _ = neighbor.injectPacket(relayPacket, from: peerID)
                    deliveries += 1
                }
            }
            return deliveries
        }

        // MARK: - GossipRouterDelegate

        func gossipRouter(_ router: GossipRouter, shouldRelay packet: Packet, excluding excludedPeer: PeerID) {
            lock.lock()
            relayedPackets.append(packet)
            lock.unlock()
        }
    }

    /// Build a linear chain of nodes: 0 -- 1 -- 2 -- ... -- (count-1).
    private func buildLinearMesh(count: Int) -> [SimulatedNode] {
        let nodes = (0 ..< count).map { SimulatedNode(seed: UInt8($0 + 1)) }
        for i in 0 ..< count - 1 {
            nodes[i].connect(to: nodes[i + 1])
        }
        return nodes
    }

    /// Run relay propagation across the mesh until no more relays occur or
    /// a maximum number of rounds is reached.
    @discardableResult
    private func propagate(_ nodes: [SimulatedNode], maxRounds: Int = 20) -> Int {
        var totalDeliveries = 0
        for _ in 0 ..< maxRounds {
            var roundDeliveries = 0
            for node in nodes {
                roundDeliveries += node.drainRelayQueue()
            }
            totalDeliveries += roundDeliveries
            if roundDeliveries == 0 { break }
        }
        return totalDeliveries
    }

    /// Create a test packet originating from a specific node.
    private func makePacket(
        from sender: SimulatedNode,
        type: MessageType = .meshBroadcast,
        ttl: UInt8 = 5,
        flags: PacketFlags = .broadcastSigned,
        payload: Data = Data([0xDE, 0xAD]),
        signature: Data? = nil
    ) -> Packet {
        Packet(
            type: type,
            ttl: ttl,
            timestamp: Packet.currentTimestamp(),
            flags: flags,
            senderID: sender.peerID,
            payload: payload,
            signature: signature ?? Data(repeating: 0xAA, count: 64)
        )
    }

    // MARK: - Test: Message Delivery via Gossip

    func testMessageDeliveryAcross10NodeMesh() {
        let nodes = buildLinearMesh(count: 10)

        // Node 0 originates a broadcast with TTL 7.
        let packet = makePacket(from: nodes[0], ttl: 7)

        // Inject into node 0 as if originating locally.
        nodes[0].router.bloomFilter.insert(nodes[0].router.packetIdentifier(for: packet))
        // Then relay to node 1.
        nodes[1].injectPacket(packet, from: nodes[0].peerID)

        // Propagate through the mesh.
        propagate(nodes)

        // Verify all 10 nodes received the packet (node 0 originated it, node 1-9 via gossip).
        // Node 0 did not formally "receive" it through handleIncoming (it originated it).
        for i in 1 ..< 10 {
            let received = nodes[i].receivedPackets.contains { p in
                p.senderID == nodes[0].peerID && p.payload == packet.payload
            }
            XCTAssertTrue(received, "Node \(i) should have received the message from node 0")
        }
    }

    // MARK: - Test: Bloom Filter Deduplication Prevents Loops

    func testBloomFilterPreventsLoops() {
        // Create a ring topology: 0-1-2-3-4-0 (potential for infinite loops).
        let nodes = (0 ..< 5).map { SimulatedNode(seed: UInt8($0 + 1)) }
        for i in 0 ..< 5 {
            nodes[i].connect(to: nodes[(i + 1) % 5])
        }

        let packet = makePacket(from: nodes[0], ttl: 7)

        // Inject the packet into node 1.
        nodes[0].router.bloomFilter.insert(nodes[0].router.packetIdentifier(for: packet))
        nodes[1].injectPacket(packet, from: nodes[0].peerID)

        // Propagate. In a ring without dedup, this would loop forever.
        let totalDeliveries = propagate(nodes, maxRounds: 30)

        // Verify each node received the packet exactly once.
        for i in 1 ..< 5 {
            let count = nodes[i].receivedPackets.filter { $0.senderID == nodes[0].peerID }.count
            XCTAssertEqual(count, 1, "Node \(i) should receive the packet exactly once, got \(count)")
        }

        // Verify no excessive relay traffic (the ring should stop after one pass).
        // With 5 nodes in a ring, we expect at most ~8-10 total relay deliveries (some duplicates rejected).
        XCTAssertLessThan(totalDeliveries, 20, "Bloom filter should prevent excessive relaying")
    }

    func testDuplicatePacketIsDropped() {
        let node = SimulatedNode(seed: 0x01)
        let packet = makePacket(from: SimulatedNode(seed: 0x02), ttl: 5)
        let source = PeerID(bytes: Data(repeating: 0x02, count: 8))!

        // First reception: new.
        let first = node.injectPacket(packet, from: source)
        XCTAssertTrue(first, "First reception should be new")

        // Second reception: duplicate.
        let second = node.injectPacket(packet, from: source)
        XCTAssertFalse(second, "Second reception should be duplicate")

        XCTAssertEqual(node.receivedPackets.count, 1)
        XCTAssertEqual(node.router.packetsDropped, 1)
    }

    // MARK: - Test: TTL Decrement

    func testTTLDecrementsOnRelay() {
        let nodes = buildLinearMesh(count: 4)

        let packet = makePacket(from: nodes[0], ttl: 3)

        // Inject at node 1.
        nodes[1].injectPacket(packet, from: nodes[0].peerID)

        // After one relay, TTL should be decremented.
        nodes[1].drainRelayQueue()

        // Node 2 should see TTL = 2.
        let atNode2 = nodes[2].receivedPackets.first { $0.senderID == nodes[0].peerID }
        XCTAssertNotNil(atNode2)
        XCTAssertEqual(atNode2?.ttl, 2, "TTL should be decremented from 3 to 2 at node 2")

        // Continue propagation.
        propagate(nodes)

        // Node 3 should see TTL = 1.
        let atNode3 = nodes[3].receivedPackets.first { $0.senderID == nodes[0].peerID }
        XCTAssertNotNil(atNode3)
        XCTAssertEqual(atNode3?.ttl, 1, "TTL should be 1 at node 3")
    }

    func testTTLZeroStopsRelay() {
        let nodes = buildLinearMesh(count: 3)

        let packet = makePacket(from: nodes[0], ttl: 1)

        // Inject at node 1. TTL=1, will be decremented to 0.
        nodes[1].injectPacket(packet, from: nodes[0].peerID)

        // Node 1 should accept it (new) and relay it.
        propagate(nodes)

        // Node 2 should receive it (TTL=0), but it should NOT be relayed further.
        // Because the router decrements before relaying, TTL=1 becomes TTL=0 at node 2.
        let atNode2 = nodes[2].receivedPackets.first { $0.senderID == nodes[0].peerID }
        XCTAssertNotNil(atNode2, "Node 2 should still receive the packet even with TTL=0")
        XCTAssertEqual(atNode2?.ttl, 0)
    }

    func testTTLExpirationPreventsDeliveryBeyondRange() {
        let nodes = buildLinearMesh(count: 10)

        // Send with TTL=2. Should only reach nodes within 2 hops.
        let packet = makePacket(from: nodes[0], ttl: 2)
        nodes[1].injectPacket(packet, from: nodes[0].peerID)
        propagate(nodes)

        // Nodes 1, 2, and 3 should receive it (within TTL range).
        XCTAssertTrue(nodes[1].receivedPackets.contains { $0.senderID == nodes[0].peerID })
        XCTAssertTrue(nodes[2].receivedPackets.contains { $0.senderID == nodes[0].peerID })

        // Node 4+ may or may not receive it depending on relay probability.
        // But nodes far beyond TTL range should definitely not.
        let node8Received = nodes[8].receivedPackets.contains { $0.senderID == nodes[0].peerID }
        let node9Received = nodes[9].receivedPackets.contains { $0.senderID == nodes[0].peerID }
        XCTAssertFalse(node8Received, "Node 8 should be unreachable with TTL=2")
        XCTAssertFalse(node9Received, "Node 9 should be unreachable with TTL=2")
    }

    // MARK: - Test: SOS Always-Relay Override

    func testSOSAlwaysRelayed() {
        let nodes = buildLinearMesh(count: 5)

        // Set high congestion on all nodes to make normal relay probability low.
        for node in nodes {
            node.router.adaptiveRelay.queueFillRatio = 0.95
            node.router.adaptiveRelay.connectedPeerCount = 100
        }

        // Send an SOS alert.
        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: nodes[0].peerID,
            payload: Data([0x03, 0x67, 0x65, 0x6F]), // severity=red + geohash prefix
            signature: Data(repeating: 0xFF, count: 64)
        )

        nodes[0].router.sosBloomFilter.insert(nodes[0].router.packetIdentifier(for: sosPacket))
        nodes[1].injectPacket(sosPacket, from: nodes[0].peerID)
        propagate(nodes)

        // All nodes should have received the SOS despite high congestion.
        for i in 1 ..< 5 {
            let received = nodes[i].receivedPackets.contains { $0.type == .sosAlert }
            XCTAssertTrue(received, "Node \(i) must receive SOS alert regardless of congestion")
        }
    }

    func testSOSSkipsTTLReductionForFirst3Hops() {
        let nodes = buildLinearMesh(count: 6)

        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: nodes[0].peerID,
            payload: Data([0x03]),
            signature: Data(repeating: 0xEE, count: 64)
        )

        nodes[0].router.sosBloomFilter.insert(nodes[0].router.packetIdentifier(for: sosPacket))
        nodes[1].injectPacket(sosPacket, from: nodes[0].peerID)

        // Propagate step by step to observe TTL at each node.
        nodes[1].drainRelayQueue()

        // At node 2: SOS with TTL=7, first hop -- TTL should remain 7 (>4 rule).
        let atNode2 = nodes[2].receivedPackets.first { $0.type == .sosAlert }
        XCTAssertNotNil(atNode2)
        // TTL 7 at node 1 -> relay to node 2 as TTL 7 (skip reduction since ttl > 4).
        XCTAssertEqual(atNode2?.ttl, 7, "SOS should preserve TTL for first hops")

        propagate(nodes)

        // The SOS should reach all remaining nodes.
        for i in 2 ..< 6 {
            let received = nodes[i].receivedPackets.contains { $0.type == .sosAlert }
            XCTAssertTrue(received, "Node \(i) should receive SOS")
        }
    }

    func testSOSUseSeparateBloomFilter() {
        let node = SimulatedNode(seed: 0x01)
        let source = PeerID(bytes: Data(repeating: 0x02, count: 8))!

        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: source,
            payload: Data([0x01]),
            signature: Data(repeating: 0xBB, count: 64)
        )

        let normalPacket = Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: .broadcastSigned,
            senderID: source,
            payload: Data([0x02]),
            signature: Data(repeating: 0xCC, count: 64)
        )

        // Insert SOS into the router.
        node.injectPacket(sosPacket, from: source)

        // The normal Bloom filter should NOT contain the SOS packet ID.
        let sosID = node.router.packetIdentifier(for: sosPacket)
        let normalContains = node.router.bloomFilter.contains(sosID)
        let sosContains = node.router.sosBloomFilter.contains(sosID)

        // SOS should be in the SOS filter.
        XCTAssertTrue(sosContains, "SOS packet should be in the SOS Bloom filter")

        // Insert a normal packet.
        node.injectPacket(normalPacket, from: source)
        let normalID = node.router.packetIdentifier(for: normalPacket)
        XCTAssertTrue(node.router.bloomFilter.contains(normalID), "Normal packet should be in the normal Bloom filter")
        XCTAssertFalse(node.router.sosBloomFilter.contains(normalID), "Normal packet should NOT be in the SOS Bloom filter")
    }

    // MARK: - Test: Metrics

    func testRouterMetrics() {
        let node = SimulatedNode(seed: 0x01)
        let source = PeerID(bytes: Data(repeating: 0x02, count: 8))!

        XCTAssertEqual(node.router.packetsReceived, 0)
        XCTAssertEqual(node.router.packetsRelayed, 0)
        XCTAssertEqual(node.router.packetsDropped, 0)

        let packet = Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: .broadcastSigned,
            senderID: source,
            payload: Data([0x01]),
            signature: Data(repeating: 0xAA, count: 64)
        )

        node.injectPacket(packet, from: source)
        XCTAssertEqual(node.router.packetsReceived, 1)

        // Duplicate.
        node.injectPacket(packet, from: source)
        XCTAssertEqual(node.router.packetsReceived, 2)
        XCTAssertEqual(node.router.packetsDropped, 1)
    }

    // MARK: - Test: Reset

    func testRouterReset() {
        let node = SimulatedNode(seed: 0x01)
        let source = PeerID(bytes: Data(repeating: 0x02, count: 8))!

        let packet = Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: [],
            senderID: source,
            payload: Data([0xAA])
        )

        node.injectPacket(packet, from: source)
        XCTAssertGreaterThan(node.router.packetsReceived, 0)

        node.router.reset()

        XCTAssertEqual(node.router.packetsReceived, 0)
        XCTAssertEqual(node.router.packetsRelayed, 0)
        XCTAssertEqual(node.router.packetsDropped, 0)

        // After reset, the same packet should be treated as new.
        let isNew = node.router.handleIncoming(packet: packet, from: source)
        XCTAssertTrue(isNew, "After reset, packet should be treated as new")
    }
}
