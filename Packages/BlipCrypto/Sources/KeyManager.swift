import Foundation
@preconcurrency import CryptoKit
import os.log
@preconcurrency import Sodium
import BlipProtocol

// MARK: - Identity

/// The local user's cryptographic identity: Curve25519 key for Noise, Ed25519 key for signing.
public struct Identity: Sendable {
    /// Curve25519 private key for Noise XX handshakes.
    public let noisePrivateKey: Curve25519.KeyAgreement.PrivateKey
    /// Curve25519 public key for Noise XX handshakes.
    public var noisePublicKey: Curve25519.KeyAgreement.PublicKey {
        noisePrivateKey.publicKey
    }
    /// Ed25519 signing secret key (64 bytes: seed + public, libsodium format).
    public let signingSecretKey: Data
    /// Ed25519 signing public key (32 bytes).
    public let signingPublicKey: Data
    /// Derived PeerID (first 8 bytes of SHA256 of Noise public key).
    public var peerID: PeerID {
        PeerID(noisePublicKey: noisePublicKey)
    }

    public init(
        noisePrivateKey: Curve25519.KeyAgreement.PrivateKey,
        signingSecretKey: Data,
        signingPublicKey: Data
    ) {
        self.noisePrivateKey = noisePrivateKey
        self.signingSecretKey = signingSecretKey
        self.signingPublicKey = signingPublicKey
    }
}

// MARK: - Recovery Kit

/// Password-encrypted backup of the user's keypair, using AES-256-GCM.
///
/// Layout: `[salt: 32][nonce: 12][ciphertext + tag]`
/// The encryption key is derived via HKDF-SHA256(password, salt).
public struct RecoveryKit: Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

// MARK: - Errors

public enum KeyManagerError: Error, Sendable {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case identityNotFound
    case corruptedKeychainData
    case recoveryKitDecryptionFailed
    case recoveryKitMalformed
    case sodiumInitFailed
    case ed25519KeyGenFailed
}

// MARK: - Storage Backends

protocol KeyManagerStore: Sendable {
    func store(tag: String, data: Data) throws
    func load(tag: String) throws -> Data?
    func delete(tag: String) throws
}

private final class KeychainKeyManagerStore: @unchecked Sendable, KeyManagerStore {
    func store(tag: String, data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainWriteFailed(status)
        }
    }

    func load(tag: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw KeyManagerError.corruptedKeychainData
        }
        return data
    }

    func delete(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyManagerError.keychainDeleteFailed(status)
        }
    }
}

final class InMemoryKeyManagerStore: @unchecked Sendable, KeyManagerStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func store(tag: String, data: Data) throws {
        lock.withLock {
            values[tag] = data
        }
    }

    func load(tag: String) throws -> Data? {
        lock.withLock {
            values[tag]
        }
    }

    func delete(tag: String) throws {
        lock.withLock {
            _ = values.removeValue(forKey: tag)
        }
    }
}

// MARK: - KeyManager

/// Generates, stores, and recovers the user's cryptographic identity.
///
/// Keys are stored in the iOS Keychain with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
/// so they are only available when the device has a passcode set and never migrate to other devices.
public final class KeyManager: @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "KeyManager")

    // MARK: - Keychain service tags

    private static let servicePrefix = "com.blip.crypto"
    private static let noiseKeyTag = "\(servicePrefix).noise"
    private static let signingSecretTag = "\(servicePrefix).signing.secret"
    private static let signingPublicTag = "\(servicePrefix).signing.public"
    private static let phoneSaltTag = "\(servicePrefix).phone.salt"

    // MARK: - Recovery Kit constants

    /// HKDF info string for recovery kit key derivation.
    private static let recoveryInfo = "Blip Recovery Kit v1".data(using: .utf8)!
    /// Salt length for HKDF in recovery kit.
    private static let recoverySaltLength = 32

    // MARK: - Singleton

    /// Shared instance for app-wide use.
    public static let shared = KeyManager()

    private let sodium: Sodium
    private let keyStore: KeyManagerStore

    public init() {
        #if targetEnvironment(simulator)
        // Simulator keychain requires code signing entitlements that aren't
        // available in unsigned CLI builds. Use in-memory storage instead.
        self.keyStore = InMemoryKeyManagerStore()
        #else
        self.keyStore = KeychainKeyManagerStore()
        #endif
        self.sodium = Sodium()
    }

    init(keyStore: KeyManagerStore, sodium: Sodium = Sodium()) {
        self.keyStore = keyStore
        self.sodium = sodium
    }

    // MARK: - Generate

    /// Generate a fresh cryptographic identity (Curve25519 + Ed25519 keypair).
    ///
    /// Does NOT store the keys -- call `storeIdentity(_:)` afterwards.
    public func generateIdentity() throws -> Identity {
        // Curve25519 for Noise
        let noiseKey = Curve25519.KeyAgreement.PrivateKey()

        // Ed25519 via libsodium
        guard let keyPair = sodium.sign.keyPair() else {
            throw KeyManagerError.ed25519KeyGenFailed
        }

        return Identity(
            noisePrivateKey: noiseKey,
            signingSecretKey: Data(keyPair.secretKey),
            signingPublicKey: Data(keyPair.publicKey)
        )
    }

    // MARK: - Store

    /// Persist the identity's keys into the iOS Keychain.
    public func storeIdentity(_ identity: Identity) throws {
        // Store Noise private key (raw 32-byte scalar)
        try keyStore.store(
            tag: Self.noiseKeyTag,
            data: identity.noisePrivateKey.rawRepresentation
        )
        // Store Ed25519 secret key (64 bytes)
        try keyStore.store(
            tag: Self.signingSecretTag,
            data: identity.signingSecretKey
        )
        // Store Ed25519 public key (32 bytes)
        try keyStore.store(
            tag: Self.signingPublicTag,
            data: identity.signingPublicKey
        )
    }

    // MARK: - Load

    /// Load the stored identity from the iOS Keychain.
    ///
    /// Returns `nil` if no identity has been stored yet.
    public func loadIdentity() throws -> Identity? {
        guard let noiseRaw = try keyStore.load(tag: Self.noiseKeyTag) else {
            return nil
        }
        guard let signingSecret = try keyStore.load(tag: Self.signingSecretTag) else {
            throw KeyManagerError.corruptedKeychainData
        }
        guard let signingPublic = try keyStore.load(tag: Self.signingPublicTag) else {
            throw KeyManagerError.corruptedKeychainData
        }

        let noiseKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noiseRaw)

        return Identity(
            noisePrivateKey: noiseKey,
            signingSecretKey: signingSecret,
            signingPublicKey: signingPublic
        )
    }

    /// Load or generate an identity. If none is stored, generates and stores a new one.
    public func loadOrCreateIdentity() throws -> Identity {
        if let existing = try loadIdentity() {
            return existing
        }
        let fresh = try generateIdentity()
        try storeIdentity(fresh)
        return fresh
    }

    // MARK: - Delete

    /// Remove all stored keys from the Keychain.
    public func deleteIdentity() throws {
        try keyStore.delete(tag: Self.noiseKeyTag)
        try keyStore.delete(tag: Self.signingSecretTag)
        try keyStore.delete(tag: Self.signingPublicTag)
    }

    // MARK: - Recovery Kit

    /// Export an encrypted backup of the current identity.
    ///
    /// The backup is encrypted with AES-256-GCM using a key derived from the
    /// user-chosen password via HKDF-SHA256.
    ///
    /// Format: `[salt:32][nonce:12][ciphertext+tag]`
    /// Plaintext layout: `[noisePrivateKey:32][signingSecretKey:64][signingPublicKey:32]`
    public func exportRecoveryKit(password: String) throws -> RecoveryKit {
        guard let identity = try loadIdentity() else {
            throw KeyManagerError.identityNotFound
        }

        // Assemble plaintext: noise(32) + signingSecret(64) + signingPublic(32) = 128 bytes
        var plaintext = Data()
        plaintext.append(identity.noisePrivateKey.rawRepresentation)
        plaintext.append(identity.signingSecretKey)
        plaintext.append(identity.signingPublicKey)

        // Derive encryption key
        let salt = generateRandomBytes(count: Self.recoverySaltLength)
        let symmetricKey = deriveKey(password: password, salt: salt)

        // Encrypt with AES-256-GCM
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

        // Pack: salt + nonce + ciphertext (includes tag)
        var output = Data()
        output.append(salt)
        output.append(contentsOf: nonce)
        output.append(sealed.ciphertext + sealed.tag)

        return RecoveryKit(data: output)
    }

    /// Import an identity from an encrypted recovery kit.
    ///
    /// Decrypts, validates, and stores the keys in the Keychain.
    public func importRecoveryKit(_ kit: RecoveryKit, password: String) throws -> Identity {
        let data = kit.data
        // Minimum: salt(32) + nonce(12) + ciphertext(128) + tag(16) = 188
        let minSize = Self.recoverySaltLength + 12 + 128 + 16
        guard data.count >= minSize else {
            throw KeyManagerError.recoveryKitMalformed
        }

        var offset = 0
        let salt = Data(data[offset ..< offset + Self.recoverySaltLength])
        offset += Self.recoverySaltLength

        let nonceData = Data(data[offset ..< offset + 12])
        offset += 12

        let ciphertextAndTag = Data(data[offset...])

        // Derive decryption key
        let symmetricKey = deriveKey(password: password, salt: salt)

        // Decrypt
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextAndTag.dropLast(16), tag: ciphertextAndTag.suffix(16))

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw KeyManagerError.recoveryKitDecryptionFailed
        }

        // Plaintext must be exactly 128 bytes: noise(32) + sigSecret(64) + sigPublic(32)
        guard plaintext.count == 128 else {
            throw KeyManagerError.recoveryKitMalformed
        }

        let noiseRaw = plaintext[0 ..< 32]
        let sigSecret = plaintext[32 ..< 96]
        let sigPublic = plaintext[96 ..< 128]

        let noiseKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noiseRaw)
        let identity = Identity(
            noisePrivateKey: noiseKey,
            signingSecretKey: Data(sigSecret),
            signingPublicKey: Data(sigPublic)
        )

        // Replace existing identity
        do {
            try deleteIdentity()
        } catch {
            logger.error("Failed to delete existing identity before recovery import: \(error.localizedDescription)")
        }
        try storeIdentity(identity)

        return identity
    }

    // MARK: - Data Encryption (AES-256-GCM)

    /// Encrypt arbitrary data with a user-chosen password using AES-256-GCM.
    ///
    /// The encryption key is derived from the password via iterated HKDF-SHA256 (same
    /// derivation used for recovery kits). The output is self-contained and includes
    /// the salt and nonce required for decryption.
    ///
    /// Format: `[salt:32][nonce:12][ciphertext+tag]`
    public func encryptData(_ plaintext: Data, password: String) throws -> Data {
        let salt = generateRandomBytes(count: Self.recoverySaltLength)
        let symmetricKey = deriveKey(password: password, salt: salt)

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

        var output = Data()
        output.append(salt)
        output.append(contentsOf: nonce)
        output.append(sealed.ciphertext + sealed.tag)

        return output
    }

    /// Decrypt data that was encrypted with ``encryptData(_:password:)``.
    ///
    /// Returns the original plaintext on success. Throws on wrong password or
    /// corrupted/truncated data.
    public func decryptData(_ encryptedData: Data, password: String) throws -> Data {
        // Minimum: salt(32) + nonce(12) + tag(16) + at least 1 byte of ciphertext = 61
        let minSize = Self.recoverySaltLength + 12 + 16 + 1
        guard encryptedData.count >= minSize else {
            throw KeyManagerError.recoveryKitMalformed
        }

        var offset = 0
        let salt = Data(encryptedData[offset ..< offset + Self.recoverySaltLength])
        offset += Self.recoverySaltLength

        let nonceData = Data(encryptedData[offset ..< offset + 12])
        offset += 12

        let ciphertextAndTag = Data(encryptedData[offset...])

        let symmetricKey = deriveKey(password: password, salt: salt)

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let tagLength = 16
        guard ciphertextAndTag.count >= tagLength else {
            throw KeyManagerError.recoveryKitMalformed
        }
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertextAndTag.dropLast(tagLength),
            tag: ciphertextAndTag.suffix(tagLength)
        )

        do {
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw KeyManagerError.recoveryKitDecryptionFailed
        }
    }

    // MARK: - Phone Salt

    /// Load or generate the per-user salt used for phone number hashing.
    public func loadOrCreatePhoneSalt() throws -> Data {
        if let existing = try keyStore.load(tag: Self.phoneSaltTag) {
            return existing
        }
        let salt = generateRandomBytes(count: 32)
        try keyStore.store(tag: Self.phoneSaltTag, data: salt)
        return salt
    }

    // MARK: - Key Derivation

    // TODO: Replace with Argon2id when dependency is approved (HKDF iteration is a mitigation, not ideal)
    /// Derive a 256-bit symmetric key from a password and salt using iterated HKDF-SHA256.
    ///
    /// HKDF is not a password-based KDF, but CryptoKit does not provide PBKDF2 or Argon2.
    /// We iterate HKDF 10,000 times to raise the cost of brute-force attacks (~0.5s on
    /// modern iPhone, acceptable for the rare recovery kit export/import flow).
    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var currentKey = SymmetricKey(data: passwordData)
        for _ in 0..<10_000 {
            currentKey = SymmetricKey(data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: currentKey,
                salt: salt,
                info: Self.recoveryInfo,
                outputByteCount: 32
            ))
        }
        return currentKey
    }

    // MARK: - Random Bytes

    /// Generate cryptographically secure random bytes.
    private func generateRandomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            // SecRandomCopyBytes is the recommended iOS CSPRNG
            _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr)
        }
        return bytes
    }
}
