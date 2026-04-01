import Foundation
import CryptoKit

// MARK: - Errors

public enum NoiseCipherError: Error, Sendable {
    case nonceOverflow
    case decryptionFailed
    case cipherNotInitialized
}

// MARK: - NoiseCipherState

/// Symmetric encryption state for one direction of a Noise transport channel.
///
/// Uses ChaChaPoly (ChaChar20-Poly1305) AEAD with a 64-bit nonce counter.
/// After a Noise XX handshake completes, each side receives a pair of
/// `NoiseCipherState` objects -- one for sending, one for receiving.
///
/// Supports rekey operations per the Noise spec: `REKEY()` replaces the key
/// with `ENCRYPT(k, maxnonce, zerolen, zeros)`.
public final class NoiseCipherState: @unchecked Sendable {

    // MARK: - Properties

    /// The symmetric key (256-bit, ChaChaPoly).
    private var key: SymmetricKey

    /// 64-bit nonce counter, incremented after each encrypt/decrypt.
    private var nonce: UInt64

    /// Number of messages processed (encrypt or decrypt) since last rekey.
    public private(set) var messageCount: UInt64

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Constants

    /// Maximum nonce value before overflow (2^64 - 2; 2^64 - 1 is reserved for rekey).
    private static let maxNonce: UInt64 = UInt64.max - 1
    /// Nonce value used for rekey operation.
    private static let rekeyNonce: UInt64 = UInt64.max

    // MARK: - Init

    /// Create a cipher state with the given key material.
    ///
    /// - Parameter key: 32-byte symmetric key from the Noise handshake.
    public init(key: SymmetricKey) {
        self.key = key
        self.nonce = 0
        self.messageCount = 0
    }

    /// Create a cipher state from raw key bytes.
    public convenience init(keyData: Data) {
        self.init(key: SymmetricKey(data: keyData))
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext message with optional associated data.
    ///
    /// Increments the nonce counter after successful encryption.
    ///
    /// - Parameters:
    ///   - plaintext: The data to encrypt.
    ///   - ad: Optional associated data (authenticated but not encrypted).
    /// - Returns: The ciphertext including the Poly1305 authentication tag.
    public func encrypt(plaintext: Data, ad: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard nonce <= Self.maxNonce else {
            throw NoiseCipherError.nonceOverflow
        }

        let chachaNonce = try makeNonce(nonce)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: chachaNonce,
            authenticating: ad
        )

        nonce += 1
        messageCount += 1

        // ChaChaPoly.seal returns combined ciphertext + tag
        return sealed.ciphertext + sealed.tag
    }

    // MARK: - Decrypt

    /// Decrypt a ciphertext message with optional associated data.
    ///
    /// Increments the nonce counter after successful decryption.
    ///
    /// - Parameters:
    ///   - ciphertext: The ciphertext + 16-byte Poly1305 tag.
    ///   - ad: Optional associated data (must match what was used during encryption).
    /// - Returns: The decrypted plaintext.
    public func decrypt(ciphertext: Data, ad: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard nonce <= Self.maxNonce else {
            throw NoiseCipherError.nonceOverflow
        }

        // Store expected nonce for monotonic validation
        let expectedNonce = nonce

        // ChaChaPoly tag is 16 bytes
        guard ciphertext.count >= 16 else {
            throw NoiseCipherError.decryptionFailed
        }

        let chachaNonce = try makeNonce(expectedNonce)
        let tagOffset = ciphertext.count - 16
        let ct = ciphertext[ciphertext.startIndex ..< ciphertext.startIndex + tagOffset]
        let tag = ciphertext[ciphertext.startIndex + tagOffset ..< ciphertext.endIndex]

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chachaNonce,
            ciphertext: ct,
            tag: tag
        )

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: ad)
        } catch {
            throw NoiseCipherError.decryptionFailed
        }

        // Only increment after successful decryption (monotonic guarantee)
        nonce = expectedNonce + 1
        messageCount += 1

        return plaintext
    }

    // MARK: - Rekey

    /// Perform an in-place rekey as defined by the Noise specification.
    ///
    /// `REKEY()`: `k = ENCRYPT(k, maxnonce, zerolen, zeros)`
    /// where `zeros` is a 32-byte zero plaintext and `zerolen` is empty AD.
    /// The first 32 bytes of the output become the new key.
    public func rekey() throws {
        lock.lock()
        defer { lock.unlock() }

        let rekeyNonce = try makeNonce(Self.rekeyNonce)
        let zeros = Data(repeating: 0, count: 32)
        let sealed = try ChaChaPoly.seal(
            zeros,
            using: key,
            nonce: rekeyNonce,
            authenticating: Data()
        )

        // Take the first 32 bytes of (ciphertext + tag) as the new key
        let combined = sealed.ciphertext + sealed.tag
        var newKeyData = Data(combined.prefix(32))
        key = SymmetricKey(data: newKeyData)

        // Zero intermediate key material to prevent memory scraping
        newKeyData.resetBytes(in: 0..<newKeyData.count)

        // Reset message count (nonce is NOT reset)
        messageCount = 0
    }

    // MARK: - State accessors

    /// The current nonce value (for replay protection tracking).
    public var currentNonce: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nonce
    }

    /// Whether the cipher has been initialized with a key.
    public var isInitialized: Bool {
        true // Always initialized upon construction
    }

    // MARK: - Nonce construction

    /// Build a ChaChaPoly nonce from a 64-bit counter.
    ///
    /// ChaChaPoly uses a 96-bit (12-byte) nonce. We encode the 64-bit counter
    /// as little-endian in the last 8 bytes, with 4 leading zero bytes.
    private func makeNonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var nonceBytes = Data(repeating: 0, count: 12)
        // Little-endian 64-bit counter in bytes 4..11
        let le = counter.littleEndian
        withUnsafeBytes(of: le) { buffer in
            nonceBytes.replaceSubrange(4 ..< 12, with: buffer)
        }
        return try ChaChaPoly.Nonce(data: nonceBytes)
    }
}
