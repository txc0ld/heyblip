import Foundation
import CryptoKit

/// An 8-byte peer identifier derived from SHA256(noise_public_key)[0..<8].
///
/// Conforms to `Hashable`, `Codable`, and `Equatable` for use as dictionary keys
/// and storage in SwiftData models.
public struct PeerID: Sendable, Hashable, Equatable, Codable {

    /// Fixed length of a PeerID in bytes.
    public static let length = 8

    /// Broadcast address: all 0xFF bytes.
    public static let broadcast = PeerID(bytes: Data(repeating: 0xFF, count: length))!

    /// The raw 8 bytes of the peer identifier.
    public let bytes: Data

    // MARK: - Initializers

    /// Create a PeerID from exactly 8 raw bytes.
    ///
    /// Returns `nil` if the data is not exactly 8 bytes.
    public init?(bytes: Data) {
        guard bytes.count == PeerID.length else { return nil }
        self.bytes = bytes
    }

    /// Derive a PeerID from a Curve25519 Noise public key.
    ///
    /// Computes `SHA256(publicKeyBytes)` and takes the first 8 bytes.
    public init(noisePublicKey: Data) {
        let hash = SHA256.hash(data: noisePublicKey)
        self.bytes = Data(hash.prefix(PeerID.length))
    }

    /// Derive a PeerID from a CryptoKit Curve25519 public key.
    public init(noisePublicKey: Curve25519.KeyAgreement.PublicKey) {
        self.init(noisePublicKey: noisePublicKey.rawRepresentation)
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard data.count == PeerID.length else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "PeerID must be exactly \(PeerID.length) bytes, got \(data.count)"
            )
        }
        self.bytes = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }

    // MARK: - Serialization helpers

    /// Write the 8-byte PeerID into a mutable Data buffer.
    public func appendTo(_ data: inout Data) {
        data.append(bytes)
    }

    /// Read a PeerID from the given data starting at `offset`.
    ///
    /// Advances `offset` by 8 on success. Returns `nil` if insufficient bytes remain.
    public static func read(from data: Data, offset: inout Int) -> PeerID? {
        guard offset + length <= data.count else { return nil }
        let slice = data[offset ..< offset + length]
        offset += length
        return PeerID(bytes: Data(slice))
    }

    /// Whether this PeerID is the broadcast address.
    public var isBroadcast: Bool {
        self == PeerID.broadcast
    }
}

// MARK: - CustomStringConvertible

extension PeerID: CustomStringConvertible {

    /// Hex string representation of the 8 bytes for logging / debugging.
    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
