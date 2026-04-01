import Foundation
import CryptoKit
import BlipProtocol

// MARK: - Errors

public enum SenderKeyError: Error, Sendable {
    case keyNotFound(channelID: Data)
    case encryptionFailed
    case decryptionFailed
    case invalidKeyData
}

// MARK: - GroupSenderKey

/// An AES-256-GCM sender key for group message encryption.
///
/// Each member of a group generates their own sender key and distributes it
/// to all other members via pairwise Noise-encrypted channels. When sending
/// a group message, the sender encrypts with their own key; receivers look up
/// the sender's key to decrypt.
public struct GroupSenderKey: Sendable, Codable, Equatable {

    /// Unique identifier for this key (random 16 bytes).
    public let keyID: Data

    /// The 256-bit AES-GCM key material.
    public let keyMaterial: Data

    /// The channel/group this key belongs to.
    public let channelID: Data

    /// PeerID of the key's creator.
    public let senderPeerID: PeerID

    /// Generation number (incremented on each rotation).
    public let generation: UInt32

    /// When this key was created.
    public let createdAt: Date

    /// Number of messages encrypted with this key.
    public private(set) var messageCount: UInt32

    /// Maximum messages before mandatory rotation.
    public static let maxMessages: UInt32 = 100

    /// Whether this key has exceeded its message limit.
    public var needsRotation: Bool {
        messageCount >= Self.maxMessages
    }

    // MARK: - Init

    public init(
        keyID: Data,
        keyMaterial: Data,
        channelID: Data,
        senderPeerID: PeerID,
        generation: UInt32,
        createdAt: Date = Date(),
        messageCount: UInt32 = 0
    ) {
        self.keyID = keyID
        self.keyMaterial = keyMaterial
        self.channelID = channelID
        self.senderPeerID = senderPeerID
        self.generation = generation
        self.createdAt = createdAt
        self.messageCount = messageCount
    }

    /// Increment the message count.
    public mutating func incrementMessageCount() {
        messageCount += 1
    }
}

// MARK: - SenderKeyRotationReason

/// Reasons for rotating a group sender key.
public enum SenderKeyRotationReason: Sendable {
    /// A member was added to the group.
    case memberAdded
    /// A member was removed from the group.
    case memberRemoved
    /// The message count threshold was reached.
    case messageLimit
    /// Manual rotation requested.
    case manual
}

// MARK: - SenderKeyManager

/// Manages AES-256-GCM sender keys for group chat encryption.
///
/// Each group member maintains their own sender key. Keys are rotated when:
/// - A member joins or leaves the group
/// - 100 messages have been encrypted with the current key
///
/// Sender keys are distributed to group members via pairwise Noise-encrypted channels.
public final class SenderKeyManager: @unchecked Sendable {

    // MARK: - State

    /// Our sender keys keyed by channelID.
    private var ourKeys: [Data: GroupSenderKey] = [:]

    /// Other members' sender keys keyed by (channelID, senderPeerID).
    private var peerKeys: [SenderKeyLookup: GroupSenderKey] = [:]

    /// Our local PeerID.
    private let localPeerID: PeerID

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Init

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
    }

    // MARK: - Key Generation

    /// Create a new sender key for a channel/group.
    ///
    /// If a key already exists for this channel, it is replaced with a new
    /// generation. The old key is kept briefly in `peerKeys` for decrypting
    /// any in-flight messages.
    ///
    /// - Parameter channelID: The identifier of the channel or group.
    /// - Returns: The newly generated sender key.
    @discardableResult
    public func createKey(forChannel channelID: Data) -> GroupSenderKey {
        lock.lock()
        defer { lock.unlock() }

        let existingGeneration = ourKeys[channelID]?.generation ?? 0
        let newGeneration = existingGeneration + (ourKeys[channelID] != nil ? 1 : 0)

        // Move old key to peer keys for in-flight decryption
        if let oldKey = ourKeys[channelID] {
            let lookup = SenderKeyLookup(channelID: channelID, peerID: localPeerID)
            peerKeys[lookup] = oldKey
        }

        let key = GroupSenderKey(
            keyID: generateRandomBytes(count: 16),
            keyMaterial: generateRandomBytes(count: 32),
            channelID: channelID,
            senderPeerID: localPeerID,
            generation: newGeneration
        )

        ourKeys[channelID] = key
        return key
    }

    /// Rotate the sender key for a channel due to the given reason.
    ///
    /// - Parameters:
    ///   - channelID: The channel to rotate the key for.
    ///   - reason: Why the rotation is happening.
    /// - Returns: The new sender key, or `nil` if no key exists for this channel.
    @discardableResult
    public func rotateKey(forChannel channelID: Data, reason: SenderKeyRotationReason) -> GroupSenderKey? {
        lock.lock()
        defer { lock.unlock() }
        return rotateKeyLocked(forChannel: channelID)
    }

    /// Internal rotation that assumes the lock is already held.
    private func rotateKeyLocked(forChannel channelID: Data) -> GroupSenderKey? {
        guard let existing = ourKeys[channelID] else { return nil }

        // Archive old key
        let lookup = SenderKeyLookup(channelID: channelID, peerID: localPeerID)
        peerKeys[lookup] = existing

        let newKey = GroupSenderKey(
            keyID: generateRandomBytes(count: 16),
            keyMaterial: generateRandomBytes(count: 32),
            channelID: channelID,
            senderPeerID: localPeerID,
            generation: existing.generation + 1
        )

        ourKeys[channelID] = newKey
        return newKey
    }

    // MARK: - Key Storage (peer keys)

    /// Store a sender key received from another group member.
    public func storePeerKey(_ key: GroupSenderKey) {
        lock.lock()
        defer { lock.unlock() }

        let lookup = SenderKeyLookup(channelID: key.channelID, peerID: key.senderPeerID)
        peerKeys[lookup] = key
    }

    /// Retrieve a peer's sender key for a channel.
    public func getPeerKey(channelID: Data, senderPeerID: PeerID) -> GroupSenderKey? {
        lock.lock()
        defer { lock.unlock() }

        let lookup = SenderKeyLookup(channelID: channelID, peerID: senderPeerID)
        return peerKeys[lookup]
    }

    /// Get our current sender key for a channel.
    public func getOurKey(forChannel channelID: Data) -> GroupSenderKey? {
        lock.lock()
        defer { lock.unlock() }
        return ourKeys[channelID]
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext group message using our sender key for the channel.
    ///
    /// Format: `[keyID:16][nonce:12][ciphertext+tag]`
    ///
    /// Automatically rotates the key if the message limit is reached.
    ///
    /// - Parameters:
    ///   - plaintext: The message data to encrypt.
    ///   - channelID: The channel to encrypt for.
    /// - Returns: A tuple of the encrypted data and the key (for distribution if rotated).
    public func encrypt(plaintext: Data, forChannel channelID: Data) throws -> (ciphertext: Data, key: GroupSenderKey) {
        lock.lock()
        defer { lock.unlock() }

        guard var senderKey = ourKeys[channelID] else {
            throw SenderKeyError.keyNotFound(channelID: channelID)
        }

        // Check if rotation is needed — rotate while still holding the lock
        if senderKey.needsRotation {
            guard let rotated = rotateKeyLocked(forChannel: channelID) else {
                throw SenderKeyError.keyNotFound(channelID: channelID)
            }
            senderKey = rotated
        }

        senderKey.incrementMessageCount()
        ourKeys[channelID] = senderKey

        // Encrypt with AES-256-GCM
        let symmetricKey = SymmetricKey(data: senderKey.keyMaterial)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

        var output = Data()
        output.append(senderKey.keyID)        // 16 bytes
        output.append(contentsOf: nonce)      // 12 bytes
        output.append(sealed.ciphertext)
        output.append(sealed.tag)             // 16 bytes

        return (output, senderKey)
    }

    // MARK: - Decrypt

    /// Decrypt a group message using the sender's key.
    ///
    /// Format: `[keyID:16][nonce:12][ciphertext+tag]`
    ///
    /// - Parameters:
    ///   - ciphertext: The encrypted message data.
    ///   - channelID: The channel the message belongs to.
    ///   - senderPeerID: The PeerID of the sender.
    /// - Returns: The decrypted plaintext.
    public func decrypt(ciphertext: Data, channelID: Data, senderPeerID: PeerID) throws -> Data {
        // Minimum: keyID(16) + nonce(12) + tag(16) = 44
        guard ciphertext.count >= 44 else {
            throw SenderKeyError.decryptionFailed
        }

        let keyID = Data(ciphertext[0 ..< 16])
        let nonceData = Data(ciphertext[16 ..< 28])
        let encryptedData = Data(ciphertext[28...])

        // Look up the key -- first check if it's our own key, then peer keys
        let senderKey: GroupSenderKey
        if senderPeerID == localPeerID {
            lock.lock()
            if let ourKey = ourKeys[channelID], ourKey.keyID == keyID {
                senderKey = ourKey
            } else {
                let lookup = SenderKeyLookup(channelID: channelID, peerID: senderPeerID)
                guard let archived = peerKeys[lookup], archived.keyID == keyID else {
                    lock.unlock()
                    throw SenderKeyError.keyNotFound(channelID: channelID)
                }
                senderKey = archived
            }
            lock.unlock()
        } else {
            lock.lock()
            let lookup = SenderKeyLookup(channelID: channelID, peerID: senderPeerID)
            guard let peerKey = peerKeys[lookup], peerKey.keyID == keyID else {
                lock.unlock()
                throw SenderKeyError.keyNotFound(channelID: channelID)
            }
            senderKey = peerKey
            lock.unlock()
        }

        // Decrypt with AES-256-GCM
        guard encryptedData.count >= 16 else {
            throw SenderKeyError.decryptionFailed
        }

        let symmetricKey = SymmetricKey(data: senderKey.keyMaterial)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ct = encryptedData.dropLast(16)
        let tag = encryptedData.suffix(16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)

        do {
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw SenderKeyError.decryptionFailed
        }
    }

    // MARK: - Cleanup

    /// Remove all keys for a channel (e.g., when leaving a group).
    public func removeKeys(forChannel channelID: Data) {
        lock.lock()
        defer { lock.unlock() }

        ourKeys.removeValue(forKey: channelID)
        peerKeys = peerKeys.filter { $0.key.channelID != channelID }
    }

    /// Remove a specific peer's key for a channel (e.g., when they leave the group).
    public func removePeerKey(channelID: Data, peerID: PeerID) {
        lock.lock()
        defer { lock.unlock() }

        let lookup = SenderKeyLookup(channelID: channelID, peerID: peerID)
        peerKeys.removeValue(forKey: lookup)
    }

    // MARK: - Helpers

    private func generateRandomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr)
        }
        return bytes
    }
}

// MARK: - SenderKeyLookup

/// Composite key for looking up peer sender keys.
private struct SenderKeyLookup: Hashable {
    let channelID: Data
    let peerID: PeerID
}
