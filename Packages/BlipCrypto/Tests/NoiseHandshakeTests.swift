import Testing
import Foundation
import CryptoKit
@testable import BlipCrypto

@Suite("Noise XX Handshake Tests")
struct NoiseHandshakeTests {

    // MARK: - Full XX Handshake

    @Test("Complete XX handshake between initiator and responder")
    func testFullXXHandshake() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        // Message 1: initiator -> responder (-> e)
        let msg1 = try initiator.writeMessage()
        #expect(msg1.count >= 32, "Message 1 should contain at least the ephemeral key (32 bytes)")

        let payload1 = try responder.readMessage(msg1)
        #expect(payload1.isEmpty, "Message 1 payload should be empty")

        // Message 2: responder -> initiator (<- e, ee, s, es)
        let msg2 = try responder.writeMessage()
        // msg2 = e(32) + encrypted_s(48) + encrypted_payload(16 for empty + tag)
        #expect(msg2.count >= 32 + 48, "Message 2 should contain ephemeral + encrypted static")

        let payload2 = try initiator.readMessage(msg2)
        #expect(payload2.isEmpty)

        // Message 3: initiator -> responder (-> s, se)
        let msg3 = try initiator.writeMessage()
        // msg3 = encrypted_s(48) + encrypted_payload(16 for empty + tag)
        #expect(msg3.count >= 48, "Message 3 should contain encrypted static")

        let payload3 = try responder.readMessage(msg3)
        #expect(payload3.isEmpty)

        // Both sides should be complete
        #expect(initiator.isComplete)
        #expect(responder.isComplete)

        // Finalize both sides
        let initiatorResult = try initiator.finalize()
        let responderResult = try responder.finalize()

        // Remote static keys should match
        #expect(
            initiatorResult.remoteStaticKey.rawRepresentation ==
            responderStatic.publicKey.rawRepresentation,
            "Initiator should have responder's static key"
        )
        #expect(
            responderResult.remoteStaticKey.rawRepresentation ==
            initiatorStatic.publicKey.rawRepresentation,
            "Responder should have initiator's static key"
        )

        // Handshake hashes should match (both sides computed the same transcript)
        #expect(
            initiatorResult.handshakeHash == responderResult.handshakeHash,
            "Handshake hashes should be identical"
        )
    }

    // MARK: - Bidirectional Encryption

    @Test("Transport messages encrypt and decrypt correctly after handshake")
    func testBidirectionalTransport() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        // Initiator sends to responder
        let plaintext1 = Data("Hello from initiator!".utf8)
        let ciphertext1 = try initiatorResult.sendCipher.encrypt(plaintext: plaintext1)
        let decrypted1 = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext1)
        #expect(decrypted1 == plaintext1)

        // Responder sends to initiator
        let plaintext2 = Data("Hello from responder!".utf8)
        let ciphertext2 = try responderResult.sendCipher.encrypt(plaintext: plaintext2)
        let decrypted2 = try initiatorResult.receiveCipher.decrypt(ciphertext: ciphertext2)
        #expect(decrypted2 == plaintext2)
    }

    @Test("Multiple messages encrypt and decrypt in sequence")
    func testMultipleMessages() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        for i in 0 ..< 100 {
            let msg = Data("Message \(i)".utf8)
            let ct = try initiatorResult.sendCipher.encrypt(plaintext: msg)
            let pt = try responderResult.receiveCipher.decrypt(ciphertext: ct)
            #expect(pt == msg)
        }
    }

    @Test("Cross-direction ciphers are independent")
    func testCrossDirectionIndependence() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        // Send messages in both directions simultaneously
        let msgA = Data("From initiator".utf8)
        let msgB = Data("From responder".utf8)

        let ctA = try initiatorResult.sendCipher.encrypt(plaintext: msgA)
        let ctB = try responderResult.sendCipher.encrypt(plaintext: msgB)

        // Decrypt in opposite direction
        let ptA = try responderResult.receiveCipher.decrypt(ciphertext: ctA)
        let ptB = try initiatorResult.receiveCipher.decrypt(ciphertext: ctB)

        #expect(ptA == msgA)
        #expect(ptB == msgB)
    }

    // MARK: - Handshake with Payloads

    @Test("Handshake messages can carry payloads")
    func testHandshakePayloads() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        // Message 1 with payload (not encrypted in XX msg1, but still carried)
        let p1 = Data("initiator-hello".utf8)
        let msg1 = try initiator.writeMessage(payload: p1)
        let recv1 = try responder.readMessage(msg1)
        #expect(recv1 == p1)

        // Message 2 with payload (encrypted)
        let p2 = Data("responder-hello".utf8)
        let msg2 = try responder.writeMessage(payload: p2)
        let recv2 = try initiator.readMessage(msg2)
        #expect(recv2 == p2)

        // Message 3 with payload (encrypted)
        let p3 = Data("initiator-final".utf8)
        let msg3 = try initiator.writeMessage(payload: p3)
        let recv3 = try responder.readMessage(msg3)
        #expect(recv3 == p3)
    }

    // MARK: - Prologue

    @Test("Matching prologues produce successful handshake")
    func testMatchingPrologues() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let prologue = Data("Blip v1".utf8)

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic, prologue: prologue)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic, prologue: prologue)

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)
        let msg3 = try initiator.writeMessage()
        _ = try responder.readMessage(msg3)

        let iResult = try initiator.finalize()
        let rResult = try responder.finalize()

        // Should work normally
        let ct = try iResult.sendCipher.encrypt(plaintext: Data("test".utf8))
        let pt = try rResult.receiveCipher.decrypt(ciphertext: ct)
        #expect(pt == Data("test".utf8))
    }

    @Test("Mismatched prologues cause handshake failure")
    func testMismatchedPrologues() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(
            role: .initiator,
            staticKey: initiatorStatic,
            prologue: Data("Prologue A".utf8)
        )
        let responder = NoiseHandshake(
            role: .responder,
            staticKey: responderStatic,
            prologue: Data("Prologue B".utf8)
        )

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        let msg2 = try responder.writeMessage()

        // Message 2 decryption should fail because the handshake hashes diverged
        #expect(throws: NoiseHandshakeError.self) {
            _ = try initiator.readMessage(msg2)
        }
    }

    // MARK: - Error Cases

    @Test("Finalize before completion throws")
    func testFinalizeBeforeComplete() throws {
        let hs = NoiseHandshake(role: .initiator, staticKey: Curve25519.KeyAgreement.PrivateKey())
        #expect(throws: NoiseHandshakeError.self) {
            _ = try hs.finalize()
        }
    }

    @Test("Write message out of order throws")
    func testWriteOutOfOrder() throws {
        let hs = NoiseHandshake(role: .responder, staticKey: Curve25519.KeyAgreement.PrivateKey())
        // Responder tries to write before reading message 1
        #expect(throws: NoiseHandshakeError.self) {
            _ = try hs.writeMessage()
        }
    }

    @Test("Read message with too-short data throws")
    func testReadShortMessage() throws {
        let hs = NoiseHandshake(role: .responder, staticKey: Curve25519.KeyAgreement.PrivateKey())
        let shortMsg = Data(repeating: 0, count: 10)
        #expect(throws: NoiseHandshakeError.self) {
            _ = try hs.readMessage(shortMsg)
        }
    }

    // MARK: - Cipher State

    @Test("CipherState nonce increments correctly")
    func testCipherStateNonce() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        // Both start at nonce 0
        #expect(initiatorResult.sendCipher.currentNonce == 0)
        #expect(responderResult.receiveCipher.currentNonce == 0)

        // Encrypt and decrypt in lockstep so nonces stay synchronized
        let ct1 = try initiatorResult.sendCipher.encrypt(plaintext: Data("1".utf8))
        #expect(initiatorResult.sendCipher.currentNonce == 1)

        _ = try responderResult.receiveCipher.decrypt(ciphertext: ct1)
        #expect(responderResult.receiveCipher.currentNonce == 1)

        let ct2 = try initiatorResult.sendCipher.encrypt(plaintext: Data("2".utf8))
        #expect(initiatorResult.sendCipher.currentNonce == 2)

        _ = try responderResult.receiveCipher.decrypt(ciphertext: ct2)
        #expect(responderResult.receiveCipher.currentNonce == 2)

        let ct3 = try initiatorResult.sendCipher.encrypt(plaintext: Data("3".utf8))
        #expect(initiatorResult.sendCipher.currentNonce == 3)

        _ = try responderResult.receiveCipher.decrypt(ciphertext: ct3)
        #expect(responderResult.receiveCipher.currentNonce == 3)
    }

    @Test("CipherState rekey produces different encryption")
    func testCipherStateRekey() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("same message".utf8)

        // Encrypt before rekey
        let ct1 = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)

        // We need to advance the responder to consume ct1
        _ = try responderResult.receiveCipher.decrypt(ciphertext: ct1)

        // Rekey both sides
        try initiatorResult.sendCipher.rekey()
        try responderResult.receiveCipher.rekey()

        // Encrypt after rekey -- nonce continues but key changed
        let ct2 = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)
        let pt2 = try responderResult.receiveCipher.decrypt(ciphertext: ct2)
        #expect(pt2 == plaintext)

        // Ciphertexts should differ (different keys, different nonces)
        #expect(ct1 != ct2)
    }

    // MARK: - Helpers

    /// Perform a full handshake and return both results.
    private func performHandshake() throws -> (NoiseHandshakeResult, NoiseHandshakeResult) {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)
        let msg3 = try initiator.writeMessage()
        _ = try responder.readMessage(msg3)

        let iResult = try initiator.finalize()
        let rResult = try responder.finalize()
        return (iResult, rResult)
    }
}
