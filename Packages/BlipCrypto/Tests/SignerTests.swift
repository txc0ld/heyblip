import Testing
import Foundation
import Sodium
@testable import BlipCrypto
import BlipProtocol

@Suite("Signer Tests")
struct SignerTests {

    /// Helper: create a test Ed25519 keypair via libsodium.
    private func makeEd25519Keypair() -> (secretKey: Data, publicKey: Data) {
        let sodium = Sodium()
        let kp = sodium.sign.keyPair()!
        return (Data(kp.secretKey), Data(kp.publicKey))
    }

    /// Helper: create a test packet.
    private func makeTestPacket(withSignature: Bool = false) -> Packet {
        let senderID = PeerID(bytes: Data(repeating: 0xAA, count: 8))!
        var flags: PacketFlags = []
        if withSignature { flags.insert(.hasSignature) }

        return Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: 1_700_000_000_000,
            flags: flags,
            senderID: senderID,
            payload: Data("Hello Blip!".utf8),
            signature: withSignature ? Data(repeating: 0, count: 64) : nil
        )
    }

    // MARK: - Sign and Verify

    @Test("Sign and verify a packet succeeds with correct key")
    func testSignAndVerify() throws {
        let (secretKey, publicKey) = makeEd25519Keypair()
        let packet = makeTestPacket()

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        #expect(signed.flags.contains(.hasSignature))
        #expect(signed.signature != nil)
        #expect(signed.signature?.count == 64)

        let isValid = try Signer.verify(packet: signed, publicKey: publicKey)
        #expect(isValid)
    }

    @Test("Verify fails with wrong public key")
    func testVerifyWrongKey() throws {
        let (secretKey, _) = makeEd25519Keypair()
        let (_, wrongPublicKey) = makeEd25519Keypair()
        let packet = makeTestPacket()

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)
        let isValid = try Signer.verify(packet: signed, publicKey: wrongPublicKey)
        #expect(!isValid)
    }

    @Test("Verify fails with tampered payload")
    func testVerifyTamperedPayload() throws {
        let (secretKey, publicKey) = makeEd25519Keypair()
        let packet = makeTestPacket()

        var signed = try Signer.sign(packet: packet, secretKey: secretKey)
        // Tamper with payload
        signed.payload = Data("Tampered!".utf8)

        let isValid = try Signer.verify(packet: signed, publicKey: publicKey)
        #expect(!isValid)
    }

    // MARK: - TTL Exclusion

    @Test("Changing TTL does not invalidate signature")
    func testTTLChangeDoesNotInvalidate() throws {
        let (secretKey, publicKey) = makeEd25519Keypair()
        let packet = makeTestPacket()

        let signed = try Signer.sign(packet: packet, secretKey: secretKey)

        // Change TTL (simulating a relay node decrementing it)
        var relayed = signed
        relayed.ttl = 3  // was 5

        let isValid = try Signer.verify(packet: relayed, publicKey: publicKey)
        #expect(isValid, "Signature should remain valid after TTL change")
    }

    @Test("Different TTL values produce same signable data")
    func testTTLExcludedFromSignableData() throws {
        let senderID = PeerID(bytes: Data(repeating: 0xBB, count: 8))!
        let payload = Data("test".utf8)

        let packet1 = Packet(
            type: .meshBroadcast,
            ttl: 7,
            timestamp: 1_000_000,
            flags: [.hasSignature],
            senderID: senderID,
            payload: payload,
            signature: Data(repeating: 0, count: 64)
        )

        let packet2 = Packet(
            type: .meshBroadcast,
            ttl: 0,
            timestamp: 1_000_000,
            flags: [.hasSignature],
            senderID: senderID,
            payload: payload,
            signature: Data(repeating: 0, count: 64)
        )

        let wire1 = try PacketSerializer.encode(packet1)
        let wire2 = try PacketSerializer.encode(packet2)

        let signable1 = try Signer.extractSignableData(from: wire1)
        let signable2 = try Signer.extractSignableData(from: wire2)

        #expect(signable1 == signable2, "Signable data should be identical regardless of TTL")
    }

    // MARK: - Raw Wire Data Sign/Verify

    @Test("Sign and verify raw wire data")
    func testSignVerifyRawData() throws {
        let (secretKey, publicKey) = makeEd25519Keypair()
        let packet = makeTestPacket(withSignature: true)
        let wireData = try PacketSerializer.encode(packet)

        let signature = try Signer.sign(packetData: wireData, secretKey: secretKey)
        #expect(signature.count == 64)

        // Replace the zero signature with the real one
        var signedWire = wireData
        let sigStart = signedWire.count - 64
        signedWire.replaceSubrange(sigStart ..< signedWire.count, with: signature)

        let isValid = try Signer.verify(packetData: signedWire, publicKey: publicKey)
        #expect(isValid)
    }

    // MARK: - Error Cases

    @Test("Sign with wrong-length secret key throws")
    func testSignWrongKeyLength() throws {
        let badKey = Data(repeating: 0, count: 32)  // Should be 64
        let packet = makeTestPacket()
        let wireData = try PacketSerializer.encode(packet)

        #expect(throws: SignerError.self) {
            _ = try Signer.sign(packetData: wireData, secretKey: badKey)
        }
    }

    @Test("Verify with wrong-length public key throws")
    func testVerifyWrongKeyLength() throws {
        let badKey = Data(repeating: 0, count: 16)  // Should be 32
        let packet = makeTestPacket(withSignature: true)
        let wireData = try PacketSerializer.encode(packet)

        #expect(throws: SignerError.self) {
            _ = try Signer.verify(packetData: wireData, publicKey: badKey)
        }
    }

    @Test("Sign with too-short packet data throws")
    func testSignShortPacket() throws {
        let (secretKey, _) = makeEd25519Keypair()
        let shortData = Data(repeating: 0, count: 5)

        #expect(throws: SignerError.self) {
            _ = try Signer.sign(packetData: shortData, secretKey: secretKey)
        }
    }

    // MARK: - Detached Signature Verification

    @Test("verifyDetached succeeds with valid signature")
    func testVerifyDetachedValid() throws {
        let sodium = Sodium()
        let kp = sodium.sign.keyPair()!
        let message = Data("event manifest payload".utf8)

        guard let signature = sodium.sign.signature(
            message: Bytes(message),
            secretKey: kp.secretKey
        ) else {
            Issue.record("Failed to produce detached signature")
            return
        }

        let isValid = try Signer.verifyDetached(
            message: message,
            signature: Data(signature),
            publicKey: Data(kp.publicKey)
        )
        #expect(isValid)
    }

    @Test("verifyDetached fails with tampered message")
    func testVerifyDetachedTampered() throws {
        let sodium = Sodium()
        let kp = sodium.sign.keyPair()!
        let message = Data("original message".utf8)

        guard let signature = sodium.sign.signature(
            message: Bytes(message),
            secretKey: kp.secretKey
        ) else {
            Issue.record("Failed to produce detached signature")
            return
        }

        let tampered = Data("tampered message".utf8)
        let isValid = try Signer.verifyDetached(
            message: tampered,
            signature: Data(signature),
            publicKey: Data(kp.publicKey)
        )
        #expect(!isValid)
    }

    @Test("verifyDetached fails with wrong public key")
    func testVerifyDetachedWrongKey() throws {
        let sodium = Sodium()
        let kp = sodium.sign.keyPair()!
        let otherKp = sodium.sign.keyPair()!
        let message = Data("signed by first key".utf8)

        guard let signature = sodium.sign.signature(
            message: Bytes(message),
            secretKey: kp.secretKey
        ) else {
            Issue.record("Failed to produce detached signature")
            return
        }

        let isValid = try Signer.verifyDetached(
            message: message,
            signature: Data(signature),
            publicKey: Data(otherKp.publicKey)
        )
        #expect(!isValid)
    }

    @Test("verifyDetached throws on invalid key/signature lengths")
    func testVerifyDetachedBadLengths() throws {
        let message = Data("test".utf8)
        let validSig = Data(repeating: 0, count: 64)
        let validKey = Data(repeating: 0, count: 32)

        #expect(throws: SignerError.self) {
            _ = try Signer.verifyDetached(message: message, signature: validSig, publicKey: Data(repeating: 0, count: 16))
        }
        #expect(throws: SignerError.self) {
            _ = try Signer.verifyDetached(message: message, signature: Data(repeating: 0, count: 32), publicKey: validKey)
        }
    }
}
