import Foundation
import CryptoKit

// MARK: - Noise Protocol Constants

/// Protocol name for Noise_XX_25519_ChaChaPoly_SHA256.
private let noiseProtocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
/// Empty key (all zeros, 32 bytes) representing an uninitialized key in the Noise spec.
private let emptyKey = Data(repeating: 0, count: 32)
/// DH output length for Curve25519 (32 bytes).
private let dhLen = 32
/// Hash output length for SHA-256 (32 bytes).
private let hashLen = 32

// MARK: - Errors

public enum NoiseHandshakeError: Error, Sendable {
    case invalidState(String)
    case messageDecryptionFailed
    case messageTooShort
    case dhFailed
    case invalidPublicKey
    case handshakeNotComplete
    case unexpectedMessageLength
}

// MARK: - Handshake Role

/// The role of this party in the handshake.
public enum NoiseRole: Sendable {
    case initiator
    case responder
}

// MARK: - Handshake Result

/// The result of a completed Noise XX handshake: two cipher states for bidirectional
/// encrypted transport, plus the remote peer's authenticated static public key.
public struct NoiseHandshakeResult: Sendable {
    /// Cipher state for encrypting messages we send.
    public let sendCipher: NoiseCipherState
    /// Cipher state for decrypting messages we receive.
    public let receiveCipher: NoiseCipherState
    /// The remote peer's static Curve25519 public key (authenticated by the handshake).
    public let remoteStaticKey: Curve25519.KeyAgreement.PublicKey
    /// The handshake hash `h`, which uniquely identifies this session.
    public let handshakeHash: Data
}

// MARK: - SymmetricState

/// Internal Noise SymmetricState per the spec.
///
/// Manages the chaining key `ck`, handshake hash `h`, and the embedded CipherState `k`/`n`.
private final class SymmetricState {
    var ck: Data      // Chaining key (32 bytes)
    var h: Data       // Handshake hash (32 bytes)
    var hasKey: Bool   // Whether CipherState has a key
    var k: Data       // CipherState key (32 bytes or empty)
    var n: UInt64     // CipherState nonce

    /// Initialize with a protocol name per the Noise spec.
    ///
    /// If the name fits in hashLen bytes, pad with zeros; otherwise hash it.
    init(protocolName: String) {
        let nameData = Data(protocolName.utf8)
        if nameData.count <= hashLen {
            var padded = nameData
            padded.append(Data(repeating: 0, count: hashLen - nameData.count))
            self.h = padded
        } else {
            self.h = Data(SHA256.hash(data: nameData))
        }
        self.ck = h
        self.hasKey = false
        self.k = emptyKey
        self.n = 0
    }

    /// MixKey: HKDF(ck, inputKeyMaterial) -> (ck, tempK)
    func mixKey(_ inputKeyMaterial: Data) {
        let (newCK, tempK) = hkdfSHA256(chainingKey: ck, inputKeyMaterial: inputKeyMaterial)
        ck = newCK
        k = tempK
        n = 0
        hasKey = true
    }

    /// MixHash: h = HASH(h || data)
    func mixHash(_ data: Data) {
        var combined = h
        combined.append(data)
        h = Data(SHA256.hash(data: combined))
    }

    /// MixKeyAndHash: used by PSK patterns, not needed for XX but included for completeness.
    func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let (tempK1, tempK2, tempK3) = hkdf3SHA256(chainingKey: ck, inputKeyMaterial: inputKeyMaterial)
        ck = tempK1
        mixHash(tempK2)
        k = tempK3
        n = 0
        hasKey = true
    }

    /// EncryptAndHash: if we have a key, encrypt plaintext; otherwise pass through.
    func encryptAndHash(_ plaintext: Data) throws -> Data {
        if hasKey {
            let ciphertext = try aeadEncrypt(key: k, nonce: n, ad: h, plaintext: plaintext)
            mixHash(ciphertext)
            n += 1
            return ciphertext
        } else {
            mixHash(plaintext)
            return plaintext
        }
    }

    /// DecryptAndHash: if we have a key, decrypt ciphertext; otherwise pass through.
    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        if hasKey {
            let plaintext = try aeadDecrypt(key: k, nonce: n, ad: h, ciphertext: ciphertext)
            mixHash(ciphertext)
            n += 1
            return plaintext
        } else {
            mixHash(ciphertext)
            return ciphertext
        }
    }

    /// Split: derive two CipherState objects from the final chaining key.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (tempK1, tempK2) = hkdfSHA256(chainingKey: ck, inputKeyMaterial: Data())
        let c1 = NoiseCipherState(keyData: tempK1)
        let c2 = NoiseCipherState(keyData: tempK2)
        return (c1, c2)
    }
}

// MARK: - HandshakeState

/// A Noise_XX_25519_ChaChaPoly_SHA256 handshake state machine.
///
/// The XX pattern:
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se
/// ```
///
/// Message 1 (initiator -> responder): initiator sends ephemeral public key.
/// Message 2 (responder -> initiator): responder sends ephemeral + encrypted static.
/// Message 3 (initiator -> responder): initiator sends encrypted static.
///
/// After 3 messages, both sides have mutually authenticated static keys and
/// derive bidirectional transport cipher states with forward secrecy.
public final class NoiseHandshake: @unchecked Sendable {

    // MARK: - State

    public let role: NoiseRole
    private let symmetricState: SymmetricState

    /// Our static keypair (long-term identity).
    private let s: Curve25519.KeyAgreement.PrivateKey

    /// Our ephemeral keypair (generated fresh for this handshake).
    private var e: Curve25519.KeyAgreement.PrivateKey?

    /// Remote static public key (learned during handshake).
    private var rs: Curve25519.KeyAgreement.PublicKey?

    /// Remote ephemeral public key (learned during handshake).
    private var re: Curve25519.KeyAgreement.PublicKey?

    /// Current handshake message index (0, 1, or 2).
    private var messageIndex: Int = 0

    /// Whether the handshake is complete.
    public private(set) var isComplete: Bool = false

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Init

    /// Create a new Noise XX handshake.
    ///
    /// - Parameters:
    ///   - role: Whether this party is the initiator or responder.
    ///   - staticKey: The local party's long-term Curve25519 private key.
    ///   - prologue: Optional prologue data mixed into the handshake hash.
    public init(
        role: NoiseRole,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        prologue: Data = Data()
    ) {
        self.role = role
        self.s = staticKey
        self.symmetricState = SymmetricState(protocolName: noiseProtocolName)
        // MixHash(prologue)
        symmetricState.mixHash(prologue)
    }

    // MARK: - Public API

    /// Write the next handshake message.
    ///
    /// Call this in sequence:
    /// - Initiator calls: writeMessage(payload:) for message 1, then message 3
    /// - Responder calls: writeMessage(payload:) for message 2
    ///
    /// - Parameter payload: Optional payload to include (encrypted if a key has been established).
    /// - Returns: The handshake message bytes to send to the remote party.
    public func writeMessage(payload: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        switch (role, messageIndex) {
        case (.initiator, 0):
            return try writeMessage1(payload: payload)
        case (.responder, 1):
            return try writeMessage2(payload: payload)
        case (.initiator, 2):
            return try writeMessage3(payload: payload)
        default:
            throw NoiseHandshakeError.invalidState(
                "Cannot write message at index \(messageIndex) as \(role)"
            )
        }
    }

    /// Read and process a handshake message received from the remote party.
    ///
    /// Call this in sequence:
    /// - Responder calls: readMessage(_:) for message 1, then message 3
    /// - Initiator calls: readMessage(_:) for message 2
    ///
    /// - Parameter message: The handshake message bytes received.
    /// - Returns: Any payload included in the message.
    public func readMessage(_ message: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        switch (role, messageIndex) {
        case (.responder, 0):
            return try readMessage1(message)
        case (.initiator, 1):
            return try readMessage2(message)
        case (.responder, 2):
            return try readMessage3(message)
        default:
            throw NoiseHandshakeError.invalidState(
                "Cannot read message at index \(messageIndex) as \(role)"
            )
        }
    }

    /// Finalize the handshake and extract the transport cipher states.
    ///
    /// Only callable after all 3 messages have been exchanged.
    public func finalize() throws -> NoiseHandshakeResult {
        lock.lock()
        defer { lock.unlock() }

        guard isComplete else {
            throw NoiseHandshakeError.handshakeNotComplete
        }
        guard let remoteStatic = rs else {
            throw NoiseHandshakeError.handshakeNotComplete
        }

        let (c1, c2) = symmetricState.split()

        let sendCipher: NoiseCipherState
        let receiveCipher: NoiseCipherState

        switch role {
        case .initiator:
            // Initiator sends with c1, receives with c2
            sendCipher = c1
            receiveCipher = c2
        case .responder:
            // Responder sends with c2, receives with c1
            sendCipher = c2
            receiveCipher = c1
        }

        return NoiseHandshakeResult(
            sendCipher: sendCipher,
            receiveCipher: receiveCipher,
            remoteStaticKey: remoteStatic,
            handshakeHash: symmetricState.h
        )
    }

    // MARK: - Message 1: -> e

    /// Initiator writes message 1: sends ephemeral public key.
    private func writeMessage1(payload: Data) throws -> Data {
        var message = Data()

        // Generate ephemeral keypair
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        e = ephemeral

        // -> e: send ephemeral public key
        let ePub = ephemeral.publicKey.rawRepresentation
        message.append(ePub)
        symmetricState.mixHash(ePub)

        // Encrypt and append payload
        let encPayload = try symmetricState.encryptAndHash(payload)
        message.append(encPayload)

        messageIndex = 1
        return message
    }

    /// Responder reads message 1: receives initiator's ephemeral key.
    private func readMessage1(_ message: Data) throws -> Data {
        guard message.count >= dhLen else {
            throw NoiseHandshakeError.messageTooShort
        }

        // <- e: read initiator's ephemeral public key
        let ePubData = Data(message[0 ..< dhLen])
        re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        symmetricState.mixHash(ePubData)

        // Decrypt payload
        let payloadData = Data(message[dhLen...])
        let payload = try symmetricState.decryptAndHash(payloadData)

        messageIndex = 1
        return payload
    }

    // MARK: - Message 2: <- e, ee, s, es

    /// Responder writes message 2: ephemeral key, DH operations, encrypted static key.
    private func writeMessage2(payload: Data) throws -> Data {
        var message = Data()

        // Generate ephemeral keypair
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        e = ephemeral

        // <- e: send ephemeral public key
        let ePub = ephemeral.publicKey.rawRepresentation
        message.append(ePub)
        symmetricState.mixHash(ePub)

        // ee: DH(e, re)
        guard let remoteE = re else {
            throw NoiseHandshakeError.invalidState("Missing remote ephemeral for ee DH")
        }
        let ee = try performDH(privateKey: ephemeral, publicKey: remoteE)
        symmetricState.mixKey(ee)

        // s: send encrypted static public key
        let sPub = s.publicKey.rawRepresentation
        let encS = try symmetricState.encryptAndHash(sPub)
        message.append(encS)

        // es: DH(s, re)
        let es = try performDH(privateKey: s, publicKey: remoteE)
        symmetricState.mixKey(es)

        // Encrypt and append payload
        let encPayload = try symmetricState.encryptAndHash(payload)
        message.append(encPayload)

        messageIndex = 2
        return message
    }

    /// Initiator reads message 2: processes responder's ephemeral, DH, and encrypted static.
    private func readMessage2(_ message: Data) throws -> Data {
        var offset = 0

        // <- e: read responder's ephemeral public key
        guard message.count >= offset + dhLen else {
            throw NoiseHandshakeError.messageTooShort
        }
        let ePubData = Data(message[offset ..< offset + dhLen])
        re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        symmetricState.mixHash(ePubData)
        offset += dhLen

        // ee: DH(e, re)
        guard let localE = e, let remoteE = re else {
            throw NoiseHandshakeError.invalidState("Missing keys for ee DH")
        }
        let ee = try performDH(privateKey: localE, publicKey: remoteE)
        symmetricState.mixKey(ee)

        // s: read encrypted static public key (32 bytes + 16 byte tag = 48 bytes)
        let encSLen = dhLen + 16  // encrypted static = pubkey + AEAD tag
        guard message.count >= offset + encSLen else {
            throw NoiseHandshakeError.messageTooShort
        }
        let encS = Data(message[offset ..< offset + encSLen])
        let sPubData = try symmetricState.decryptAndHash(encS)
        rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sPubData)
        offset += encSLen

        // es: DH(e, rs) -- initiator uses own ephemeral with responder's static
        guard let remoteS = rs else {
            throw NoiseHandshakeError.invalidState("Missing remote static for es DH")
        }
        let es = try performDH(privateKey: localE, publicKey: remoteS)
        symmetricState.mixKey(es)

        // Decrypt payload
        let payloadData = Data(message[offset...])
        let payload = try symmetricState.decryptAndHash(payloadData)

        messageIndex = 2
        return payload
    }

    // MARK: - Message 3: -> s, se

    /// Initiator writes message 3: encrypted static key and final DH.
    private func writeMessage3(payload: Data) throws -> Data {
        var message = Data()

        // s: send encrypted static public key
        let sPub = s.publicKey.rawRepresentation
        let encS = try symmetricState.encryptAndHash(sPub)
        message.append(encS)

        // se: DH(s, re)
        guard let remoteE = re else {
            throw NoiseHandshakeError.invalidState("Missing remote ephemeral for se DH")
        }
        let se = try performDH(privateKey: s, publicKey: remoteE)
        symmetricState.mixKey(se)

        // Encrypt and append payload
        let encPayload = try symmetricState.encryptAndHash(payload)
        message.append(encPayload)

        isComplete = true
        messageIndex = 3
        return message
    }

    /// Responder reads message 3: processes initiator's encrypted static and final DH.
    private func readMessage3(_ message: Data) throws -> Data {
        var offset = 0

        // s: read encrypted static public key (32 + 16 = 48 bytes)
        let encSLen = dhLen + 16
        guard message.count >= offset + encSLen else {
            throw NoiseHandshakeError.messageTooShort
        }
        let encS = Data(message[offset ..< offset + encSLen])
        let sPubData = try symmetricState.decryptAndHash(encS)
        rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sPubData)
        offset += encSLen

        // se: DH(e, rs) -- responder uses own ephemeral with initiator's static
        guard let localE = e, let remoteS = rs else {
            throw NoiseHandshakeError.invalidState("Missing keys for se DH")
        }
        let se = try performDH(privateKey: localE, publicKey: remoteS)
        symmetricState.mixKey(se)

        // Decrypt payload
        let payloadData = Data(message[offset...])
        let payload = try symmetricState.decryptAndHash(payloadData)

        isComplete = true
        messageIndex = 3
        return payload
    }

    // MARK: - DH helper

    /// Perform a Curve25519 Diffie-Hellman key exchange.
    private func performDH(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        do {
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            return shared.withUnsafeBytes { buffer in
                Data(buffer)
            }
        } catch {
            throw NoiseHandshakeError.dhFailed
        }
    }
}

// MARK: - Noise Crypto Functions

/// HKDF-SHA256 producing 2 output keys (each 32 bytes).
///
/// Per Noise spec: `HKDF(chaining_key, input_key_material, num_outputs=2)`.
private func hkdfSHA256(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
    let prk = hmacSHA256(key: chainingKey, data: inputKeyMaterial)
    let t1 = hmacSHA256(key: prk, data: Data([0x01]))
    var t2Input = t1
    t2Input.append(Data([0x02]))
    let t2 = hmacSHA256(key: prk, data: t2Input)
    return (t1, t2)
}

/// HKDF-SHA256 producing 3 output keys (each 32 bytes).
private func hkdf3SHA256(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data, Data) {
    let prk = hmacSHA256(key: chainingKey, data: inputKeyMaterial)
    let t1 = hmacSHA256(key: prk, data: Data([0x01]))
    var t2Input = t1
    t2Input.append(Data([0x02]))
    let t2 = hmacSHA256(key: prk, data: t2Input)
    var t3Input = t2
    t3Input.append(Data([0x03]))
    let t3 = hmacSHA256(key: prk, data: t3Input)
    return (t1, t2, t3)
}

/// HMAC-SHA256 computation.
private func hmacSHA256(key: Data, data: Data) -> Data {
    let hmac = HMAC<SHA256>.authenticationCode(
        for: data,
        using: SymmetricKey(data: key)
    )
    return Data(hmac)
}

/// ChaChaPoly AEAD encrypt.
///
/// Nonce is 64-bit little-endian counter padded to 96 bits (4 zero bytes prefix).
private func aeadEncrypt(key: Data, nonce: UInt64, ad: Data, plaintext: Data) throws -> Data {
    let nonceData = makeAEADNonce(nonce)
    let chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
    let sealed = try ChaChaPoly.seal(
        plaintext,
        using: SymmetricKey(data: key),
        nonce: chachaNonce,
        authenticating: ad
    )
    return sealed.ciphertext + sealed.tag
}

/// ChaChaPoly AEAD decrypt.
private func aeadDecrypt(key: Data, nonce: UInt64, ad: Data, ciphertext: Data) throws -> Data {
    guard ciphertext.count >= 16 else {
        throw NoiseHandshakeError.messageDecryptionFailed
    }
    let nonceData = makeAEADNonce(nonce)
    let chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
    let tagOffset = ciphertext.count - 16
    let ct = ciphertext[ciphertext.startIndex ..< ciphertext.startIndex + tagOffset]
    let tag = ciphertext[ciphertext.startIndex + tagOffset ..< ciphertext.endIndex]
    let sealedBox = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ct, tag: tag)
    do {
        return try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: key), authenticating: ad)
    } catch {
        throw NoiseHandshakeError.messageDecryptionFailed
    }
}

/// Build a 96-bit ChaChaPoly nonce from a 64-bit counter.
///
/// 4 bytes of zeros followed by 8 bytes of the counter in little-endian.
private func makeAEADNonce(_ counter: UInt64) -> Data {
    var nonceBytes = Data(repeating: 0, count: 12)
    let le = counter.littleEndian
    withUnsafeBytes(of: le) { buffer in
        nonceBytes.replaceSubrange(4 ..< 12, with: buffer)
    }
    return nonceBytes
}
