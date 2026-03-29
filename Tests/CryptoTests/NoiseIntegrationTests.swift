import XCTest
import CryptoKit
@testable import BlipCrypto
@testable import BlipProtocol

/// Integration tests for the full Noise XX handshake, encryption/decryption,
/// forward secrecy, and session manager caching with IK upgrade.
final class NoiseIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a fresh Curve25519 keypair.
    private func generateStaticKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Derive a PeerID from a public key.
    private func peerID(from privateKey: Curve25519.KeyAgreement.PrivateKey) -> PeerID {
        PeerID(noisePublicKey: privateKey.publicKey)
    }

    // MARK: - Full Handshake

    func testFullNoiseXXHandshakeBetweenTwoPeers() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        // Alice is the initiator, Bob is the responder.
        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        // Message 1: Alice -> Bob (ephemeral key).
        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)

        // Message 2: Bob -> Alice (ephemeral + encrypted static).
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)

        // Message 3: Alice -> Bob (encrypted static).
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        // Both sides should now be complete.
        XCTAssertTrue(aliceHandshake.isComplete)
        XCTAssertTrue(bobHandshake.isComplete)

        // Finalize both sides.
        let aliceResult = try aliceHandshake.finalize()
        let bobResult = try bobHandshake.finalize()

        // Verify they learned each other's static keys.
        XCTAssertEqual(
            aliceResult.remoteStaticKey.rawRepresentation,
            bobKey.publicKey.rawRepresentation,
            "Alice should know Bob's static key"
        )
        XCTAssertEqual(
            bobResult.remoteStaticKey.rawRepresentation,
            aliceKey.publicKey.rawRepresentation,
            "Bob should know Alice's static key"
        )

        // Verify handshake hashes match.
        XCTAssertEqual(
            aliceResult.handshakeHash,
            bobResult.handshakeHash,
            "Handshake hashes must be identical"
        )
    }

    // MARK: - Encrypt on One Side, Decrypt on Other

    func testEncryptDecryptAfterHandshake() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        // Complete the 3-message handshake.
        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        let aliceResult = try aliceHandshake.finalize()
        let bobResult = try bobHandshake.finalize()

        // Alice encrypts a message.
        let plaintext = "Hello Bob! See you at the Pyramid Stage.".data(using: .utf8)!
        let ciphertext = try aliceResult.sendCipher.encrypt(plaintext: plaintext)

        // Bob decrypts it.
        let decrypted = try bobResult.receiveCipher.decrypt(ciphertext: ciphertext)
        XCTAssertEqual(decrypted, plaintext)

        // Bob encrypts a reply.
        let reply = "On my way! Meet at the flags.".data(using: .utf8)!
        let replyCiphertext = try bobResult.sendCipher.encrypt(plaintext: reply)

        // Alice decrypts the reply.
        let decryptedReply = try aliceResult.receiveCipher.decrypt(ciphertext: replyCiphertext)
        XCTAssertEqual(decryptedReply, reply)
    }

    func testMultipleMessagesInSequence() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        let aliceResult = try aliceHandshake.finalize()
        let bobResult = try bobHandshake.finalize()

        // Send 20 messages from Alice to Bob.
        for i in 0 ..< 20 {
            let msg = "Message \(i) from Alice".data(using: .utf8)!
            let ct = try aliceResult.sendCipher.encrypt(plaintext: msg)
            let pt = try bobResult.receiveCipher.decrypt(ciphertext: ct)
            XCTAssertEqual(pt, msg)
        }

        // Send 20 messages from Bob to Alice.
        for i in 0 ..< 20 {
            let msg = "Reply \(i) from Bob".data(using: .utf8)!
            let ct = try bobResult.sendCipher.encrypt(plaintext: msg)
            let pt = try aliceResult.receiveCipher.decrypt(ciphertext: ct)
            XCTAssertEqual(pt, msg)
        }
    }

    func testWrongCipherFailsDecryption() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()
        let eveKey = generateStaticKey()

        // Alice <-> Bob handshake.
        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        let aliceResult = try aliceHandshake.finalize()

        // Alice <-> Eve separate handshake (Eve cannot use Bob's cipher).
        let aliceHandshake2 = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let eveHandshake = NoiseHandshake(role: .responder, staticKey: eveKey)

        let e1 = try aliceHandshake2.writeMessage()
        let _ = try eveHandshake.readMessage(e1)
        let e2 = try eveHandshake.writeMessage()
        let _ = try aliceHandshake2.readMessage(e2)
        let e3 = try aliceHandshake2.writeMessage()
        let _ = try eveHandshake.readMessage(e3)

        let eveResult = try eveHandshake.finalize()

        // Alice encrypts for Bob's session.
        let plaintext = "Secret for Bob only".data(using: .utf8)!
        let ciphertext = try aliceResult.sendCipher.encrypt(plaintext: plaintext)

        // Eve tries to decrypt with her own receive cipher -- should fail.
        XCTAssertThrowsError(try eveResult.receiveCipher.decrypt(ciphertext: ciphertext)) { error in
            guard case NoiseCipherError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Forward Secrecy

    func testForwardSecrecyDifferentEphemeralKeys() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        // First session.
        let alice1 = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bob1 = NoiseHandshake(role: .responder, staticKey: bobKey)

        let m1 = try alice1.writeMessage()
        let _ = try bob1.readMessage(m1)
        let m2 = try bob1.writeMessage()
        let _ = try alice1.readMessage(m2)
        let m3 = try alice1.writeMessage()
        let _ = try bob1.readMessage(m3)

        let result1Alice = try alice1.finalize()
        let result1Bob = try bob1.finalize()

        // Second session (same static keys, new ephemeral keys).
        let alice2 = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bob2 = NoiseHandshake(role: .responder, staticKey: bobKey)

        let n1 = try alice2.writeMessage()
        let _ = try bob2.readMessage(n1)
        let n2 = try bob2.writeMessage()
        let _ = try alice2.readMessage(n2)
        let n3 = try alice2.writeMessage()
        let _ = try bob2.readMessage(n3)

        let result2Alice = try alice2.finalize()
        let result2Bob = try bob2.finalize()

        // Handshake hashes must differ (different ephemeral keys each time).
        XCTAssertNotEqual(
            result1Alice.handshakeHash,
            result2Alice.handshakeHash,
            "Different sessions must produce different handshake hashes (forward secrecy)"
        )

        // Message encrypted in session 1 cannot be decrypted by session 2.
        let plaintext = "Session 1 secret".data(using: .utf8)!
        let ct1 = try result1Alice.sendCipher.encrypt(plaintext: plaintext)

        XCTAssertThrowsError(try result2Bob.receiveCipher.decrypt(ciphertext: ct1)) { error in
            guard case NoiseCipherError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed, got \(error)")
                return
            }
        }

        // Session 2 message works on its own ciphers.
        let ct2 = try result2Alice.sendCipher.encrypt(plaintext: plaintext)
        let pt2 = try result2Bob.receiveCipher.decrypt(ciphertext: ct2)
        XCTAssertEqual(pt2, plaintext)
    }

    // MARK: - Rekey

    func testRekeyContinuesWorking() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        let aliceResult = try aliceHandshake.finalize()
        let bobResult = try bobHandshake.finalize()

        // Send some messages.
        let preRekey = "Before rekey".data(using: .utf8)!
        let ct1 = try aliceResult.sendCipher.encrypt(plaintext: preRekey)
        let pt1 = try bobResult.receiveCipher.decrypt(ciphertext: ct1)
        XCTAssertEqual(pt1, preRekey)

        // Perform rekey on both sides.
        try aliceResult.sendCipher.rekey()
        try bobResult.receiveCipher.rekey()

        // Messages after rekey should still work.
        let postRekey = "After rekey".data(using: .utf8)!
        let ct2 = try aliceResult.sendCipher.encrypt(plaintext: postRekey)
        let pt2 = try bobResult.receiveCipher.decrypt(ciphertext: ct2)
        XCTAssertEqual(pt2, postRekey)
    }

    // MARK: - Session Manager

    func testSessionManagerCachesSession() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()
        let alicePeerID = peerID(from: aliceKey)
        let bobPeerID = peerID(from: bobKey)

        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)

        // Alice initiates handshake with Bob.
        let (_, msg1) = try aliceManager.initiateHandshake(with: bobPeerID)

        // Bob receives message 1.
        let (_, _) = try bobManager.receiveHandshakeInit(from: alicePeerID, message: msg1)

        // Bob sends message 2.
        let msg2 = try bobManager.respondToHandshake(for: alicePeerID)

        // Alice processes message 2.
        let (_, maybeSession) = try aliceManager.processHandshakeMessage(from: bobPeerID, message: msg2)
        XCTAssertNil(maybeSession, "Session should not be complete after message 2 for initiator")

        // Alice sends message 3 and completes the handshake.
        let (msg3, aliceSession) = try aliceManager.completeHandshake(with: bobPeerID)

        // Bob processes message 3 and gets the completed session.
        let (_, bobSession) = try bobManager.processHandshakeMessage(from: alicePeerID, message: msg3)
        XCTAssertNotNil(bobSession, "Bob should have a completed session after message 3")

        // Verify sessions are cached.
        XCTAssertTrue(aliceManager.hasSession(for: bobPeerID))
        XCTAssertTrue(bobManager.hasSession(for: alicePeerID))
        XCTAssertEqual(aliceManager.activeSessionCount, 1)
        XCTAssertEqual(bobManager.activeSessionCount, 1)

        // Test encrypt/decrypt through the sessions.
        let plaintext = "Through session manager".data(using: .utf8)!
        let ct = try aliceSession.encrypt(plaintext: plaintext)
        let pt = try bobSession!.decrypt(ciphertext: ct)
        XCTAssertEqual(pt, plaintext)
    }

    func testSessionManagerCacheLookup() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()
        let alicePeerID = peerID(from: aliceKey)
        let bobPeerID = peerID(from: bobKey)

        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)

        // Complete a handshake.
        let (_, msg1) = try aliceManager.initiateHandshake(with: bobPeerID)
        let _ = try bobManager.receiveHandshakeInit(from: alicePeerID, message: msg1)
        let msg2 = try bobManager.respondToHandshake(for: alicePeerID)
        let _ = try aliceManager.processHandshakeMessage(from: bobPeerID, message: msg2)
        let (msg3, _) = try aliceManager.completeHandshake(with: bobPeerID)
        let _ = try bobManager.processHandshakeMessage(from: alicePeerID, message: msg3)

        // Retrieve the cached session.
        let cachedSession = aliceManager.getSession(for: bobPeerID)
        XCTAssertNotNil(cachedSession, "Session should be retrievable from cache")
        XCTAssertEqual(cachedSession?.peerID, bobPeerID)
        XCTAssertFalse(cachedSession!.isExpired())
    }

    func testSessionManagerIKUpgradeAvailable() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()
        let alicePeerID = peerID(from: aliceKey)
        let bobPeerID = peerID(from: bobKey)

        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)

        // Before handshake: IK not available.
        XCTAssertFalse(aliceManager.canUseIKPattern(for: bobPeerID))
        XCTAssertFalse(bobManager.canUseIKPattern(for: alicePeerID))

        // Complete XX handshake.
        let (_, msg1) = try aliceManager.initiateHandshake(with: bobPeerID)
        let _ = try bobManager.receiveHandshakeInit(from: alicePeerID, message: msg1)
        let msg2 = try bobManager.respondToHandshake(for: alicePeerID)
        let _ = try aliceManager.processHandshakeMessage(from: bobPeerID, message: msg2)
        let (msg3, _) = try aliceManager.completeHandshake(with: bobPeerID)
        let _ = try bobManager.processHandshakeMessage(from: alicePeerID, message: msg3)

        // After handshake: IK should be available (static keys are known).
        XCTAssertTrue(aliceManager.canUseIKPattern(for: bobPeerID))
        XCTAssertTrue(bobManager.canUseIKPattern(for: alicePeerID))

        // Verify the known static keys are correct.
        XCTAssertEqual(
            aliceManager.knownStaticKey(for: bobPeerID)?.rawRepresentation,
            bobKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            bobManager.knownStaticKey(for: alicePeerID)?.rawRepresentation,
            aliceKey.publicKey.rawRepresentation
        )
    }

    func testSessionManagerDestroySession() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()
        let alicePeerID = peerID(from: aliceKey)
        let bobPeerID = peerID(from: bobKey)

        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)

        // Complete handshake.
        let (_, msg1) = try aliceManager.initiateHandshake(with: bobPeerID)
        let _ = try bobManager.receiveHandshakeInit(from: alicePeerID, message: msg1)
        let msg2 = try bobManager.respondToHandshake(for: alicePeerID)
        let _ = try aliceManager.processHandshakeMessage(from: bobPeerID, message: msg2)
        let (msg3, _) = try aliceManager.completeHandshake(with: bobPeerID)
        let _ = try bobManager.processHandshakeMessage(from: alicePeerID, message: msg3)

        XCTAssertEqual(aliceManager.activeSessionCount, 1)

        // Destroy Alice's session to Bob.
        aliceManager.destroySession(for: bobPeerID)
        XCTAssertEqual(aliceManager.activeSessionCount, 0)
        XCTAssertFalse(aliceManager.hasSession(for: bobPeerID))
        XCTAssertNil(aliceManager.getSession(for: bobPeerID))
    }

    func testSessionManagerDestroyAll() throws {
        let localKey = generateStaticKey()
        let manager = NoiseSessionManager(localStaticKey: localKey)

        // Create sessions with multiple peers.
        for i: UInt8 in 0 ..< 5 {
            let remoteKey = generateStaticKey()
            let remotePeerID = peerID(from: remoteKey)
            let remoteManager = NoiseSessionManager(localStaticKey: remoteKey)
            let localPeerID = peerID(from: localKey)

            let (_, msg1) = try manager.initiateHandshake(with: remotePeerID)
            let _ = try remoteManager.receiveHandshakeInit(from: localPeerID, message: msg1)
            let msg2 = try remoteManager.respondToHandshake(for: localPeerID)
            let _ = try manager.processHandshakeMessage(from: remotePeerID, message: msg2)
            let (msg3, _) = try manager.completeHandshake(with: remotePeerID)
            let _ = try remoteManager.processHandshakeMessage(from: localPeerID, message: msg3)
            _ = i // suppress unused warning
        }

        XCTAssertEqual(manager.activeSessionCount, 5)

        manager.destroyAllSessions()
        XCTAssertEqual(manager.activeSessionCount, 0)
    }

    // MARK: - Handshake with Payload

    func testHandshakeWithPayload() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        // Message 1 with payload (usually empty, but valid per Noise spec).
        let msg1Payload = "initiate".data(using: .utf8)!
        let msg1 = try aliceHandshake.writeMessage(payload: msg1Payload)
        let recvPayload1 = try bobHandshake.readMessage(msg1)
        XCTAssertEqual(recvPayload1, msg1Payload)

        // Message 2 with payload.
        let msg2Payload = "respond".data(using: .utf8)!
        let msg2 = try bobHandshake.writeMessage(payload: msg2Payload)
        let recvPayload2 = try aliceHandshake.readMessage(msg2)
        XCTAssertEqual(recvPayload2, msg2Payload)

        // Message 3 with payload.
        let msg3Payload = "complete".data(using: .utf8)!
        let msg3 = try aliceHandshake.writeMessage(payload: msg3Payload)
        let recvPayload3 = try bobHandshake.readMessage(msg3)
        XCTAssertEqual(recvPayload3, msg3Payload)

        XCTAssertTrue(aliceHandshake.isComplete)
        XCTAssertTrue(bobHandshake.isComplete)
    }

    // MARK: - Nonce Tracking

    func testNonceIncrements() throws {
        let aliceKey = generateStaticKey()
        let bobKey = generateStaticKey()

        let aliceHandshake = NoiseHandshake(role: .initiator, staticKey: aliceKey)
        let bobHandshake = NoiseHandshake(role: .responder, staticKey: bobKey)

        let msg1 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg1)
        let msg2 = try bobHandshake.writeMessage()
        let _ = try aliceHandshake.readMessage(msg2)
        let msg3 = try aliceHandshake.writeMessage()
        let _ = try bobHandshake.readMessage(msg3)

        let aliceResult = try aliceHandshake.finalize()

        XCTAssertEqual(aliceResult.sendCipher.currentNonce, 0)

        let _ = try aliceResult.sendCipher.encrypt(plaintext: Data([0x01]))
        XCTAssertEqual(aliceResult.sendCipher.currentNonce, 1)

        let _ = try aliceResult.sendCipher.encrypt(plaintext: Data([0x02]))
        XCTAssertEqual(aliceResult.sendCipher.currentNonce, 2)

        XCTAssertEqual(aliceResult.sendCipher.messageCount, 2)
    }

    // MARK: - Register Known Static Key

    func testRegisterStaticKeyEnablesIKUpgrade() {
        let localKey = generateStaticKey()
        let remoteKey = generateStaticKey()
        let remotePeerID = peerID(from: remoteKey)

        let manager = NoiseSessionManager(localStaticKey: localKey)

        XCTAssertFalse(manager.canUseIKPattern(for: remotePeerID))

        manager.registerStaticKey(remoteKey.publicKey, for: remotePeerID)

        XCTAssertTrue(manager.canUseIKPattern(for: remotePeerID))
        XCTAssertEqual(
            manager.knownStaticKey(for: remotePeerID)?.rawRepresentation,
            remoteKey.publicKey.rawRepresentation
        )
    }
}
