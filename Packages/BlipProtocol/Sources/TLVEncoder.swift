import Foundation

/// TLV (Type-Length-Value) field identifiers for announcement packets
/// (spec Section 5.3).
///
/// Length is encoded as UInt16 big-endian. Value is raw bytes.
public enum TLVFieldType: UInt8, Sendable, Codable, CaseIterable {
    /// Username (max 32 bytes UTF-8).
    case username       = 0x01
    /// Noise static public key (32 bytes, Curve25519).
    case noiseKey       = 0x02
    /// Ed25519 signing public key (32 bytes).
    case signingKey     = 0x03
    /// Capabilities flags (2 bytes).
    case capabilities   = 0x04
    /// Neighbor peer ID list (8 bytes x N, max 8 neighbors = 64 bytes).
    case neighbors      = 0x05
    /// Avatar hash (32 bytes SHA256 of thumbnail).
    case avatarHash     = 0x06
}

/// A single TLV record: type tag + length + raw bytes.
public struct TLVField: Sendable, Equatable {
    /// Field type tag.
    public let type: TLVFieldType
    /// Raw value bytes.
    public let value: Data

    public init(type: TLVFieldType, value: Data) {
        self.type = type
        self.value = value
    }
}

/// Errors from TLV encoding/decoding.
public enum TLVError: Error, Sendable, Equatable {
    case dataTooShort
    case unknownFieldType(UInt8)
    case valueTooLarge(type: UInt8, length: Int)
    case duplicateField(UInt8)
    case usernameTooLong(Int)
}

/// Encoder and decoder for Blip TLV-formatted announcement payloads.
///
/// Wire format for each field:
/// ```
/// type   (1 byte)
/// length (2 bytes, UInt16 big-endian)
/// value  (length bytes)
/// ```
public enum TLVEncoder {

    /// Maximum username length in bytes.
    public static let maxUsernameLength = 32

    /// Maximum value size for any single TLV field (prevents abuse).
    public static let maxFieldValueLength = 256

    // MARK: - Encode

    /// Encode an ordered list of TLV fields to binary data.
    public static func encode(_ fields: [TLVField]) throws -> Data {
        var data = Data()
        for field in fields {
            if field.type == .username && field.value.count > maxUsernameLength {
                throw TLVError.usernameTooLong(field.value.count)
            }
            guard field.value.count <= maxFieldValueLength else {
                throw TLVError.valueTooLarge(type: field.type.rawValue, length: field.value.count)
            }
            data.append(field.type.rawValue)
            PacketSerializer.appendUInt16(&data, UInt16(field.value.count))
            data.append(field.value)
        }
        return data
    }

    // MARK: - Decode

    /// Decode binary data into an ordered list of TLV fields.
    ///
    /// Unknown field types are reported as errors; callers that want forward
    /// compatibility should use `decodeLenient` instead.
    public static func decode(_ data: Data) throws -> [TLVField] {
        var fields: [TLVField] = []
        var seenTypes = Set<UInt8>()
        var offset = 0

        while offset < data.count {
            // Type (1 byte)
            guard offset + 1 <= data.count else {
                throw TLVError.dataTooShort
            }
            let typeRaw = data[offset]; offset += 1

            guard let fieldType = TLVFieldType(rawValue: typeRaw) else {
                throw TLVError.unknownFieldType(typeRaw)
            }

            // Length (2 bytes, big-endian)
            guard offset + 2 <= data.count else {
                throw TLVError.dataTooShort
            }
            let length = PacketSerializer.readUInt16(data, at: &offset)

            // Value
            guard offset + Int(length) <= data.count else {
                throw TLVError.dataTooShort
            }
            let value = Data(data[offset ..< offset + Int(length)])
            offset += Int(length)

            // Duplicate check
            if seenTypes.contains(typeRaw) {
                throw TLVError.duplicateField(typeRaw)
            }
            seenTypes.insert(typeRaw)

            fields.append(TLVField(type: fieldType, value: value))
        }

        return fields
    }

    /// Decode with forward compatibility -- unknown field types are silently skipped.
    public static func decodeLenient(_ data: Data) -> [TLVField] {
        var fields: [TLVField] = []
        var offset = 0

        while offset < data.count {
            guard offset + 3 <= data.count else { break }

            let typeRaw = data[offset]; offset += 1
            let length = PacketSerializer.readUInt16(data, at: &offset)

            guard offset + Int(length) <= data.count else { break }

            let value = Data(data[offset ..< offset + Int(length)])
            offset += Int(length)

            if let fieldType = TLVFieldType(rawValue: typeRaw) {
                fields.append(TLVField(type: fieldType, value: value))
            }
            // Unknown types are silently skipped
        }

        return fields
    }

    // MARK: - Convenience builders

    /// Build an announcement TLV payload from structured data.
    public static func buildAnnouncement(
        username: String,
        noisePublicKey: Data,
        signingPublicKey: Data,
        capabilities: UInt16,
        neighborPeerIDs: [PeerID],
        avatarHash: Data?
    ) throws -> Data {
        var fields: [TLVField] = []

        // Username
        let usernameData = Data(username.utf8)
        fields.append(TLVField(type: .username, value: usernameData))

        // Noise public key
        fields.append(TLVField(type: .noiseKey, value: noisePublicKey))

        // Signing public key
        fields.append(TLVField(type: .signingKey, value: signingPublicKey))

        // Capabilities
        var capBig = capabilities.bigEndian
        let capData = Data(bytes: &capBig, count: 2)
        fields.append(TLVField(type: .capabilities, value: capData))

        // Neighbors (concatenated 8-byte PeerIDs, max 8)
        if !neighborPeerIDs.isEmpty {
            var neighborData = Data()
            for peer in neighborPeerIDs.prefix(8) {
                neighborData.append(peer.bytes)
            }
            fields.append(TLVField(type: .neighbors, value: neighborData))
        }

        // Avatar hash (optional)
        if let hash = avatarHash {
            fields.append(TLVField(type: .avatarHash, value: hash))
        }

        return try encode(fields)
    }

    /// Parse an announcement TLV payload into structured data.
    public struct AnnouncementData: Sendable, Equatable {
        public let username: String
        public let noisePublicKey: Data
        public let signingPublicKey: Data
        public let capabilities: UInt16
        public let neighborPeerIDs: [PeerID]
        public let avatarHash: Data?
    }

    /// Decode a TLV-encoded announcement payload.
    public static func parseAnnouncement(_ data: Data) throws -> AnnouncementData {
        let fields = try decode(data)
        var username: String?
        var noiseKey: Data?
        var signingKey: Data?
        var capabilities: UInt16 = 0
        var neighbors: [PeerID] = []
        var avatarHash: Data?

        for field in fields {
            switch field.type {
            case .username:
                username = String(data: field.value, encoding: .utf8)
            case .noiseKey:
                noiseKey = field.value
            case .signingKey:
                signingKey = field.value
            case .capabilities:
                if field.value.count >= 2 {
                    var offset = 0
                    capabilities = PacketSerializer.readUInt16(field.value, at: &offset)
                }
            case .neighbors:
                var offset = 0
                while offset + PeerID.length <= field.value.count {
                    if let peer = PeerID.read(from: field.value, offset: &offset) {
                        neighbors.append(peer)
                    }
                }
            case .avatarHash:
                avatarHash = field.value
            }
        }

        guard let u = username, let nk = noiseKey, let sk = signingKey else {
            throw TLVError.dataTooShort
        }

        return AnnouncementData(
            username: u,
            noisePublicKey: nk,
            signingPublicKey: sk,
            capabilities: capabilities,
            neighborPeerIDs: neighbors,
            avatarHash: avatarHash
        )
    }
}
