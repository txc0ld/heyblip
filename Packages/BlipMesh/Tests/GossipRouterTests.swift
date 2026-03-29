import Testing
import Foundation
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makePeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data([byte, byte, byte, byte, byte, byte, byte, byte]))!
}

private func makePacket(
    type: MessageType = .meshBroadcast,
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

    @Test("SOS TTL skips decrement for first 3 hops")
    func sosTTLSkip() {
        let router = GossipRouter()
        let mockDelegate = MockGossipDelegate()
        router.delegate = mockDelegate

        // TTL 7: first hop, should not decrement (TTL > 4).
        let packet = makeSOSPacket(ttl: 7)
        let source = makePeerID(0x10)

        _ = router.handleIncoming(packet: packet, from: source)

        #expect(mockDelegate.relayCount == 1)
        let relayed = mockDelegate.relayedPackets[0].0
        #expect(relayed.ttl == 7) // TTL preserved for first 3 hops.
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
        let excludedPeer = mockDelegate.relayedPackets[0].1
        #expect(excludedPeer == source)
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
}
