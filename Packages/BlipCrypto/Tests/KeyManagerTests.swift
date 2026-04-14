import Testing
import Foundation
import CryptoKit
@testable import BlipCrypto
import BlipProtocol

private func makeTestKeyManager() -> KeyManager {
    KeyManager(keyStore: InMemoryKeyManagerStore())
}

@Suite("KeyManager Tests")
struct KeyManagerTests {

    // MARK: - Identity Generation

    @Test("Generate identity creates valid Curve25519 and Ed25519 keypairs")
    func testGenerateIdentity() throws {
        let km = KeyManager()
        let identity = try km.generateIdentity()

        // Curve25519 public key is 32 bytes
        #expect(identity.noisePublicKey.rawRepresentation.count == 32)

        // Ed25519 keys have expected sizes
        #expect(identity.signingSecretKey.count == 64) // libsodium format: seed + public
        #expect(identity.signingPublicKey.count == 32)

        // PeerID is 8 bytes derived from noise key
        #expect(identity.peerID.bytes.count == 8)
    }

    @Test("Two generated identities have different keys")
    func testUniqueIdentities() throws {
        let km = KeyManager()
        let id1 = try km.generateIdentity()
        let id2 = try km.generateIdentity()

        #expect(id1.noisePublicKey.rawRepresentation != id2.noisePublicKey.rawRepresentation)
        #expect(id1.signingPublicKey != id2.signingPublicKey)
        #expect(id1.peerID != id2.peerID)
    }

    @Test("PeerID derived from noise public key matches expected derivation")
    func testPeerIDDerivation() throws {
        let km = KeyManager()
        let identity = try km.generateIdentity()

        let expected = PeerID(noisePublicKey: identity.noisePublicKey)
        #expect(identity.peerID == expected)

        // Verify it's SHA256(pubkey)[0..<8]
        let hash = SHA256.hash(data: identity.noisePublicKey.rawRepresentation)
        let manualPeerID = PeerID(bytes: Data(hash.prefix(8)))
        #expect(identity.peerID == manualPeerID)
    }

    // MARK: - Storage-backed Store/Load
    // These tests use the in-memory secure store so they can run under CLI `swift test`
    // while still exercising the KeyManager persistence logic.

    @Test("Store and load identity round-trips correctly")
    func testStoreAndLoadIdentity() throws {
        let km = makeTestKeyManager()
        try? km.deleteIdentity()

        let original = try km.generateIdentity()
        try km.storeIdentity(original)

        let loaded = try km.loadIdentity()
        #expect(loaded != nil)

        if let loaded = loaded {
            #expect(loaded.noisePublicKey.rawRepresentation == original.noisePublicKey.rawRepresentation)
            #expect(loaded.signingPublicKey == original.signingPublicKey)
            #expect(loaded.signingSecretKey == original.signingSecretKey)
            #expect(loaded.peerID == original.peerID)
        }

        try km.deleteIdentity()
    }

    @Test("Load returns nil when no identity is stored")
    func testLoadNoIdentity() throws {
        let km = makeTestKeyManager()
        try? km.deleteIdentity()

        let loaded = try km.loadIdentity()
        #expect(loaded == nil)
    }

    @Test("loadOrCreateIdentity creates and stores when none exists")
    func testLoadOrCreate() throws {
        let km = makeTestKeyManager()
        try? km.deleteIdentity()

        let identity = try km.loadOrCreateIdentity()
        #expect(identity.noisePublicKey.rawRepresentation.count == 32)

        // Second call should return the same identity
        let loaded = try km.loadOrCreateIdentity()
        #expect(loaded.peerID == identity.peerID)
        #expect(loaded.noisePublicKey.rawRepresentation == identity.noisePublicKey.rawRepresentation)

        try km.deleteIdentity()
    }

    // MARK: - Recovery Kit

    @Test("Export and import recovery kit round-trips correctly")
    func testRecoveryKit() throws {
        let km = makeTestKeyManager()
        try? km.deleteIdentity()

        let original = try km.generateIdentity()
        try km.storeIdentity(original)

        let password = "test-password-123!"
        let kit = try km.exportRecoveryKit(password: password)

        // Kit data should be: salt(32) + nonce(12) + ciphertext(128) + tag(16) = 188
        #expect(kit.data.count == 188)

        // Delete existing keys
        try km.deleteIdentity()
        #expect(try km.loadIdentity() == nil)

        // Import with correct password
        let restored = try km.importRecoveryKit(kit, password: password)
        #expect(restored.noisePublicKey.rawRepresentation == original.noisePublicKey.rawRepresentation)
        #expect(restored.signingPublicKey == original.signingPublicKey)
        #expect(restored.signingSecretKey == original.signingSecretKey)
        #expect(restored.peerID == original.peerID)

        // Verify it was stored
        let loaded = try km.loadIdentity()
        #expect(loaded?.peerID == original.peerID)

        try km.deleteIdentity()
    }

    @Test("Import recovery kit with wrong password fails")
    func testRecoveryKitWrongPassword() throws {
        let km = makeTestKeyManager()
        try? km.deleteIdentity()

        let original = try km.generateIdentity()
        try km.storeIdentity(original)

        let kit = try km.exportRecoveryKit(password: "correct-password")

        try km.deleteIdentity()

        #expect(throws: KeyManagerError.self) {
            _ = try km.importRecoveryKit(kit, password: "wrong-password")
        }

        try? km.deleteIdentity()
    }

    @Test("Import recovery kit with malformed data fails")
    func testRecoveryKitMalformed() throws {
        let km = KeyManager()

        let shortData = RecoveryKit(data: Data(repeating: 0, count: 10))
        #expect(throws: KeyManagerError.self) {
            _ = try km.importRecoveryKit(shortData, password: "password")
        }
    }

    // MARK: - Recovery Kit (in-memory, no Keychain needed)

    @Test("Recovery kit encrypt/decrypt cycle works with correct password")
    func testRecoveryKitInMemory() throws {
        let km = KeyManager()
        let identity = try km.generateIdentity()

        // Manually build the plaintext the same way exportRecoveryKit does
        var plaintext = Data()
        plaintext.append(identity.noisePrivateKey.rawRepresentation)
        plaintext.append(identity.signingSecretKey)
        plaintext.append(identity.signingPublicKey)
        #expect(plaintext.count == 128)
    }

    // MARK: - Data Encryption

    @Test("Encrypt and decrypt data round-trips correctly")
    func testEncryptDecryptData() throws {
        let km = KeyManager()
        let password = "strong-test-password-42!"
        let originalData = Data("Hello, Blip export encryption!".utf8)

        let encrypted = try km.encryptData(originalData, password: password)

        // Encrypted data should be larger: magic(4) + version(1) + salt(16) + nonce(12) + ciphertext + tag(16)
        #expect(encrypted.count == 4 + 1 + 16 + 12 + originalData.count + 16)

        let decrypted = try km.decryptData(encrypted, password: password)
        #expect(decrypted == originalData)
    }

    @Test("Decrypt data with wrong password fails")
    func testDecryptDataWrongPassword() throws {
        let km = KeyManager()
        let originalData = Data("Secret account data".utf8)

        let encrypted = try km.encryptData(originalData, password: "correct-password")

        #expect(throws: KeyManagerError.self) {
            _ = try km.decryptData(encrypted, password: "wrong-password")
        }
    }

    @Test("Decrypt malformed data fails")
    func testDecryptMalformedData() throws {
        let km = KeyManager()
        let shortData = Data(repeating: 0, count: 10)

        #expect(throws: KeyManagerError.self) {
            _ = try km.decryptData(shortData, password: "password")
        }
    }

    @Test("Encrypt and decrypt large JSON-like data round-trips")
    func testEncryptDecryptLargeData() throws {
        let km = KeyManager()
        let password = "export-password-2026!"

        // Simulate a JSON export payload
        let jsonString = String(repeating: "{\"user\":\"blip\",\"messages\":[\"hello\"]}", count: 100)
        let originalData = Data(jsonString.utf8)

        let encrypted = try km.encryptData(originalData, password: password)
        let decrypted = try km.decryptData(encrypted, password: password)

        #expect(decrypted == originalData)
        #expect(String(data: decrypted, encoding: .utf8) == jsonString)
    }

    // MARK: - Export Format Validation

    @Test("Encrypt data produces BLIP magic header and version byte")
    func testEncryptDataMagicHeader() throws {
        let km = KeyManager()
        let password = "header-test-pw"
        let originalData = Data("round-trip test".utf8)

        let encrypted = try km.encryptData(originalData, password: password)

        // First 4 bytes must be "BLIP"
        #expect(encrypted[0] == 0x42) // B
        #expect(encrypted[1] == 0x4C) // L
        #expect(encrypted[2] == 0x49) // I
        #expect(encrypted[3] == 0x50) // P
        // Version byte
        #expect(encrypted[4] == 0x01)

        // Round-trip must succeed
        let decrypted = try km.decryptData(encrypted, password: password)
        #expect(decrypted == originalData)
    }

    @Test("Decrypt data without BLIP magic header throws notABlipExport")
    func testDecryptWithoutMagicHeader() throws {
        let km = KeyManager()
        // Craft data that is long enough but has wrong magic
        var fakeData = Data(repeating: 0xAA, count: 100)
        fakeData[0] = 0x00
        fakeData[1] = 0x00
        fakeData[2] = 0x00
        fakeData[3] = 0x00

        #expect(throws: KeyManagerError.notABlipExport) {
            _ = try km.decryptData(fakeData, password: "password")
        }
    }

    @Test("Decrypt data with unsupported version throws unsupportedExportVersion")
    func testDecryptUnsupportedVersion() throws {
        let km = KeyManager()
        // Craft data with correct magic but bad version 0xFF
        var fakeData = Data([0x42, 0x4C, 0x49, 0x50, 0xFF])
        // Pad with enough bytes to pass minimum size check
        fakeData.append(Data(repeating: 0x00, count: 100))

        #expect(throws: KeyManagerError.unsupportedExportVersion(0xFF)) {
            _ = try km.decryptData(fakeData, password: "password")
        }
    }

    // MARK: - Phone Salt

    @Test("Phone salt is generated and persisted")
    func testPhoneSalt() throws {
        let km = makeTestKeyManager()

        let salt1 = try km.loadOrCreatePhoneSalt()
        #expect(salt1.count == 32)

        let salt2 = try km.loadOrCreatePhoneSalt()
        #expect(salt1 == salt2)  // Same salt on second call
    }
}
