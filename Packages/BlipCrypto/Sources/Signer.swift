import Foundation
@preconcurrency import Sodium
import BlipProtocol

// MARK: - Errors

public enum SignerError: Error, Sendable {
    case signatureFailed
    case invalidSignatureLength(Int)
    case invalidPublicKeyLength(Int)
    case invalidSecretKeyLength(Int)
    case packetTooShort
}

// MARK: - Signer

/// Ed25519 packet signing and verification.
///
/// Per spec Section 7.3, the signed data is the entire serialized packet
/// **excluding** the TTL field (offset 2, 1 byte) and the signature itself
/// (trailing 64 bytes when present). This allows relay nodes to decrement
/// TTL without invalidating the sender's signature.
public enum Signer {

    nonisolated(unsafe) private static let sodium = Sodium()

    /// Expected Ed25519 signature length.
    public static let signatureLength = 64
    /// Expected Ed25519 public key length.
    public static let publicKeyLength = 32
    /// Expected Ed25519 secret key length (seed + public in libsodium format).
    public static let secretKeyLength = 64

    // MARK: - Sign

    /// Sign a serialized packet using the sender's Ed25519 secret key.
    ///
    /// The signature covers all bytes except:
    /// - TTL byte at offset 2 (1 byte)
    /// - Any existing trailing signature (64 bytes)
    ///
    /// - Parameters:
    ///   - packetData: The full serialized packet (may or may not include signature bytes).
    ///   - secretKey: The 64-byte Ed25519 secret key.
    /// - Returns: 64-byte Ed25519 signature.
    public static func sign(packetData: Data, secretKey: Data) throws -> Data {
        guard secretKey.count == secretKeyLength else {
            throw SignerError.invalidSecretKeyLength(secretKey.count)
        }
        guard packetData.count >= Packet.headerSize else {
            throw SignerError.packetTooShort
        }

        let signable = extractSignableData(from: packetData)
        guard let signature = sodium.sign.signature(
            message: Bytes(signable),
            secretKey: Bytes(secretKey)
        ) else {
            throw SignerError.signatureFailed
        }
        return Data(signature)
    }

    /// Sign a `Packet` value directly. Serializes, signs, and attaches the signature.
    ///
    /// Returns a new `Packet` with the `.hasSignature` flag set and the signature field populated.
    public static func sign(packet: Packet, secretKey: Data) throws -> Packet {
        // Build a packet with signature flag but no signature data yet
        var signable = packet
        signable.flags.insert(.hasSignature)
        signable.signature = Data(repeating: 0, count: signatureLength)

        let wireData = try PacketSerializer.encode(signable)
        let signature = try sign(packetData: wireData, secretKey: secretKey)

        var result = packet
        result.flags.insert(.hasSignature)
        result.signature = signature
        return result
    }

    // MARK: - Verify

    /// Verify the Ed25519 signature on a serialized packet.
    ///
    /// - Parameters:
    ///   - packetData: Full serialized packet including the trailing 64-byte signature.
    ///   - publicKey: The 32-byte Ed25519 public key of the alleged signer.
    /// - Returns: `true` if the signature is valid.
    public static func verify(packetData: Data, publicKey: Data) throws -> Bool {
        guard publicKey.count == publicKeyLength else {
            throw SignerError.invalidPublicKeyLength(publicKey.count)
        }
        guard packetData.count >= Packet.headerSize + signatureLength else {
            throw SignerError.packetTooShort
        }

        // Extract the signature (last 64 bytes)
        let signature = Data(packetData.suffix(signatureLength))
        let signable = extractSignableData(from: packetData)

        return sodium.sign.verify(
            message: Bytes(signable),
            publicKey: Bytes(publicKey),
            signature: Bytes(signature)
        )
    }

    /// Verify the signature on a `Packet` that has already been deserialized.
    ///
    /// The packet must have `.hasSignature` set and a non-nil `signature`.
    public static func verify(packet: Packet, publicKey: Data) throws -> Bool {
        guard packet.flags.contains(.hasSignature), let _ = packet.signature else {
            return false
        }
        let wireData = try PacketSerializer.encode(packet)
        return try verify(packetData: wireData, publicKey: publicKey)
    }

    // MARK: - Signable data extraction

    /// Extract the bytes that are covered by the signature.
    ///
    /// Per spec: everything except TTL (offset 2, 1 byte) and the trailing signature
    /// (64 bytes when the hasSignature flag is set).
    ///
    /// Wire layout:
    /// ```
    /// [0]  version
    /// [1]  type
    /// [2]  TTL        <-- excluded
    /// [3..10] timestamp (8 bytes)
    /// [11] flags
    /// [12..15] payloadLength (4 bytes)
    /// [16..] sender + optional recipient + payload + optional signature
    /// ```
    internal static func extractSignableData(from wireData: Data) -> Data {
        guard wireData.count > 3 else { return wireData }

        var result = Data()
        // Bytes before TTL: version(0) + type(1)
        result.append(wireData[0 ..< 2])

        // Determine end boundary: exclude trailing signature if flag set
        let flagsByte = wireData.count > 11 ? wireData[11] : 0
        let flags = PacketFlags(rawValue: flagsByte)
        let endOffset: Int
        if flags.contains(.hasSignature) && wireData.count >= signatureLength {
            endOffset = wireData.count - signatureLength
        } else {
            endOffset = wireData.count
        }

        // Everything after TTL (offset 3) up to endOffset
        if endOffset > 3 {
            result.append(wireData[3 ..< endOffset])
        }

        return result
    }
}
