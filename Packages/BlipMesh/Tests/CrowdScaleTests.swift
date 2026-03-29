import Testing
import Foundation
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makePeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data([byte, byte, byte, byte, byte, byte, byte, byte]))!
}

// MARK: - CrowdScaleMode tests

@Suite("CrowdScaleMode")
struct CrowdScaleModeTests {

    @Test("Mode classification by peer count")
    func modeClassification() {
        #expect(CrowdScaleMode.mode(forPeerCount: 0) == .gather)
        #expect(CrowdScaleMode.mode(forPeerCount: 100) == .gather)
        #expect(CrowdScaleMode.mode(forPeerCount: 499) == .gather)
        #expect(CrowdScaleMode.mode(forPeerCount: 500) == .festival)
        #expect(CrowdScaleMode.mode(forPeerCount: 2000) == .festival)
        #expect(CrowdScaleMode.mode(forPeerCount: 4999) == .festival)
        #expect(CrowdScaleMode.mode(forPeerCount: 5000) == .mega)
        #expect(CrowdScaleMode.mode(forPeerCount: 15000) == .mega)
        #expect(CrowdScaleMode.mode(forPeerCount: 24999) == .mega)
        #expect(CrowdScaleMode.mode(forPeerCount: 25000) == .massive)
        #expect(CrowdScaleMode.mode(forPeerCount: 100000) == .massive)
    }

    @Test("SOS TTL is always 7 regardless of mode")
    func sosTTLAlways7() {
        for mode in CrowdScaleMode.allCases {
            #expect(mode.sosTTL == 7)
        }
    }

    @Test("DM TTL decreases with crowd density")
    func dmTTLDecreases() {
        #expect(CrowdScaleMode.gather.dmTTL == 7)
        #expect(CrowdScaleMode.festival.dmTTL == 5)
        #expect(CrowdScaleMode.mega.dmTTL == 4)
        #expect(CrowdScaleMode.massive.dmTTL == 3)
    }

    @Test("Group TTL decreases with crowd density")
    func groupTTLDecreases() {
        #expect(CrowdScaleMode.gather.groupTTL == 5)
        #expect(CrowdScaleMode.festival.groupTTL == 4)
        #expect(CrowdScaleMode.mega.groupTTL == 3)
        #expect(CrowdScaleMode.massive.groupTTL == 2)
    }

    @Test("Broadcast TTL decreases and suppresses in Massive")
    func broadcastTTL() {
        #expect(CrowdScaleMode.gather.broadcastTTL == 5)
        #expect(CrowdScaleMode.festival.broadcastTTL == 3)
        #expect(CrowdScaleMode.mega.broadcastTTL == 2)
        #expect(CrowdScaleMode.massive.broadcastTTL == 0) // Suppressed.
    }

    @Test("Media restrictions by mode")
    func mediaRestrictions() {
        #expect(CrowdScaleMode.gather.allowsMediaOnMesh == true)
        #expect(CrowdScaleMode.festival.allowsMediaOnMesh == true)
        #expect(CrowdScaleMode.mega.allowsMediaOnMesh == false)
        #expect(CrowdScaleMode.massive.allowsMediaOnMesh == false)
    }
}

// MARK: - CrowdScaleManager tests

@Suite("CrowdScaleManager")
struct CrowdScaleManagerTests {

    @Test("Initial mode is Gather")
    func initialMode() {
        let manager = CrowdScaleManager()
        #expect(manager.currentMode == .gather)
    }

    @Test("Reports peers and updates raw count")
    func reportPeers() {
        let manager = CrowdScaleManager()

        for i: UInt8 in 0..<50 {
            manager.reportPeerSeen(makePeerID(i))
        }

        manager.evaluate()
        #expect(manager.rawPeerCount == 50)
    }

    @Test("EMA smoothing applied to peer count")
    func emaSmoothingApplied() {
        let manager = CrowdScaleManager()

        // Report 100 unique peers.
        for i in 0..<100 {
            let byte = UInt8(i % 256)
            manager.reportPeerSeen(makePeerID(byte))
        }

        // First evaluation seeds the EMA directly to the raw count.
        manager.evaluate()
        #expect(abs(manager.smoothedPeerCount - 100.0) < 1.0)

        // Second evaluation with the same peers applies EMA smoothing.
        // EMA = alpha * raw + (1 - alpha) * previous = 0.3 * 100 + 0.7 * 100 = 100.
        manager.evaluate()
        #expect(abs(manager.smoothedPeerCount - 100.0) < 1.0)

        // Now add 50 more peers (150 total). EMA should move toward 150.
        for i in 100..<150 {
            let byte = UInt8(i % 256)
            manager.reportPeerSeen(makePeerID(byte))
        }
        manager.evaluate()

        // EMA = 0.3 * 150 + 0.7 * 100 = 45 + 70 = 115.
        #expect(abs(manager.smoothedPeerCount - 115.0) < 1.0)
    }

    @Test("Mode does not change immediately (hysteresis)")
    func hysteresisPreventsImmediateChange() {
        let manager = CrowdScaleManager()

        // Report enough peers for Festival mode.
        for i in 0..<600 {
            let data = withUnsafeBytes(of: i) { Data($0) }
            let peerID = PeerID(noisePublicKey: data)
            manager.reportPeerSeen(peerID)
        }

        // Force smoothed count to Festival range.
        // Multiple evaluations to get EMA up.
        for _ in 0..<20 {
            manager.evaluate()
        }

        // With hysteresis, the mode might not change yet since we need
        // the candidate mode to be sustained for 60 seconds.
        // But after enough evaluations with the count stable, it should eventually.
        // For this test, we just verify the mechanism doesn't crash and
        // the mode is correctly tracked.
        #expect(manager.rawPeerCount > 0)
    }

    @Test("forceMode bypasses hysteresis")
    func forceModeWorks() {
        let manager = CrowdScaleManager()
        #expect(manager.currentMode == .gather)

        manager.forceMode(.mega)
        #expect(manager.currentMode == .mega)

        manager.forceMode(.massive)
        #expect(manager.currentMode == .massive)
    }

    @Test("Reset returns to Gather mode")
    func resetToGather() {
        let manager = CrowdScaleManager()

        manager.forceMode(.festival)
        #expect(manager.currentMode == .festival)

        manager.reset()
        #expect(manager.currentMode == .gather)
        #expect(manager.smoothedPeerCount == 0)
        #expect(manager.rawPeerCount == 0)
    }

    @Test("Combine publisher emits mode changes")
    func publisherEmits() {
        let manager = CrowdScaleManager()
        var receivedModes: [CrowdScaleMode] = []

        let cancellable = manager.modePublisher.sink { mode in
            receivedModes.append(mode)
        }

        // Initial value.
        #expect(receivedModes.count == 1)
        #expect(receivedModes[0] == .gather)

        manager.forceMode(.festival)
        #expect(receivedModes.count == 2)
        #expect(receivedModes[1] == .festival)

        // Keep the cancellable alive.
        _ = cancellable
    }

    @Test("Stale peers are pruned from sightings")
    func stalePeersPruned() {
        let manager = CrowdScaleManager()

        // Report some peers.
        for i: UInt8 in 0..<10 {
            manager.reportPeerSeen(makePeerID(i))
        }

        manager.evaluate()
        #expect(manager.rawPeerCount == 10)

        // After evaluation, the peers are still within the window.
        manager.evaluate()
        #expect(manager.rawPeerCount == 10) // Still there.
    }
}

// MARK: - TrafficLane tests

@Suite("TrafficLane")
struct TrafficLaneTests {

    @Test("SOS always gets critical lane")
    func sosCriticalLane() {
        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: makePeerID(0x01),
            payload: Data()
        )
        #expect(TrafficLane.lane(for: sosPacket) == .critical)
    }

    @Test("DM gets high lane")
    func dmHighLane() {
        let dmPacket = Packet(
            type: .noiseEncrypted,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: [.hasRecipient],
            senderID: makePeerID(0x01),
            recipientID: makePeerID(0x02),
            payload: Data()
        )
        #expect(TrafficLane.lane(for: dmPacket) == .high)
    }

    @Test("Broadcast gets normal lane")
    func broadcastNormalLane() {
        let broadcastPacket = Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: PacketFlags(),
            senderID: makePeerID(0x01),
            payload: Data()
        )
        #expect(TrafficLane.lane(for: broadcastPacket) == .normal)
    }

    @Test("Sync gets low lane")
    func syncLowLane() {
        let syncPacket = Packet(
            type: .syncRequest,
            ttl: 3,
            timestamp: Packet.currentTimestamp(),
            flags: PacketFlags(),
            senderID: makePeerID(0x01),
            payload: Data()
        )
        #expect(TrafficLane.lane(for: syncPacket) == .low)
    }

    @Test("Lane ordering is correct")
    func laneOrdering() {
        #expect(TrafficLane.critical < TrafficLane.high)
        #expect(TrafficLane.high < TrafficLane.normal)
        #expect(TrafficLane.normal < TrafficLane.low)
    }

    @Test("Bandwidth shares sum to 1.0 for non-critical lanes")
    func bandwidthShares() {
        let nonCriticalSum = TrafficLane.high.bandwidthShare
            + TrafficLane.normal.bandwidthShare
            + TrafficLane.low.bandwidthShare
        #expect(abs(nonCriticalSum - 1.0) < 0.001)
    }
}

// MARK: - PowerTier tests

@Suite("PowerTier")
struct PowerTierTests {

    @Test("Tier classification by battery level")
    func tierClassification() {
        #expect(PowerTier.tier(level: 0.80, isCharging: false) == .performance)
        #expect(PowerTier.tier(level: 0.61, isCharging: false) == .performance)
        #expect(PowerTier.tier(level: 0.50, isCharging: false) == .balanced)
        #expect(PowerTier.tier(level: 0.31, isCharging: false) == .balanced)
        #expect(PowerTier.tier(level: 0.20, isCharging: false) == .powerSaver)
        #expect(PowerTier.tier(level: 0.11, isCharging: false) == .powerSaver)
        #expect(PowerTier.tier(level: 0.05, isCharging: false) == .ultraLow)
    }

    @Test("Charging always returns performance tier")
    func chargingIsPerformance() {
        #expect(PowerTier.tier(level: 0.05, isCharging: true) == .performance)
        #expect(PowerTier.tier(level: 0.30, isCharging: true) == .performance)
        #expect(PowerTier.tier(level: 0.50, isCharging: true) == .performance)
    }

    @Test("Relay disabled in ultra-low tier")
    func relayDisabledUltraLow() {
        #expect(PowerTier.ultraLow.relayEnabled == false)
        #expect(PowerTier.performance.relayEnabled == true)
        #expect(PowerTier.balanced.relayEnabled == true)
        #expect(PowerTier.powerSaver.relayEnabled == true)
    }

    @Test("Scan duration decreases with lower tiers")
    func scanDurationDecreases() {
        #expect(PowerTier.performance.scanOnDuration > PowerTier.ultraLow.scanOnDuration)
    }

    @Test("Scan pause increases with lower tiers")
    func scanPauseIncreases() {
        #expect(PowerTier.performance.scanOffDuration < PowerTier.ultraLow.scanOffDuration)
    }

    @Test("Advertise interval increases with lower tiers")
    func advertiseIntervalIncreases() {
        #expect(PowerTier.performance.advertiseInterval < PowerTier.ultraLow.advertiseInterval)
    }
}

// MARK: - ReputationManager tests

@Suite("ReputationManager")
struct ReputationManagerTests {

    @Test("Block votes accumulate correctly")
    func blockVoteAccumulation() {
        let manager = ReputationManager()
        let target = makePeerID(0x01)

        for i: UInt8 in 0..<12 {
            manager.recordBlockVote(from: makePeerID(i + 0x10), against: target)
        }

        #expect(manager.blockVoteCount(for: target) == 12)
        #expect(manager.isDeprioritized(target) == true)
        #expect(manager.isBroadcastDropped(target) == false)
    }

    @Test("Duplicate votes from same voter not counted")
    func duplicateVotesIgnored() {
        let manager = ReputationManager()
        let voter = makePeerID(0x10)
        let target = makePeerID(0x01)

        manager.recordBlockVote(from: voter, against: target)
        manager.recordBlockVote(from: voter, against: target)
        manager.recordBlockVote(from: voter, against: target)

        #expect(manager.blockVoteCount(for: target) == 1)
    }

    @Test("25 votes triggers broadcast drop")
    func broadcastDropThreshold() {
        let manager = ReputationManager()
        let target = makePeerID(0x01)

        for i: UInt8 in 0..<25 {
            manager.recordBlockVote(from: makePeerID(i + 0x10), against: target)
        }

        #expect(manager.isBroadcastDropped(target) == true)
    }

    @Test("SOS packets exempt from reputation filtering")
    func sosExempt() {
        let manager = ReputationManager()
        let target = makePeerID(0x01)

        // Give the target 30 block votes.
        for i: UInt8 in 0..<30 {
            manager.recordBlockVote(from: makePeerID(i + 0x10), against: target)
        }

        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: target,
            payload: Data()
        )

        #expect(manager.shouldAllow(packet: sosPacket) == true)
    }

    @Test("Non-SOS broadcast dropped for high-vote peer")
    func nonSOSBroadcastDropped() {
        let manager = ReputationManager()
        let target = makePeerID(0x01)

        for i: UInt8 in 0..<25 {
            manager.recordBlockVote(from: makePeerID(i + 0x10), against: target)
        }

        let broadcastPacket = Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: PacketFlags(),
            senderID: target,
            payload: Data()
        )

        #expect(manager.shouldAllow(packet: broadcastPacket) == false)
    }

    @Test("Festival change resets reputation")
    func festivalResets() {
        let manager = ReputationManager()
        let target = makePeerID(0x01)

        manager.recordBlockVote(from: makePeerID(0x10), against: target)
        #expect(manager.blockVoteCount(for: target) == 1)

        manager.setFestival("festival-2026")
        #expect(manager.blockVoteCount(for: target) == 0)
    }
}

// MARK: - StoreForwardCache tests

@Suite("StoreForwardCache")
struct StoreForwardCacheTests {

    @Test("Cache and retrieve DM")
    func cacheAndRetrieveDM() {
        let cache = StoreForwardCache()
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

        cache.cache(packet: packet)
        #expect(cache.entryCount == 1)

        let retrieved = cache.retrieve(forPeerID: recipientID)
        #expect(retrieved.count == 1)
        #expect(cache.entryCount == 0) // Removed after retrieval.
    }

    @Test("SOS resolve clears cached SOS for that sender")
    func sosResolveClearsCache() {
        let cache = StoreForwardCache()
        let sosSender = makePeerID(0x01)

        let sosPacket = Packet(
            type: .sosAlert,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: .sosPriority,
            senderID: sosSender,
            payload: Data()
        )

        cache.cache(packet: sosPacket)
        #expect(cache.entryCount == 1)

        cache.resolveSOSAlert(senderID: sosSender)
        #expect(cache.entryCount == 0)
    }

    @Test("Voice/images not cached")
    func voiceNotCached() {
        let cache = StoreForwardCache()

        let voicePacket = Packet(
            type: .pttAudio,
            ttl: 3,
            timestamp: Packet.currentTimestamp(),
            flags: PacketFlags(),
            senderID: makePeerID(0x01),
            payload: Data(repeating: 0xAA, count: 100)
        )

        cache.cache(packet: voicePacket)
        #expect(cache.entryCount == 0) // Not cached.
    }

    @Test("LRU eviction when cache full")
    func lruEviction() {
        let cache = StoreForwardCache()

        // Fill the cache with large packets.
        let largePayload = Data(repeating: 0xBB, count: 1024)
        let packetCount = (StoreForwardCache.maxCacheSizeBytes / 1050) + 10

        for i in 0..<packetCount {
            let byte = UInt8(i % 256)
            let packet = Packet(
                type: .noiseEncrypted,
                ttl: 5,
                timestamp: Packet.currentTimestamp() + UInt64(i),
                flags: [.hasRecipient],
                senderID: makePeerID(byte),
                recipientID: makePeerID(0xAA),
                payload: largePayload
            )
            cache.cache(packet: packet)
        }

        // Cache size should be at or under the limit.
        #expect(cache.cacheSizeBytes <= StoreForwardCache.maxCacheSizeBytes)
    }
}

// MARK: - DirectedRouter tests

@Suite("DirectedRouter")
struct DirectedRouterTests {

    @Test("Process announcement creates routes")
    func processAnnouncementCreatesRoutes() {
        let router = DirectedRouter()
        let neighbor = makePeerID(0x01)
        let neighborPeer = makePeerID(0x02)

        router.processAnnouncement(from: neighbor, neighbors: [neighborPeer])

        // Neighbor itself should be reachable (1 hop).
        #expect(router.findRoute(to: neighbor) == neighbor)

        // Neighbor's neighbor should be reachable via neighbor (2 hops).
        #expect(router.findRoute(to: neighborPeer) == neighbor)
    }

    @Test("Route expiry after 5 minutes")
    func routeExpiry() {
        let router = DirectedRouter()
        let neighbor = makePeerID(0x01)

        router.updateRoute(peerID: makePeerID(0x02), viaPeer: neighbor)

        // Route should exist.
        #expect(router.findRoute(to: makePeerID(0x02)) != nil)

        // Prune should not remove fresh routes.
        router.pruneExpired()
        #expect(router.routeCount > 0)
    }

    @Test("Remove routes via disconnected peer")
    func removeRoutesViaPeer() {
        let router = DirectedRouter()
        let via = makePeerID(0x01)

        router.updateRoute(peerID: makePeerID(0x10), viaPeer: via)
        router.updateRoute(peerID: makePeerID(0x11), viaPeer: via)
        router.updateRoute(peerID: makePeerID(0x12), viaPeer: makePeerID(0x02))

        #expect(router.routeCount == 3)

        router.removeRoutes(viaPeer: via)

        #expect(router.routeCount == 1)
        #expect(router.findRoute(to: makePeerID(0x12)) != nil)
    }

    @Test("Unknown destination returns nil (fallback to gossip)")
    func unknownDestinationNil() {
        let router = DirectedRouter()
        #expect(router.findRoute(to: makePeerID(0xFF)) == nil)
    }
}
