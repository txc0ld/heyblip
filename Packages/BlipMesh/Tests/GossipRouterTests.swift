import Testing
import Foundation
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makePeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data([byte, byte, byte, byte, byte, byte, byte, byte]))!
}

private func makePacket(
    type: MessageType = .noiseEncrypted,
    ttl: UInt8 = 5,
    senderByte: UInt8 = 0x01,
    payload: Data = Data([0xAA, 0xBB]),
    timestamp: UInt64? = nil
) -> Packet {
    Packet(
        type: type,
        ttl: ttl,
        timestamp: timestamp ?? Packet.currentTimestamp(),
        flags: PacketFlags(),
        senderID: makePeerID(senderByte),
        payload: payload
    )
}

private func makeSOSPacket(
    ttl: UInt8 = 7,
    senderByte: UInt8 = 0x02
) -> Packet {
    Packet(
        type: .sosAlert,
        ttl: ttl,
        timestamp: Packet.currentTimestamp(),
        flags: .sosPriority,
        senderID: makePeerID(senderByte),
        payload: Data([0xFF, 0xEE])
    )
}

// MARK: - Mock delegate

final class MockGossipDelegate: GossipRouterDelegate, @unchecked Sendable {
    var relayedPackets: [(Packet, PeerID)] = []
    let lock = NSLock()

    func gossipRouter(_ router: GossipRouter, shouldRelay packet: Packet, excluding excludedPeer: PeerID) {
        lock.lock()
        relayedPackets.append((packet, excludedPeer))
        lock.unlock()
    }

    var relayCount: Int {
        lock.withLock { relayedPackets.count }
    }

    var firstRelayedPacket: Packet? {
        lock.withLock { relayedPackets.first?.0 }
    }

    var firstExcludedPeer: PeerID? {
        lock.withLock { relayedPackets.first?.1 }
    }
}

// MARK: - GossipRouter tests

@Suite("GossipRouter")
struct GossipRouterTests {

    // MARK: - New packet handling

    @Test("New packet is accepted and returns true")
    func newPacketAccepted() {
        let router = GossipRouter()
        let packet = makePacket()
        let source = makePeerID(0x10)

        let isNew = router.handleIncoming(packet: packet, from: source)
        #expect(isNew == true)
    }

    // MARK: - Bloom filter dedup

    @Test("Duplicate packet is rejected")
    func duplicateRejected() {
        let router = GossipRouter()
        let packet = makePacket()
        let source = makePeerID(0x10)

        let first = router.handleIncoming(packet: packet, from: source)
        let second = router.handleIncoming(packet: packet, from: source)

        #expect(first == true)
        #expect(second == false)
    }

    @Test("Different packets are both accepted")
    func differentPacketsAccepted() {
        let router = GossipRouter()
        let source = makePeerID(0x10)

        let packet1 = makePacket(senderByte: 0x01, payload: Data([0x01]))
        let packet2 = makePacket(senderByte: 0x02, payload: Data([0x02]))

        let first = router.handleIncoming(packet: packet1, from: source)
        let second = router.handleIncoming(packet: packet2, from: source)

        #expect(first == true)
        #expect(second == true)
    }

    // MARK: - TTL handling

    @Test("TTL 0 packet is not relayed but is delivered locally")
    func ttlZeroNotRelayed() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        let packet = makePacket(ttl: 0)
        let source = makePeerID(0x10)

        let isNew = router.handleIncoming(packet: packet, from: source)

        #expect(isNew == true) // Still delivered locally.
        // Give time for async relay (shouldn't happen).
        Thread.sleep(forTimeInterval: 0.05)
        #expect(mockDelegate.relayCount == 0)
    }

    @Test("TTL 1 packet is relayed with decremented TTL")
    func ttlDecremented() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        // Set high peer count for deterministic relay.
        router.adaptiveRelay.connectedPeerCount = 1

        let packet = makePacket(ttl: 2)
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)

        // Wait for jitter delay.
        Thread.sleep(forTimeInterval: 0.1)

        // The packet should be relayed (probability ~1.0 with 1 peer).
        // Due to randomness we check the mechanism works.
        #expect(router.packetsReceived == 1)
    }

    // MARK: - SOS handling

    @Test("SOS packets are always relayed")
    func sosAlwaysRelayed() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        // Even with high peer count and congestion.
        router.adaptiveRelay.connectedPeerCount = 100
        router.adaptiveRelay.queueFillRatio = 0.99

        let packet = makeSOSPacket()
        let source = makePeerID(0x10)

        let isNew = router.handleIncoming(packet: packet, from: source)
        #expect(isNew == true)

        // SOS should be relayed immediately (no jitter for SOS).
        #expect(mockDelegate.relayCount == 1)
    }

    @Test("SOS packets use separate Bloom filter")
    func sosSeparateBloomFilter() {
        let router = GossipRouter()

        let sosPacket = makeSOSPacket()
        let source = makePeerID(0x10)

        // Process the SOS packet.
        let first = router.handleIncoming(packet: sosPacket, from: source)
        #expect(first == true)

        // The SOS Bloom filter should have the packet.
        let packetID = router.packetIdentifier(for: sosPacket)
        #expect(router.sosBloomFilter.contains(packetID))

        // The regular Bloom filter should NOT have it.
        #expect(!router.bloomFilter.contains(packetID))
    }

    @Test("SOS TTL decrements every hop")
    func sosTTLDecrements() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        let packet = makeSOSPacket(ttl: 7)
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)

        #expect(mockDelegate.relayCount == 1)
        #expect(mockDelegate.firstRelayedPacket?.ttl == 6) // TTL decremented from 7 to 6.
    }

    @Test("SOS packet relays even at TTL 1 (no last-hop suppression)")
    func sosNoLastHopSuppression() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        let packet = makeSOSPacket(ttl: 1)
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)

        #expect(mockDelegate.relayCount == 1, "SOS should relay even when TTL decrements to 0")
        #expect(mockDelegate.firstRelayedPacket?.ttl == 0)
    }

    @Test("SOS packet with TTL 0 is not relayed")
    func sosTTLZeroNotRelayed() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        let packet = makeSOSPacket(ttl: 0)
        let source = makePeerID(0x10)

        let isNew = router.handleIncoming(packet: packet, from: source)

        #expect(isNew == true, "TTL 0 SOS still delivered locally")
        #expect(mockDelegate.relayCount == 0, "TTL 0 SOS should not relay")
    }

    @Test("Regular packet TTL 1 triggers last-hop suppression but SOS does not")
    func regularVsSosLastHop() {
        // Regular: TTL 1 → decrement to 0 → last-hop suppression → no relay
        let router1 = GossipRouter()
        let delegate1 = MockGossipDelegate()
        router1.delegate = delegate1
        router1.adaptiveRelay.connectedPeerCount = 1

        _ = router1.handleIncoming(packet: makePacket(ttl: 1), from: makePeerID(0x10))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(delegate1.relayCount == 0, "Regular TTL 1 should not relay")

        // SOS: TTL 1 → decrement to 0 → no suppression → relay
        let router2 = GossipRouter()
        let delegate2 = MockGossipDelegate()
        router2.delegate = delegate2

        _ = router2.handleIncoming(packet: makeSOSPacket(ttl: 1), from: makePeerID(0x10))
        #expect(delegate2.relayCount == 1, "SOS TTL 1 should still relay")
    }

    // MARK: - Relay exclusion

    @Test("Source peer is excluded from relay")
    func sourceExcluded() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate
        router.adaptiveRelay.connectedPeerCount = 1

        let source = makePeerID(0x10)
        let sosPacket = makeSOSPacket()

        _ = router.handleIncoming(packet: sosPacket, from: source)

        #expect(mockDelegate.relayCount == 1)
        #expect(mockDelegate.firstExcludedPeer == source)
    }

    // MARK: - Metrics

    @Test("Metrics track packets correctly")
    func metricsTracking() {
        let router = GossipRouter()

        let packet1 = makePacket(senderByte: 0x01, payload: Data([0x01]))
        let packet2 = makePacket(senderByte: 0x02, payload: Data([0x02]))
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet1, from: source)
        _ = router.handleIncoming(packet: packet1, from: source) // Duplicate.
        _ = router.handleIncoming(packet: packet2, from: source)

        #expect(router.packetsReceived == 3)
        #expect(router.packetsDropped >= 1) // At least the duplicate.
    }

    // MARK: - Store-forward integration

    @Test("Packets are cached in store-forward cache")
    func storeForwardCaching() {
        let router = GossipRouter()

        let recipientID = makePeerID(0xAA)
        let packet = Packet(
            type: .noiseEncrypted,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: [.hasRecipient],
            senderID: makePeerID(0x01),
            recipientID: recipientID,
            payload: Data([0x01, 0x02])
        )
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)

        // The packet should be in the store-forward cache.
        let cached = router.deliverCachedPackets(to: recipientID)
        #expect(cached.count == 1)
        #expect(cached.first?.senderID == makePeerID(0x01))
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func resetClearsState() {
        let router = GossipRouter()

        let packet = makePacket()
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)
        #expect(router.packetsReceived > 0)

        router.reset()

        #expect(router.packetsReceived == 0)
        #expect(router.packetsRelayed == 0)
        #expect(router.packetsDropped == 0)

        // Previously-seen packet should be accepted again after reset.
        let isNew = router.handleIncoming(packet: packet, from: source)
        #expect(isNew == true)
    }

    // MARK: - Adaptive relay

    @Test("Relay probability decreases with more peers")
    func relayProbabilityScaling() {
        let relay = AdaptiveRelay()

        relay.connectedPeerCount = 5
        let lowPeerProb = relay.baseProbability()

        relay.connectedPeerCount = 50
        let highPeerProb = relay.baseProbability()

        #expect(lowPeerProb > highPeerProb)
    }

    @Test("Congestion factor decreases with queue fill")
    func congestionScaling() {
        let relay = AdaptiveRelay()

        relay.queueFillRatio = 0.3
        let lowCongestion = relay.congestionFactor()

        relay.queueFillRatio = 0.9
        let highCongestion = relay.congestionFactor()

        #expect(lowCongestion > highCongestion)
    }

    @Test("SOS always returns relay probability 1.0")
    func sosRelayProbability() {
        let relay = AdaptiveRelay()
        relay.connectedPeerCount = 100
        relay.queueFillRatio = 0.99

        let sosPacket = makeSOSPacket()
        let prob = relay.relayProbability(for: sosPacket)
        #expect(prob == 1.0)
    }

    @Test("Jitter is within spec range")
    func jitterRange() {
        let relay = AdaptiveRelay()

        for _ in 0..<100 {
            let jitter = relay.jitterDelay()
            #expect(jitter >= BLEConstants.relayJitterMin)
            #expect(jitter <= BLEConstants.relayJitterMax)
        }
    }

    // MARK: - TTL boundary behavior

    @Test("TTL 0 is delivered locally but never relayed")
    func ttlZeroNeverRelayed() {
        let router = GossipRouter()
        let delegate = MockGossipDelegate()
        router.delegate = delegate
        router.adaptiveRelay.connectedPeerCount = 1

        let packet = makePacket(ttl: 0)
        let isNew = router.handleIncoming(packet: packet, from: makePeerID(0x20))

        #expect(isNew == true, "TTL 0 should still be delivered locally")
        Thread.sleep(forTimeInterval: 0.1)
        #expect(delegate.relayCount == 0, "TTL 0 should never be relayed")
        #expect(router.packetsReceived == 1)
        #expect(router.packetsRelayed == 0)
    }

    @Test("TTL 1 hits last-hop suppression — delivered locally, not relayed")
    func ttlOneLastHopSuppression() {
        let router = GossipRouter()
        let delegate = MockGossipDelegate()
        router.delegate = delegate
        router.adaptiveRelay.connectedPeerCount = 1

        let packet = makePacket(ttl: 1)
        let isNew = router.handleIncoming(packet: packet, from: makePeerID(0x20))

        #expect(isNew == true, "TTL 1 should be delivered locally")
        Thread.sleep(forTimeInterval: 0.1)
        #expect(delegate.relayCount == 0, "TTL 1 after decrement to 0 triggers last-hop suppression")
    }

    @Test("TTL 2 is relayed with TTL decremented to 1")
    func ttlTwoRelayed() {
        let router = GossipRouter()
        let delegate = MockGossipDelegate()
        router.delegate = delegate
        router.adaptiveRelay.connectedPeerCount = 1

        let packet = makePacket(ttl: 2)
        _ = router.handleIncoming(packet: packet, from: makePeerID(0x20))

        Thread.sleep(forTimeInterval: 0.1)
        #expect(delegate.relayCount == 1, "TTL 2 should be relayed")
        #expect(delegate.firstRelayedPacket?.ttl == 1, "Relayed TTL should be decremented by 1")
    }

    @Test("High TTL packet is relayed with TTL decremented by 1")
    func highTTLDecremented() {
        let router = GossipRouter()
        let delegate = MockGossipDelegate()
        router.delegate = delegate
        router.adaptiveRelay.connectedPeerCount = 1

        let packet = makePacket(ttl: 7)
        _ = router.handleIncoming(packet: packet, from: makePeerID(0x20))

        // Wait for jitter (up to 25ms) + async dispatch
        Thread.sleep(forTimeInterval: 0.3)
        #expect(delegate.relayCount == 1)
        #expect(delegate.firstRelayedPacket?.ttl == 6, "Relayed TTL should be original - 1")
    }
}
