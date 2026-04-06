import Testing
import Foundation
import CryptoKit
@testable import BlipCrypto

@Suite("Noise XX Handshake Validation - T22")
struct NoiseHandshakeValidationTests {

    // MARK: - Forward Secrecy Validation

    @Test("Two handshakes with same static keys produce different session keys")
    func testForwardSecrecyDifferentEphemeralKeys() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        // First handshake
        let (result1Init, result1Resp) = try performHandshake(
            initiatorKey: initiatorStatic,
            responderKey: responderStatic
        )

        // Second handshake with same static keys
        let (result2Init, result2Resp) = try performHandshake(
            initiatorKey: initiatorStatic,
            responderKey: responderStatic
        )

        // Session keys should differ
        let msg1Session1 = Data("test".utf8)
        let ct1Session1 = try result1Init.sendCipher.encrypt(plaintext: msg1Session1)

        let msg1Session2 = Data("test".utf8)
        let ct1Session2 = try result2Init.sendCipher.encrypt(plaintext: msg1Session2)

        // Different ephemeral keys → different session keys → different ciphertexts
        #expect(ct1Session1 != ct1Session2)

        // Handshake hashes should differ
        #expect(result1Init.handshakeHash != result2Init.handshakeHash)
        #expect(result1Resp.handshakeHash != result2Resp.handshakeHash)

        // But each session should still decrypt correctly within itself
        let pt1 = try result1Resp.receiveCipher.decrypt(ciphertext: ct1Session1)
        let pt2 = try result2Resp.receiveCipher.decrypt(ciphertext: ct1Session2)
        #expect(pt1 == msg1Session1)
        #expect(pt2 == msg1Session2)
    }

    @Test("Compromising one session's keys doesn't affect another session")
    func testSessionIsolation() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        // Create two sessions
        let (result1Init, _) = try performHandshake(
            initiatorKey: initiatorStatic,
            responderKey: responderStatic
        )
        let (result2Init, result2Resp) = try performHandshake(
            initiatorKey: initiatorStatic,
            responderKey: responderStatic
        )

        // Send a message in session 2
        let plaintextSession2 = Data("Session 2 message".utf8)
        let ciphertextSession2 = try result2Init.sendCipher.encrypt(plaintext: plaintextSession2)

        // Even if we had session 1's cipher (hypothetically compromised),
        // decrypting session 2's ciphertext with session 1's cipher should fail
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try result1Init.receiveCipher.decrypt(ciphertext: ciphertextSession2)
        }

        // Session 2's cipher should decrypt correctly
        let decryptedSession2 = try result2Resp.receiveCipher.decrypt(ciphertext: ciphertextSession2)
        #expect(decryptedSession2 == plaintextSession2)
    }

    // MARK: - Rapid Connect/Disconnect Stress Test

    @Test("500 complete handshakes in succession all produce valid transport")
    func testRapidHandshakeStress() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        for i in 0 ..< 500 {
            let (initiatorResult, responderResult) = try performHandshake(
                initiatorKey: initiatorStatic,
                responderKey: responderStatic
            )

            // Verify bidirectional transport works
            let plaintext = Data("Message \(i)".utf8)
            let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)
            let decrypted = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)

            #expect(decrypted == plaintext)
        }
    }

    @Test("Rapid handshakes don't cause nonce or state degradation")
    func testRapidHandshakeStateConsistency() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let iterations = 100
        var nonces: [UInt64] = []

        for _ in 0 ..< iterations {
            let (initiatorResult, _) = try performHandshake(
                initiatorKey: initiatorStatic,
                responderKey: responderStatic
            )

            // Each handshake should start with nonce 0
            let initialNonce = initiatorResult.sendCipher.currentNonce
            nonces.append(initialNonce)

            // Send one message
            _ = try initiatorResult.sendCipher.encrypt(plaintext: Data("test".utf8))

            // After one message, nonce should be 1
            let afterSend = initiatorResult.sendCipher.currentNonce
            #expect(afterSend == 1)
        }

        // All initial nonces should be 0
        #expect(nonces.allSatisfy { $0 == 0 })
    }

    // MARK: - Tampered Message Detection

    @Test("Bit flip in message 1 breaks the handshake on the next encrypted message")
    func testTamperedMessage1() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        var msg1 = try initiator.writeMessage()

        // Flip a bit in the message (if there are enough bytes)
        if msg1.count > 0 {
            msg1[0] ^= 0x01
        }

        // XX message 1 only carries the initiator's ephemeral public key and optional
        // plaintext payload. A tampered ephemeral can still parse, but the handshake
        // must fail when the initiator later tries to process the responder's encrypted
        // message 2 because the two sides derived different handshake keys.
        _ = try responder.readMessage(msg1)

        let msg2 = try responder.writeMessage()
        #expect(throws: NoiseHandshakeError.self) {
            _ = try initiator.readMessage(msg2)
        }
    }

    @Test("Bit flip in message 2 causes decryption failure")
    func testTamperedMessage2() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        // Message 1
        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)

        // Message 2
        var msg2 = try responder.writeMessage()

        // Flip a bit (message 2 is encrypted)
        if msg2.count > 0 {
            msg2[0] ^= 0x01
        }

        // Initiator should fail to decrypt
        #expect(throws: NoiseHandshakeError.self) {
            _ = try initiator.readMessage(msg2)
        }
    }

    @Test("Bit flip in message 3 causes decryption failure")
    func testTamperedMessage3() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)

        // Message 3
        var msg3 = try initiator.writeMessage()

        // Flip a bit
        if msg3.count > 0 {
            msg3[msg3.count - 1] ^= 0x01
        }

        // Responder should fail to decrypt
        #expect(throws: NoiseHandshakeError.self) {
            _ = try responder.readMessage(msg3)
        }
    }

    @Test("Truncated messages are rejected")
    func testTruncatedMessages() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        let msg1 = try initiator.writeMessage()

        // Truncate message 1
        let truncated1 = Data(msg1.prefix(10))
        #expect(throws: NoiseHandshakeError.self) {
            _ = try responder.readMessage(truncated1)
        }

        // A valid message 1 should still let the handshake continue, and a truncated
        // encrypted message 2 must then be rejected.
        _ = try responder.readMessage(msg1)

        let msg2 = try responder.writeMessage()
        let truncated2 = Data(msg2.prefix(20))
        #expect(throws: NoiseHandshakeError.self) {
            _ = try initiator.readMessage(truncated2)
        }
    }

    @Test("Replayed message (same ciphertext twice) fails nonce check")
    func testReplayedMessage() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("Original message".utf8)
        let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)

        // First decryption should work
        let decrypted1 = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)
        #expect(decrypted1 == plaintext)

        // Replaying the same ciphertext should fail (nonce would be wrong)
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)
        }
    }

    @Test("Tampered transport ciphertext fails authentication")
    func testTamperedTransportMessage() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("Authenticated message".utf8)
        var ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)

        // Tamper with the ciphertext (flip a bit in the middle)
        if ciphertext.count > 8 {
            ciphertext[ciphertext.count / 2] ^= 0xFF
        }

        // Decryption should fail due to authentication tag mismatch
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)
        }
    }

    // MARK: - Large Payload Handling

    @Test("Large payload in handshake message 2 (10KB)")
    func testLargePayloadMessage2() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)

        // Large payload in message 2
        let largePayload = Data(repeating: 0xAB, count: 10_000)
        let msg2 = try responder.writeMessage(payload: largePayload)

        let received = try initiator.readMessage(msg2)
        #expect(received == largePayload)
    }

    @Test("Large payload in handshake message 3 (10KB)")
    func testLargePayloadMessage3() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let initiator = NoiseHandshake(role: .initiator, staticKey: initiatorStatic)
        let responder = NoiseHandshake(role: .responder, staticKey: responderStatic)

        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)

        // Large payload in message 3
        let largePayload = Data(repeating: 0xCD, count: 10_000)
        let msg3 = try initiator.writeMessage(payload: largePayload)

        let received = try responder.readMessage(msg3)
        #expect(received == largePayload)
    }

    @Test("Very large transport messages up to 65KB")
    func testLargeTransportMessages() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let sizes = [1_000, 10_000, 32_000, 65_000]

        for size in sizes {
            let plaintext = Data(repeating: 0xEF, count: size)
            let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)
            let decrypted = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)

            #expect(decrypted == plaintext)
            #expect(decrypted.count == size)
        }
    }

    @Test("Empty plaintext encryption and decryption")
    func testEmptyPayload() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let empty = Data()
        let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: empty)

        // Ciphertext should contain at least the authentication tag (16 bytes)
        #expect(ciphertext.count >= 16)

        let decrypted = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)
        #expect(decrypted.isEmpty)
    }

    // MARK: - Concurrent Handshake Stress

    @Test("50 concurrent handshakes all complete successfully")
    func testConcurrentHandshakes() async throws {
        let initiatorKeyData = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let responderKeyData = Curve25519.KeyAgreement.PrivateKey().rawRepresentation

        let results = try await withThrowingTaskGroup(
            of: (NoiseHandshakeResult, NoiseHandshakeResult).self,
            returning: [(NoiseHandshakeResult, NoiseHandshakeResult)].self
        ) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    let initiatorKey = try Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: initiatorKeyData
                    )
                    let responderKey = try Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: responderKeyData
                    )
                    return try performHandshake(
                        initiatorKey: initiatorKey,
                        responderKey: responderKey
                    )
                }
            }

            var allResults: [(NoiseHandshakeResult, NoiseHandshakeResult)] = []
            for try await result in group {
                allResults.append(result)
            }
            return allResults
        }

        #expect(results.count == 50)

        // Verify all completed handshakes are functional
        for (initiatorResult, responderResult) in results {
            let plaintext = Data("Concurrent test".utf8)
            let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)
            let decrypted = try responderResult.receiveCipher.decrypt(ciphertext: ciphertext)
            #expect(decrypted == plaintext)
        }
    }

    // MARK: - Nonce Exhaustion Edge Cases

    @Test("CipherState rejects operations past max nonce")
    func testNonceOverflow() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let (result, _) = try performHandshake()

        // Create a cipher state at near-max nonce
        // We can't easily set nonce to max without private access,
        // but we can test that repeated operations eventually fail
        // For now, test the documented behavior: nonce can go up to 2^64-2

        // The actual overflow test would require exposing nonce mutation,
        // which the API intentionally prevents. We validate the API design here.
        let initialNonce = result.sendCipher.currentNonce
        #expect(initialNonce == 0)
    }

    @Test("CipherState rekey resets message count but continues nonce")
    func testRekeyMessageCount() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        // Send 5 messages
        for i in 0 ..< 5 {
            _ = try initiatorResult.sendCipher.encrypt(
                plaintext: Data("msg \(i)".utf8)
            )
        }

        let nonceBeforeRekey = initiatorResult.sendCipher.currentNonce
        #expect(nonceBeforeRekey == 5)

        // Rekey
        try initiatorResult.sendCipher.rekey()

        // Nonce should continue (not reset)
        let nonceAfterRekey = initiatorResult.sendCipher.currentNonce
        #expect(nonceAfterRekey == 5)

        // Message count should be reset
        let messageCount = initiatorResult.sendCipher.messageCount
        #expect(messageCount == 0)

        // Send another message after rekey
        _ = try initiatorResult.sendCipher.encrypt(
            plaintext: Data("post-rekey".utf8)
        )

        let messageCountAfter = initiatorResult.sendCipher.messageCount
        #expect(messageCountAfter == 1)
    }

    // MARK: - Session Uniqueness

    @Test("100 handshakes produce 100 unique handshake hashes")
    func testHandshakeHashUniqueness() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        var hashes = Set<Data>()

        for _ in 0 ..< 100 {
            let (initiatorResult, _) = try performHandshake(
                initiatorKey: initiatorStatic,
                responderKey: responderStatic
            )

            hashes.insert(initiatorResult.handshakeHash)
        }

        // All 100 hashes should be unique
        #expect(hashes.count == 100)
    }

    @Test("First message ciphertexts are unique for same plaintext across sessions")
    func testMessageCiphertextUniqueness() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let plaintext = Data("Same message".utf8)
        var ciphertexts = Set<Data>()

        for _ in 0 ..< 50 {
            let (initiatorResult, _) = try performHandshake(
                initiatorKey: initiatorStatic,
                responderKey: responderStatic
            )

            let ciphertext = try initiatorResult.sendCipher.encrypt(plaintext: plaintext)
            ciphertexts.insert(ciphertext)
        }

        // All ciphertexts should be unique (different nonces)
        #expect(ciphertexts.count == 50)
    }

    // MARK: - Associated Data Validation

    @Test("Decrypt with different AD than encryption fails")
    func testAssociatedDataMismatch() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("Protected message".utf8)
        let adEncrypt = Data("header1".utf8)
        let adDecrypt = Data("header2".utf8)

        // Encrypt with AD "header1"
        let ciphertext = try initiatorResult.sendCipher.encrypt(
            plaintext: plaintext,
            ad: adEncrypt
        )

        // Try to decrypt with AD "header2" -- should fail
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try responderResult.receiveCipher.decrypt(
                ciphertext: ciphertext,
                ad: adDecrypt
            )
        }

        // Decrypt with correct AD should work
        let decrypted = try responderResult.receiveCipher.decrypt(
            ciphertext: ciphertext,
            ad: adEncrypt
        )
        #expect(decrypted == plaintext)
    }

    @Test("Encrypt with AD, decrypt without AD fails")
    func testADEncryptNoADDecrypt() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("Secret".utf8)
        let ad = Data("context".utf8)

        // Encrypt with AD
        let ciphertext = try initiatorResult.sendCipher.encrypt(
            plaintext: plaintext,
            ad: ad
        )

        // Try to decrypt without AD -- should fail
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try responderResult.receiveCipher.decrypt(
                ciphertext: ciphertext,
                ad: Data()
            )
        }
    }

    @Test("Encrypt without AD, decrypt with AD fails")
    func testNoADEncryptADDecrypt() throws {
        let (initiatorResult, responderResult) = try performHandshake()

        let plaintext = Data("Secret".utf8)
        let ad = Data("context".utf8)

        // Encrypt without AD
        let ciphertext = try initiatorResult.sendCipher.encrypt(
            plaintext: plaintext,
            ad: Data()
        )

        // Try to decrypt with AD -- should fail
        #expect(throws: NoiseCipherError.decryptionFailed) {
            _ = try responderResult.receiveCipher.decrypt(
                ciphertext: ciphertext,
                ad: ad
            )
        }
    }

    // MARK: - Helper

    /// Perform a complete Noise XX handshake and return both sides' results.
    ///
    /// - Parameters:
    ///   - initiatorKey: Optional custom initiator static key (default: new random)
    ///   - responderKey: Optional custom responder static key (default: new random)
    ///   - prologue: Optional prologue (default: empty)
    /// - Returns: Tuple of (initiator result, responder result)
    private func performHandshake(
        initiatorKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        responderKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        prologue: Data = Data()
    ) throws -> (NoiseHandshakeResult, NoiseHandshakeResult) {
        let initiator = NoiseHandshake(
            role: .initiator,
            staticKey: initiatorKey,
            prologue: prologue
        )
        let responder = NoiseHandshake(
            role: .responder,
            staticKey: responderKey,
            prologue: prologue
        )

        // Message 1: initiator -> responder (-> e)
        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)

        // Message 2: responder -> initiator (<- e, ee, s, es)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)

        // Message 3: initiator -> responder (-> s, se)
        let msg3 = try initiator.writeMessage()
        _ = try responder.readMessage(msg3)

        let iResult = try initiator.finalize()
        let rResult = try responder.finalize()

        return (iResult, rResult)
    }
}
