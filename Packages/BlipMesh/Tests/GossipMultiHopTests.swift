import Testing
import Foundation
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makePeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data([byte, byte, byte, byte, byte, byte, byte, byte]))!
}

/// Default type is `.noiseEncrypted` (urgencyFactor 1.0) for deterministic relay in chain tests.
private func makePacket(
    type: MessageType = .noiseEncrypted,
    ttl: UInt8 = 5,
    senderByte: UInt8 = 0x01,
    payload: Data = Data([0xAA, 0xBB]),
    timestamp: UInt64? = nil,
    flags: PacketFlags = PacketFlags(),
    recipientID: PeerID? = nil
) -> Packet {
    Packet(
        type: type,
        ttl: ttl,
        timestamp: timestamp ?? Packet.currentTimestamp(),
        flags: flags,
        senderID: makePeerID(senderByte),
        recipientID: recipientID,
        payload: payload
    )
}

private func makeSOSPacket(
    ttl: UInt8 = 7,
    senderByte: UInt8 = 0x02,
    payload: Data = Data([0xFF, 0xEE])
) -> Packet {
    Packet(
        type: .sosAlert,
        ttl: ttl,
        timestamp: Packet.currentTimestamp(),
        flags: .sosPriority,
        senderID: makePeerID(senderByte),
        payload: payload
    )
}

// MARK: - Mock Chain Delegate

/// Connects GossipRouter nodes: when one relays, feed the packet into downstream routers.
private final class MockChainDelegate: GossipRouterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var forwards: [(router: GossipRouter, asPeer: PeerID)] = []
    private var _relayedPackets: [Packet] = []

    var relayedPackets: [Packet] {
        lock.withLock { _relayedPackets }
    }

    var relayCount: Int {
        lock.withLock { _relayedPackets.count }
    }

    func addForward(to router: GossipRouter, asPeer peer: PeerID) {
        lock.withLock { forwards.append((router, peer)) }
    }

    func gossipRouter(_ router: GossipRouter, shouldRelay packet: Packet, excluding excludedPeer: PeerID) {
        lock.lock()
        _relayedPackets.append(packet)
        let fwds = forwards
        lock.unlock()

        for fwd in fwds {
            fwd.router.handleIncoming(packet: packet, from: fwd.asPeer)
        }
    }
}

// MARK: - Chain Node & Builder

private struct ChainNode {
    let peerID: PeerID
    let router: GossipRouter
    let delegate: MockChainDelegate
}

/// Build a linear chain of GossipRouter nodes wired in sequence.
/// When `deterministicRelay` is true, sets connectedPeerCount=1 so relay probability ≈ 1.0.
private func buildLinearChain(count: Int, deterministicRelay: Bool = true) -> [ChainNode] {
    var nodes: [ChainNode] = []
    for i in 0..<count {
        let peerID = makePeerID(UInt8(0x10 + i))
        let router = GossipRouter()
        let delegate = MockChainDelegate()
        router.delegate = delegate
        if deterministicRelay {
            router.adaptiveRelay.connectedPeerCount = 1
        }
        nodes.append(ChainNode(peerID: peerID, router: router, delegate: delegate))
    }
    for i in 0..<(count - 1) {
        nodes[i].delegate.addForward(to: nodes[i + 1].router, asPeer: nodes[i].peerID)
    }
    return nodes
}

// MARK: - Test Suite

@Suite("GossipRouter Multi-Hop Integration")
struct GossipMultiHopTests {

    // MARK: 1 — Linear chain delivery (5 hops)

    @Test("Packet propagates through a 5-node linear chain")
    func linearChainDelivery() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let packet = makePacket(ttl: 5)

        nodes[0].router.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 1.0)

        for (i, node) in nodes.enumerated() {
            #expect(node.router.packetsReceived == 1,
                    "Node \(i) should have received the packet")
        }
        for i in 0..<4 {
            #expect(nodes[i].delegate.relayCount == 1,
                    "Node \(i) should have relayed the packet")
        }
    }

    // MARK: 2 — Bloom filter dedup across chain

    @Test("Duplicate packet is stopped at the first node — no chain propagation")
    func bloomFilterDedupAcrossChain() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let packet = makePacket(ttl: 5)

        let first = nodes[0].router.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 1.0)
        let relaySnapshot = nodes.map { $0.delegate.relayCount }

        let second = nodes[0].router.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 0.5)

        #expect(first == true)
        #expect(second == false)
        for (i, node) in nodes.enumerated() {
            #expect(node.delegate.relayCount == relaySnapshot[i],
                    "Node \(i) should not relay the duplicate")
        }
    }

    // MARK: 3 — TTL exhaustion

    @Test("TTL=3 packet reaches nodes 0-2 but not nodes 3 or 4")
    func ttlExhaustion() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let packet = makePacket(ttl: 3)

        nodes[0].router.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 1.0)

        #expect(nodes[0].router.packetsReceived == 1)
        #expect(nodes[1].router.packetsReceived == 1)
        #expect(nodes[2].router.packetsReceived == 1)
        #expect(nodes[3].router.packetsReceived == 0, "TTL expired before node 3")
        #expect(nodes[4].router.packetsReceived == 0, "TTL expired before node 4")
    }

    // MARK: 4 — SOS priority relay through chain

    @Test("SOS packet reaches all 5 nodes, TTL decrements, uses SOS Bloom filter")
    func sosPriorityRelay() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let sos = makeSOSPacket(ttl: 7)

        nodes[0].router.handleIncoming(packet: sos, from: source)
        // SOS relay is synchronous (no jitter).
        Thread.sleep(forTimeInterval: 0.05)

        // (a) All nodes receive.
        for (i, node) in nodes.enumerated() {
            #expect(node.router.packetsReceived == 1,
                    "Node \(i) should receive the SOS")
        }

        // (b) TTL decrements each hop (BDEV-107 fix: was previously preserved indefinitely).
        for i in 0..<4 {
            let relayed = nodes[i].delegate.relayedPackets
            #expect(relayed.count == 1)
            let expectedTTL = UInt8(7 - (i + 1))
            #expect(relayed[0].ttl == expectedTTL,
                    "Node \(i) should relay with TTL \(expectedTTL)")
        }

        // (c) SOS Bloom filter used; normal Bloom filter untouched.
        let packetID = nodes[0].router.packetIdentifier(for: sos)
        for (i, node) in nodes.enumerated() {
            #expect(node.router.sosBloomFilter.contains(packetID),
                    "Node \(i) SOS Bloom should contain packet")
            #expect(!node.router.bloomFilter.contains(packetID),
                    "Node \(i) normal Bloom should NOT contain SOS packet")
        }
    }

    // MARK: 5 — SOS vs normal dedup isolation

    @Test("Normal and SOS packets with identical payloads propagate independently")
    func sosVsNormalDedupIsolation() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let ts = Packet.currentTimestamp()

        let normalPacket = makePacket(
            type: .noiseEncrypted, ttl: 5, senderByte: 0x01,
            payload: payload, timestamp: ts
        )
        let sosPacket = Packet(
            type: .sosAlert, ttl: 7, timestamp: ts,
            flags: .sosPriority, senderID: makePeerID(0x01), payload: payload
        )

        let normalOK = nodes[0].router.handleIncoming(packet: normalPacket, from: source)
        let sosOK = nodes[0].router.handleIncoming(packet: sosPacket, from: source)
        Thread.sleep(forTimeInterval: 1.0)

        #expect(normalOK == true)
        #expect(sosOK == true)

        for (i, node) in nodes.enumerated() {
            #expect(node.router.packetsReceived == 2,
                    "Node \(i) should receive both packets")
        }

        // Bloom filter isolation at first node.
        let normalID = nodes[0].router.packetIdentifier(for: normalPacket)
        let sosID = nodes[0].router.packetIdentifier(for: sosPacket)
        #expect(nodes[0].router.bloomFilter.contains(normalID))
        #expect(!nodes[0].router.bloomFilter.contains(sosID))
        #expect(nodes[0].router.sosBloomFilter.contains(sosID))
        #expect(!nodes[0].router.sosBloomFilter.contains(normalID))
    }

    // MARK: 6 — Store-and-forward for offline peer

    @Test("DM packet is cached in store-forward at intermediate nodes")
    func storeAndForwardForOfflinePeer() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let recipientID = makePeerID(0xAA)

        let dm = Packet(
            type: .noiseEncrypted, ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: [.hasRecipient],
            senderID: makePeerID(0x01),
            recipientID: recipientID,
            payload: Data([0x01, 0x02, 0x03])
        )

        nodes[0].router.handleIncoming(packet: dm, from: source)
        Thread.sleep(forTimeInterval: 1.0)

        // Node 2 (middle of chain) should have the packet cached for the recipient.
        let cached = nodes[2].router.deliverCachedPackets(to: recipientID)
        #expect(cached.count >= 1, "Store-forward cache at node 2 should hold the DM")
        #expect(cached.first?.senderID == makePeerID(0x01))
    }

    // MARK: 7 — Branching topology (diamond)

    @Test("Diamond topology: convergence node receives packet exactly once")
    func diamondTopology() {
        let peerA = makePeerID(0x10)
        let peerB = makePeerID(0x11)
        let peerC = makePeerID(0x12)

        let routerA = GossipRouter()
        let routerB = GossipRouter()
        let routerC = GossipRouter()
        let routerD = GossipRouter()

        let delA = MockChainDelegate()
        let delB = MockChainDelegate()
        let delC = MockChainDelegate()
        let delD = MockChainDelegate()

        routerA.delegate = delA
        routerB.delegate = delB
        routerC.delegate = delC
        routerD.delegate = delD

        for r in [routerA, routerB, routerC, routerD] {
            r.adaptiveRelay.connectedPeerCount = 1
        }

        // A -> B, A -> C
        delA.addForward(to: routerB, asPeer: peerA)
        delA.addForward(to: routerC, asPeer: peerA)
        // B -> D, C -> D
        delB.addForward(to: routerD, asPeer: peerB)
        delC.addForward(to: routerD, asPeer: peerC)

        // Use SOS packet for synchronous relay — avoids jitter-based race at convergence node.
        let source = makePeerID(0x01)
        let packet = makeSOSPacket(ttl: 7, senderByte: 0x05)

        routerA.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 0.05)

        #expect(routerB.packetsReceived == 1, "B receives")
        #expect(routerC.packetsReceived == 1, "C receives")

        // D's handleIncoming is called twice (from B and C), so packetsReceived == 2.
        // But the second call is rejected by the Bloom filter (packetsDropped == 1).
        // Net new packets accepted = received - dropped == 1.
        #expect(routerD.packetsReceived == 2, "D receives from both paths")
        #expect(routerD.packetsDropped == 1, "D deduplicates the second arrival")
        #expect(delD.relayCount == 1, "D relays the packet exactly once")
    }

    // MARK: 8 — Adaptive relay under congestion

    @Test("Congestion significantly reduces normal throughput; SOS is unaffected")
    func adaptiveRelayUnderCongestion() {
        // Clean chain: connectedPeerCount=1, probability ~1.0 for .noiseEncrypted.
        let clean = buildLinearChain(count: 5)

        // Congested chain: intermediate nodes throttled.
        let congested = buildLinearChain(count: 5, deterministicRelay: false)
        congested[0].router.adaptiveRelay.connectedPeerCount = 1
        for i in 1..<4 {
            congested[i].router.adaptiveRelay.connectedPeerCount = 50
            congested[i].router.adaptiveRelay.queueFillRatio = 0.95
        }

        let source = makePeerID(0x01)

        // Send 100 unique packets through both chains.
        for i in 0..<100 {
            let pkt = makePacket(
                ttl: 5,
                senderByte: UInt8(3 + i),
                payload: Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)])
            )
            clean[0].router.handleIncoming(packet: pkt, from: source)
            congested[0].router.handleIncoming(packet: pkt, from: source)
        }
        Thread.sleep(forTimeInterval: 1.5)

        let cleanEnd = clean[4].router.packetsReceived
        let congestedEnd = congested[4].router.packetsReceived

        #expect(congestedEnd < cleanEnd,
                "Congested (\(congestedEnd)) should deliver fewer than clean (\(cleanEnd))")

        // SOS through a separate congested chain: 100% delivery expected.
        let sosCongested = buildLinearChain(count: 5, deterministicRelay: false)
        sosCongested[0].router.adaptiveRelay.connectedPeerCount = 1
        for i in 1..<4 {
            sosCongested[i].router.adaptiveRelay.connectedPeerCount = 50
            sosCongested[i].router.adaptiveRelay.queueFillRatio = 0.95
        }

        let sosCount = 10
        for i in 0..<sosCount {
            let sos = makeSOSPacket(ttl: 7, senderByte: UInt8(50 + i))
            sosCongested[0].router.handleIncoming(packet: sos, from: source)
        }
        Thread.sleep(forTimeInterval: 0.15)

        #expect(sosCongested[4].router.packetsReceived == UInt64(sosCount),
                "All \(sosCount) SOS packets reach end despite congestion")
    }

    // MARK: 9 — Metrics accumulation across chain

    @Test("Metrics are consistent at every node after chain propagation")
    func metricsAccumulation() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)

        for i in 0..<5 {
            let pkt = makePacket(
                ttl: 5,
                senderByte: UInt8(i + 1),
                payload: Data([UInt8(i)])
            )
            nodes[0].router.handleIncoming(packet: pkt, from: source)
        }
        Thread.sleep(forTimeInterval: 1.5)

        #expect(nodes[0].router.packetsReceived == 5)

        for (i, node) in nodes.enumerated() {
            let r = node.router
            // Cannot relay more than received.
            #expect(r.packetsReceived >= r.packetsRelayed,
                    "Node \(i): received (\(r.packetsReceived)) >= relayed (\(r.packetsRelayed))")
            // Dropped + relayed <= received (remainder = local-only deliveries at TTL boundary).
            #expect(r.packetsDropped + r.packetsRelayed <= r.packetsReceived,
                    "Node \(i): dropped + relayed <= received")
        }
    }

    // MARK: 10 — Reset isolation

    @Test("Resetting one node allows it to re-accept packets; others still reject")
    func resetIsolation() {
        let nodes = buildLinearChain(count: 5)
        let source = makePeerID(0x01)
        let packet = makePacket(ttl: 5)

        nodes[0].router.handleIncoming(packet: packet, from: source)
        Thread.sleep(forTimeInterval: 1.0)

        for node in nodes {
            #expect(node.router.packetsReceived >= 1)
        }

        // Reset only node 2 (middle of chain).
        nodes[2].router.reset()

        // Node 2 should accept the previously-seen packet again.
        #expect(nodes[2].router.handleIncoming(packet: packet, from: source) == true,
                "Reset node accepts previously-seen packet")

        // All other nodes still reject it.
        #expect(nodes[0].router.handleIncoming(packet: packet, from: source) == false,
                "Non-reset node 0 still rejects")
        #expect(nodes[1].router.handleIncoming(packet: packet, from: source) == false,
                "Non-reset node 1 still rejects")
        #expect(nodes[3].router.handleIncoming(packet: packet, from: source) == false,
                "Non-reset node 3 still rejects")
        #expect(nodes[4].router.handleIncoming(packet: packet, from: source) == false,
                "Non-reset node 4 still rejects")
    }
}
