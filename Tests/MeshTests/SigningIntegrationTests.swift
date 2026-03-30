import XCTest
@testable import BlipCrypto
@testable import BlipProtocol

/// Integration tests for the Ed25519 signing layer wired into the message pipeline.
///
/// Tests the full cycle: sign → encode → decode → verify, matching how MessageService
/// sends and receives packets. Also tests relay compatibility (TTL change doesn't break sig)
/// and edge cases (unsigned packets, wrong key, tampered payload).
final class SigningIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeKeypair() -> (secretKey: Data, publicKey: Data) {
        let kp = Sodium().sign.keyPair()!
        return (Data(kp.secretKey), Data(kp.publicKey))
    }

    private func makePeerID(seed: UInt8) -> PeerID {
        PeerID(bytes: Data([seed, seed, seed, seed, seed, seed, seed, seed]))!
    }

    private func makePacket(
        type: MessageType = .noiseEncrypted,
        ttl: UInt8 = 5,
        sender: PeerID? = nil,
        recipientID: PeerID? = nil,
        payload: Data = Data("Hello mesh".utf8),
        flags: PacketFlags = []
    ) -> Packet {
        Packet(
            type: type,
            ttl: ttl,
            timestamp: Packet.currentTimestamp(),
            flags: flags,
            senderID: sender ?? makePeerID(seed: 0x01),
            recipientID: recipientID,
            payload: payload,
            signature: nil
        )
    }

    // MARK: - Test: Full sign → encode → decode → verify roundtrip

    func testSignEncodeDecodeVerifyRoundtrip() throws {
        let (secretKey, publicKey) = makeKeypair()
        let packet = makePacket()

        // Sign
        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        XCTAssertTrue(signed.flags.contains(.hasSignature))
        XCTAssertNotNil(signed.signature)
        XCTAssertEqual(signed.signature?.count, 64)

        // Encode to wire
        let wireData = try PacketSerializer.encode(signed)

        // Decode from wire
        let decoded = try PacketSerializer.decode(wireData)
        XCTAssertTrue(decoded.flags.contains(.hasSignature))
        XCTAssertNotNil(decoded.signature)

        // Verify
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertTrue(valid, "Signature should be valid after roundtrip")
    }

    // MARK: - Test: TTL change doesn't break signature (relay compatibility)

    func testRelayTTLDecrementPreservesSignature() throws {
        let (secretKey, publicKey) = makeKeypair()
        let packet = makePacket(ttl: 7)

        // Sign at origin
        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let wireData = try PacketSerializer.encode(signed)

        // Simulate relay: decode, decrement TTL, re-encode
        var relayed = try PacketSerializer.decode(wireData)
        XCTAssertEqual(relayed.ttl, 7)
        relayed.ttl = 4 // Relay decremented TTL from 7 to 4

        // Re-encode with modified TTL
        let relayedWire = try PacketSerializer.encode(relayed)

        // Verify at final destination — should still be valid
        let decoded = try PacketSerializer.decode(relayedWire)
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertTrue(valid, "Signature must survive TTL modification by relay nodes")
    }

    // MARK: - Test: Wrong key rejects signature

    func testWrongKeyRejectsSignature() throws {
        let (secretKey, _) = makeKeypair()
        let (_, wrongPublicKey) = makeKeypair() // Different keypair

        let packet = makePacket()
        let signed = try Signer.sign(packet: packet, secretKey: secretKey)

        let valid = try Signer.verify(packet: signed, publicKey: wrongPublicKey)
        XCTAssertFalse(valid, "Verification with wrong key must fail")
    }

    // MARK: - Test: Tampered payload invalidates signature

    func testTamperedPayloadInvalidatesSignature() throws {
        let (secretKey, publicKey) = makeKeypair()
        let packet = makePacket(payload: Data("original message".utf8))

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let wireData = try PacketSerializer.encode(signed)

        // Tamper with payload bytes (somewhere in the middle of the wire data)
        var tampered = wireData
        let payloadStart = Packet.headerSize + PeerID.length // After header + senderID
        if payloadStart + 5 < tampered.count - 64 { // Before signature
            tampered[payloadStart + 5] ^= 0xFF // Flip bits
        }

        let decoded = try PacketSerializer.decode(tampered)
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertFalse(valid, "Tampered payload must invalidate signature")
    }

    // MARK: - Test: Unsigned packet is accepted (no hasSignature flag)

    func testUnsignedPacketEncodesAndDecodes() throws {
        let packet = makePacket(flags: [])
        XCTAssertFalse(packet.flags.contains(.hasSignature))
        XCTAssertNil(packet.signature)

        let wireData = try PacketSerializer.encode(packet)
        let decoded = try PacketSerializer.decode(wireData)
        XCTAssertFalse(decoded.flags.contains(.hasSignature))
        XCTAssertNil(decoded.signature)
    }

    // MARK: - Test: Addressed + signed packet roundtrip

    func testAddressedSignedPacketRoundtrip() throws {
        let (secretKey, publicKey) = makeKeypair()
        let recipient = makePeerID(seed: 0x02)
        let packet = makePacket(
            recipientID: recipient,
            flags: [.hasRecipient, .isReliable]
        )

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        XCTAssertTrue(signed.flags.contains(.hasSignature))
        XCTAssertTrue(signed.flags.contains(.hasRecipient))

        let wireData = try PacketSerializer.encode(signed)
        let decoded = try PacketSerializer.decode(wireData)

        XCTAssertEqual(decoded.recipientID, recipient)
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertTrue(valid)
    }

    // MARK: - Test: SOS signed packet roundtrip

    func testSOSSignedPacketRoundtrip() throws {
        let (secretKey, publicKey) = makeKeypair()
        let packet = makePacket(
            type: .sosAlert,
            ttl: 7,
            payload: Data([0x03, 0x67, 0x65, 0x6F]),
            flags: [.isPriority, .isReliable]
        )

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let wireData = try PacketSerializer.encode(signed)
        let decoded = try PacketSerializer.decode(wireData)

        XCTAssertEqual(decoded.type, .sosAlert)
        XCTAssertTrue(decoded.flags.contains(.isPriority))
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertTrue(valid, "SOS packets must be verifiable")
    }

    // MARK: - Test: Announce packet signed and verified

    func testAnnouncePacketSignedRoundtrip() throws {
        let (secretKey, publicKey) = makeKeypair()

        // Simulate announce payload: username + 0x00 + displayName + 0x00 + noiseKey(32) + signingKey(32)
        var payload = Data("testuser".utf8)
        payload.append(0x00)
        payload.append(Data("Test User".utf8))
        payload.append(0x00)
        payload.append(Data(repeating: 0xAA, count: 32)) // noise key
        payload.append(publicKey) // signing key

        let packet = makePacket(
            type: .announce,
            payload: payload,
            flags: []
        )

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let wireData = try PacketSerializer.encode(signed)
        let decoded = try PacketSerializer.decode(wireData)

        // Verify the announce signature
        let valid = try Signer.verify(packet: decoded, publicKey: publicKey)
        XCTAssertTrue(valid, "Announce packets must be verifiable")

        // Parse the payload to extract the signing key
        let payloadBytes = Array(decoded.payload)
        guard let firstSep = payloadBytes.firstIndex(of: 0x00) else {
            XCTFail("No separator in announce payload")
            return
        }
        let afterFirst = firstSep + 1
        guard let secondSep = payloadBytes[afterFirst...].firstIndex(of: 0x00) else {
            XCTFail("No second separator in announce payload")
            return
        }
        let keyStart = secondSep + 1
        XCTAssertTrue(keyStart + 64 <= payloadBytes.count, "Payload should contain noise + signing keys")
        let extractedSigningKey = Data(payloadBytes[keyStart + 32..<keyStart + 64])
        XCTAssertEqual(extractedSigningKey, publicKey, "Extracted signing key should match original")
    }

    // MARK: - Test: Multi-hop relay chain preserves signature

    func testMultiHopRelayPreservesSignature() throws {
        let (secretKey, publicKey) = makeKeypair()
        let packet = makePacket(ttl: 7, payload: Data("mesh message".utf8))

        // Origin signs
        let signed = try Signer.sign(packet: packet, secretKey: secretKey)

        // Simulate 5 relay hops — each decrements TTL
        var current = signed
        for hop in 0..<5 {
            let wire = try PacketSerializer.encode(current)
            var relayed = try PacketSerializer.decode(wire)
            relayed.ttl = UInt8(max(0, Int(relayed.ttl) - 1))
            current = relayed

            // Verify at each hop — should always pass
            let valid = try Signer.verify(packet: current, publicKey: publicKey)
            XCTAssertTrue(valid, "Signature must be valid at hop \(hop + 1) (TTL=\(current.ttl))")
        }

        XCTAssertEqual(current.ttl, 2, "TTL should be 7 - 5 = 2")
    }

    // MARK: - Test: Packet size stays within MTU

    func testSignedPacketWithinMTU() throws {
        let (secretKey, _) = makeKeypair()

        // Max payload for broadcast signed: 424 bytes
        let payload = Data(repeating: 0x42, count: 400) // Leave room for signature overhead
        let packet = makePacket(payload: payload)

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let wireData = try PacketSerializer.encode(signed)

        XCTAssertLessThanOrEqual(wireData.count, 512, "Signed packet must fit within 512B MTU")
    }
}

// Sodium import for keypair generation
import Sodium
