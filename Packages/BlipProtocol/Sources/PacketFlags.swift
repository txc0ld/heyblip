import Foundation

/// Bitmask flags for the packet header (spec Section 6.2).
///
/// Stored as a single byte at header offset 11.
public struct PacketFlags: OptionSet, Sendable, Codable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    // MARK: - Flag definitions

    /// Bit 0 (0x01) -- Recipient ID follows sender ID.
    public static let hasRecipient  = PacketFlags(rawValue: 0x01)

    /// Bit 1 (0x02) -- 64-byte Ed25519 signature appended.
    public static let hasSignature  = PacketFlags(rawValue: 0x02)

    /// Bit 2 (0x04) -- Payload is zlib compressed.
    public static let isCompressed  = PacketFlags(rawValue: 0x04)

    /// Bit 3 (0x08) -- Routing hint included.
    public static let hasRoute      = PacketFlags(rawValue: 0x08)

    /// Bit 4 (0x10) -- Store-and-forward requested.
    public static let isReliable    = PacketFlags(rawValue: 0x10)

    /// Bit 5 (0x20) -- Priority packet (organizer / SOS).
    public static let isPriority    = PacketFlags(rawValue: 0x20)

    // MARK: - Common combinations

    /// Addressed, signed, reliable DM.
    public static let addressedSignedReliable: PacketFlags = [.hasRecipient, .hasSignature, .isReliable]

    /// Broadcast, signed (public channel message).
    public static let broadcastSigned: PacketFlags = [.hasSignature]

    /// SOS priority flags.
    public static let sosPriority: PacketFlags = [.hasSignature, .isPriority, .isReliable]
}

// MARK: - CustomStringConvertible

extension PacketFlags: CustomStringConvertible {

    public var description: String {
        var parts: [String] = []
        if contains(.hasRecipient)  { parts.append("hasRecipient") }
        if contains(.hasSignature)  { parts.append("hasSignature") }
        if contains(.isCompressed)  { parts.append("isCompressed") }
        if contains(.hasRoute)      { parts.append("hasRoute") }
        if contains(.isReliable)    { parts.append("isReliable") }
        if contains(.isPriority)    { parts.append("isPriority") }
        return "[\(parts.joined(separator: ", "))]"
    }
}
