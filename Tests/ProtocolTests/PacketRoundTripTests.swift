import XCTest
@testable import BlipProtocol

/// Round-trip serialization tests for every message type, fragmentation, compression, and padding.
final class PacketRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Create a deterministic PeerID from a seed byte.
    private func makePeerID(_ seed: UInt8) -> PeerID {
        PeerID(bytes: Data([seed, seed, seed, seed, seed, seed, seed, seed]))!
    }

    /// Create a test packet with the given type and flags.
    private func makePacket(
        type: MessageType,
        flags: PacketFlags = [],
        payload: Data = Data([0xDE, 0xAD]),
        ttl: UInt8 = 5,
        recipientID: PeerID? = nil,
        signature: Data? = nil
    ) -> Packet {
        Packet(
            version: Packet.currentVersion,
            type: type,
            ttl: ttl,
            timestamp: 1_711_584_000_000, // Fixed timestamp for deterministic tests
            flags: flags,
            senderID: makePeerID(0xAA),
            recipientID: recipientID,
            payload: payload,
            signature: signature
        )
    }

    /// Assert that encoding then decoding a packet produces an identical packet.
    private func assertRoundTrip(_ packet: Packet, file: StaticString = #file, line: UInt = #line) throws {
        let encoded = try PacketSerializer.encode(packet)
        let decoded = try PacketSerializer.decode(encoded)

        XCTAssertEqual(decoded.version, packet.version, "Version mismatch", file: file, line: line)
        XCTAssertEqual(decoded.type, packet.type, "Type mismatch", file: file, line: line)
        XCTAssertEqual(decoded.ttl, packet.ttl, "TTL mismatch", file: file, line: line)
        XCTAssertEqual(decoded.timestamp, packet.timestamp, "Timestamp mismatch", file: file, line: line)
        XCTAssertEqual(decoded.flags, packet.flags, "Flags mismatch", file: file, line: line)
        XCTAssertEqual(decoded.senderID, packet.senderID, "Sender ID mismatch", file: file, line: line)
        XCTAssertEqual(decoded.recipientID, packet.recipientID, "Recipient ID mismatch", file: file, line: line)
        XCTAssertEqual(decoded.payload, packet.payload, "Payload mismatch", file: file, line: line)
        XCTAssertEqual(decoded.signature, packet.signature, "Signature mismatch", file: file, line: line)
    }

    // MARK: - Per-Type Round-Trip Tests

    func testAnnounceRoundTrip() throws {
        let packet = makePacket(type: .announce, flags: .broadcastSigned, payload: Data(repeating: 0x11, count: 100), signature: Data(repeating: 0xCC, count: 64))
        try assertRoundTrip(packet)
    }

    func testMeshBroadcastRoundTrip() throws {
        let packet = makePacket(type: .meshBroadcast, flags: .broadcastSigned, payload: "Hello mesh!".data(using: .utf8)!, signature: Data(repeating: 0xBB, count: 64))
        try assertRoundTrip(packet)
    }

    func testLeaveRoundTrip() throws {
        let packet = makePacket(type: .leave, payload: Data())
        try assertRoundTrip(packet)
    }

    func testNoiseHandshakeRoundTrip() throws {
        let packet = makePacket(type: .noiseHandshake, flags: [.hasRecipient], payload: Data(repeating: 0x42, count: 32), recipientID: makePeerID(0xBB))
        try assertRoundTrip(packet)
    }

    func testNoiseEncryptedRoundTrip() throws {
        let packet = makePacket(type: .noiseEncrypted, flags: .addressedSignedReliable, payload: Data(repeating: 0x99, count: 200), recipientID: makePeerID(0xCC), signature: Data(repeating: 0xAA, count: 64))
        try assertRoundTrip(packet)
    }

    func testFragmentRoundTrip() throws {
        let packet = makePacket(type: .fragment, payload: Data(repeating: 0x55, count: 300))
        try assertRoundTrip(packet)
    }

    func testSyncRequestRoundTrip() throws {
        let packet = makePacket(type: .syncRequest, payload: Data(repeating: 0x77, count: 50))
        try assertRoundTrip(packet)
    }

    func testFileTransferRoundTrip() throws {
        let packet = makePacket(type: .fileTransfer, flags: [.hasRecipient], payload: Data(repeating: 0xEE, count: 400), recipientID: makePeerID(0xDD))
        try assertRoundTrip(packet)
    }

    func testPttAudioRoundTrip() throws {
        let packet = makePacket(type: .pttAudio, flags: [.hasRecipient], payload: Data(repeating: 0x01, count: 160), recipientID: makePeerID(0x11))
        try assertRoundTrip(packet)
    }

    func testOrgAnnouncementRoundTrip() throws {
        let packet = makePacket(type: .orgAnnouncement, flags: [.hasSignature, .isPriority], payload: "Schedule change!".data(using: .utf8)!, signature: Data(repeating: 0x33, count: 64))
        try assertRoundTrip(packet)
    }

    func testChannelUpdateRoundTrip() throws {
        let packet = makePacket(type: .channelUpdate, payload: Data([0x01, 0x02, 0x03]))
        try assertRoundTrip(packet)
    }

    func testSOSAlertRoundTrip() throws {
        let packet = makePacket(type: .sosAlert, flags: .sosPriority, payload: Data([0x03, 0x67, 0x65, 0x6F, 0x68, 0x61, 0x73, 0x68]), ttl: 7, signature: Data(repeating: 0xFF, count: 64))
        try assertRoundTrip(packet)
    }

    func testSOSAcceptRoundTrip() throws {
        let packet = makePacket(type: .sosAccept, flags: .sosPriority, payload: Data(repeating: 0x44, count: 36), ttl: 7, signature: Data(repeating: 0xEE, count: 64))
        try assertRoundTrip(packet)
    }

    func testSOSPreciseLocationRoundTrip() throws {
        let packet = makePacket(type: .sosPreciseLocation, flags: [.hasRecipient, .hasSignature, .isPriority], payload: Data(repeating: 0x66, count: 16), recipientID: makePeerID(0xAA), signature: Data(repeating: 0xDD, count: 64))
        try assertRoundTrip(packet)
    }

    func testSOSResolveRoundTrip() throws {
        let packet = makePacket(type: .sosResolve, flags: .sosPriority, payload: Data(repeating: 0x88, count: 36), signature: Data(repeating: 0x11, count: 64))
        try assertRoundTrip(packet)
    }

    func testSOSNearbyAssistRoundTrip() throws {
        let packet = makePacket(type: .sosNearbyAssist, flags: [.hasSignature, .isPriority], payload: Data([0x01]), signature: Data(repeating: 0x22, count: 64))
        try assertRoundTrip(packet)
    }

    func testLocationShareRoundTrip() throws {
        let packet = makePacket(type: .locationShare, flags: [.hasRecipient], payload: Data(repeating: 0x50, count: 48), recipientID: makePeerID(0xEE))
        try assertRoundTrip(packet)
    }

    func testLocationRequestRoundTrip() throws {
        let packet = makePacket(type: .locationRequest, flags: [.hasRecipient], payload: Data(), recipientID: makePeerID(0xFF))
        try assertRoundTrip(packet)
    }

    func testProximityPingRoundTrip() throws {
        let packet = makePacket(type: .proximityPing, payload: Data([0x52]))
        try assertRoundTrip(packet)
    }

    func testIAmHereBeaconRoundTrip() throws {
        let packet = makePacket(type: .iAmHereBeacon, payload: "Main Stage".data(using: .utf8)!)
        try assertRoundTrip(packet)
    }

    // MARK: - All Types Exhaustive

    func testAllMessageTypesRoundTrip() throws {
        for messageType in MessageType.allCases {
            var flags: PacketFlags = []
            var recipientID: PeerID?
            var signature: Data?

            // Add appropriate flags per type
            if messageType == .noiseEncrypted || messageType == .locationShare {
                flags.insert(.hasRecipient)
                recipientID = makePeerID(0xBB)
            }
            if messageType == .meshBroadcast || messageType.isSOS || messageType == .orgAnnouncement {
                flags.insert(.hasSignature)
                signature = Data(repeating: 0xAA, count: 64)
            }

            let packet = Packet(
                type: messageType,
                ttl: 5,
                timestamp: 1_711_584_000_000,
                flags: flags,
                senderID: makePeerID(0x01),
                recipientID: recipientID,
                payload: Data(repeating: messageType.rawValue, count: 10),
                signature: signature
            )

            try assertRoundTrip(packet)
        }
    }

    // MARK: - Fragmentation Round-Trip

    func testFragmentationAndReassembly() throws {
        // Create a payload larger than the fragmentation threshold.
        let largePayload = Data((0 ..< 2000).map { UInt8($0 % 256) })
        XCTAssertTrue(FragmentSplitter.needsFragmentation(largePayload))

        // Split into fragments.
        let fragments = FragmentSplitter.split(largePayload)
        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(
            FragmentSplitter.fragmentCount(for: largePayload.count),
            fragments.count
        )

        // Verify each fragment has consistent metadata.
        let expectedTotal = UInt16(fragments.count)
        let fragmentID = fragments[0].fragmentID
        for (i, fragment) in fragments.enumerated() {
            XCTAssertEqual(fragment.fragmentID, fragmentID)
            XCTAssertEqual(fragment.index, UInt16(i))
            XCTAssertEqual(fragment.total, expectedTotal)
        }

        // Serialize and parse each fragment.
        let assembler = FragmentAssembler()
        var reassembled: Data?

        for fragment in fragments {
            let serialized = fragment.serialize()
            guard let parsed = Fragment.parse(serialized) else {
                XCTFail("Failed to parse serialized fragment \(fragment.index)")
                return
            }

            XCTAssertEqual(parsed.fragmentID, fragment.fragmentID)
            XCTAssertEqual(parsed.index, fragment.index)
            XCTAssertEqual(parsed.total, fragment.total)
            XCTAssertEqual(parsed.data, fragment.data)

            let result = try assembler.receive(parsed)
            switch result {
            case .complete(let data):
                reassembled = data
            case .incomplete(let received, let total):
                XCTAssertEqual(received, Int(fragment.index) + 1)
                XCTAssertEqual(total, Int(expectedTotal))
            }
        }

        // Verify reassembled payload matches original.
        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled, largePayload)
    }

    func testSingleFragmentRoundTrip() throws {
        // A small payload that fits in one fragment.
        let smallPayload = Data(repeating: 0xAB, count: 100)
        XCTAssertFalse(FragmentSplitter.needsFragmentation(smallPayload))

        let fragments = FragmentSplitter.split(smallPayload)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].index, 0)
        XCTAssertEqual(fragments[0].total, 1)
        XCTAssertEqual(fragments[0].data, smallPayload)

        // Serialize, parse, and reassemble.
        let serialized = fragments[0].serialize()
        let parsed = Fragment.parse(serialized)!
        let assembler = FragmentAssembler()
        let result = try assembler.receive(parsed)

        if case .complete(let data) = result {
            XCTAssertEqual(data, smallPayload)
        } else {
            XCTFail("Expected complete assembly for single-fragment payload")
        }
    }

    func testFragmentOutOfOrderAssembly() throws {
        let payload = Data((0 ..< 1500).map { UInt8($0 % 256) })
        let fragments = FragmentSplitter.split(payload)
        XCTAssertGreaterThan(fragments.count, 1)

        // Feed fragments in reverse order.
        let assembler = FragmentAssembler()
        var reassembled: Data?

        for fragment in fragments.reversed() {
            let result = try assembler.receive(fragment)
            if case .complete(let data) = result {
                reassembled = data
            }
        }

        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled, payload)
    }

    // MARK: - Compression + Padding Round-Trip

    func testCompressionRoundTrip_SmallPayload() {
        // < 100 bytes: no compression applied.
        let small = Data(repeating: 0x41, count: 50)
        let result = PayloadCompressor.compressIfNeeded(small)
        XCTAssertFalse(result.wasCompressed)
        XCTAssertEqual(result.data, small)
    }

    func testCompressionRoundTrip_MediumPayload() throws {
        // 100-256 bytes: compress if result is smaller.
        // Repetitive data compresses well.
        let medium = Data(repeating: 0x42, count: 200)
        let result = PayloadCompressor.compressIfNeeded(medium)

        if result.wasCompressed {
            XCTAssertLessThan(result.data.count, medium.count)
            let decompressed = try PayloadCompressor.decompress(result.data)
            XCTAssertEqual(decompressed, medium)
        } else {
            // Compression did not improve size; original is preserved.
            XCTAssertEqual(result.data, medium)
        }
    }

    func testCompressionRoundTrip_LargePayload() throws {
        // > 256 bytes: always compressed.
        let large = Data(repeating: 0x43, count: 1000)
        let result = PayloadCompressor.compressIfNeeded(large)
        XCTAssertTrue(result.wasCompressed)

        let decompressed = try PayloadCompressor.decompress(result.data)
        XCTAssertEqual(decompressed, large)
    }

    func testCompressionRoundTrip_PreCompressed() {
        // Pre-compressed data should be skipped.
        let opus = Data(repeating: 0xFF, count: 500)
        let result = PayloadCompressor.compressIfNeeded(opus, isPreCompressed: true)
        XCTAssertFalse(result.wasCompressed)
        XCTAssertEqual(result.data, opus)
    }

    func testCompressionRoundTrip_VariedContent() throws {
        // Varied (non-repetitive) content > 256 bytes.
        var varied = Data()
        for i in 0 ..< 500 {
            varied.append(UInt8(i % 256))
        }
        let result = PayloadCompressor.compressIfNeeded(varied)
        XCTAssertTrue(result.wasCompressed)

        let decompressed = try PayloadCompressor.decompress(result.data)
        XCTAssertEqual(decompressed, varied)
    }

    // MARK: - Padding Round-Trip

    func testPaddingRoundTrip_SmallData() {
        let data = Data(repeating: 0x01, count: 50)
        let padded = PacketPadding.pad(data)

        // Should be padded to 256 (nearest block boundary).
        XCTAssertEqual(padded.count, 256)
        XCTAssertGreaterThan(padded.count, data.count)

        let unpadded = PacketPadding.unpad(padded)
        XCTAssertNotNil(unpadded)
        XCTAssertEqual(unpadded, data)
    }

    func testPaddingRoundTrip_BlockBoundary() {
        // Data just below a block boundary.
        let data = Data(repeating: 0x02, count: 255)
        let padded = PacketPadding.pad(data)
        XCTAssertEqual(padded.count, 256)

        let unpadded = PacketPadding.unpad(padded)
        XCTAssertNotNil(unpadded)
        XCTAssertEqual(unpadded, data)
    }

    func testPaddingRoundTrip_MediumData() {
        let data = Data(repeating: 0x03, count: 300)
        let padded = PacketPadding.pad(data)

        // Should be padded to 512 (next block boundary).
        XCTAssertEqual(padded.count, 512)

        let unpadded = PacketPadding.unpad(padded)
        XCTAssertNotNil(unpadded)
        XCTAssertEqual(unpadded, data)
    }

    func testPaddingRoundTrip_LargeData() {
        let data = Data(repeating: 0x04, count: 1500)
        let padded = PacketPadding.pad(data)

        // Should be padded to 1792 or 2048 depending on block size rules.
        XCTAssertGreaterThan(padded.count, data.count)
        XCTAssertEqual(padded.count % 256, 0, "Padded size should be a multiple of a block boundary")

        let unpadded = PacketPadding.unpad(padded)
        XCTAssertNotNil(unpadded)
        XCTAssertEqual(unpadded, data)
    }

    func testPaddingRoundTrip_AllBlockSizes() {
        // Test data sizes that exercise each block tier.
        let sizes = [1, 10, 100, 200, 255, 300, 500, 700, 1000, 1500, 2000, 2500, 3000]

        for size in sizes {
            let data = Data((0 ..< size).map { UInt8($0 % 256) })
            let padded = PacketPadding.pad(data)
            XCTAssertGreaterThan(padded.count, data.count, "Padding must add at least 1 byte for size \(size)")

            let unpadded = PacketPadding.unpad(padded)
            XCTAssertNotNil(unpadded, "Unpadding failed for size \(size)")
            XCTAssertEqual(unpadded, data, "Data mismatch after pad/unpad for size \(size)")
        }
    }

    // MARK: - Combined Compression + Padding Round-Trip

    func testCompressionThenPaddingRoundTrip() throws {
        let original = Data(repeating: 0x61, count: 400) // 'a' repeated, compresses well

        // Step 1: Compress.
        let compressed = PayloadCompressor.compressIfNeeded(original)
        XCTAssertTrue(compressed.wasCompressed)

        // Step 2: Pad.
        let padded = PacketPadding.pad(compressed.data)
        XCTAssertGreaterThanOrEqual(padded.count, compressed.data.count)

        // Step 3: Unpad.
        let unpadded = PacketPadding.unpad(padded)
        XCTAssertNotNil(unpadded)
        XCTAssertEqual(unpadded, compressed.data)

        // Step 4: Decompress.
        let decompressed = try PayloadCompressor.decompress(unpadded!)
        XCTAssertEqual(decompressed, original)
    }

    // MARK: - Edge Cases

    func testEmptyPayloadRoundTrip() throws {
        let packet = makePacket(type: .leave, payload: Data())
        try assertRoundTrip(packet)
    }

    func testMaxTTLRoundTrip() throws {
        let packet = makePacket(type: .sosAlert, flags: .sosPriority, ttl: 7, signature: Data(repeating: 0xAA, count: 64))
        try assertRoundTrip(packet)
    }

    func testZeroTTLRoundTrip() throws {
        let packet = makePacket(type: .meshBroadcast, ttl: 0)
        try assertRoundTrip(packet)
    }

    func testBroadcastRecipientRoundTrip() throws {
        let packet = makePacket(
            type: .meshBroadcast,
            flags: [.hasRecipient],
            payload: Data([0x01]),
            recipientID: PeerID.broadcast
        )
        try assertRoundTrip(packet)
        XCTAssertTrue(packet.recipientID!.isBroadcast)
    }

    func testDecodeRejectsTruncatedData() {
        let tooShort = Data(repeating: 0x00, count: 10)
        XCTAssertThrowsError(try PacketSerializer.decode(tooShort)) { error in
            guard case PacketSerializerError.dataTooShort = error else {
                XCTFail("Expected dataTooShort error, got \(error)")
                return
            }
        }
    }

    func testDecodeRejectsUnknownType() {
        // Build a 16-byte header with an invalid type byte.
        var data = Data(repeating: 0x00, count: Packet.headerSize + PeerID.length)
        data[0] = 0x01 // version
        data[1] = 0xFE // invalid type
        data[2] = 3    // TTL

        XCTAssertThrowsError(try PacketSerializer.decode(data)) { error in
            guard case PacketSerializerError.unknownMessageType = error else {
                XCTFail("Expected unknownMessageType error, got \(error)")
                return
            }
        }
    }
}
