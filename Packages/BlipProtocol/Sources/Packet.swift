import Foundation

/// A Blip binary protocol packet (spec Section 6.1 -- 6.3).
///
/// Layout:
/// ```
/// [Header: 16 bytes]
///   version      (1B)  -- protocol version, currently 0x01
///   type         (1B)  -- MessageType raw value
///   ttl          (1B)  -- hop count 0-7
///   timestamp    (8B)  -- UInt64 ms since epoch, big-endian
///   flags        (1B)  -- PacketFlags bitmask
///   payloadLength(4B)  -- UInt32, big-endian
/// [Sender ID: 8 bytes] -- always present
/// [Recipient ID: 8 bytes] -- if flags.hasRecipient
/// [Payload: variable]
/// [Signature: 64 bytes] -- if flags.hasSignature
/// ```
public struct Packet: Sendable, Equatable {

    // MARK: - Constants

    /// Fixed header size in bytes.
    public static let headerSize = 16

    /// Ed25519 signature size in bytes.
    public static let signatureSize = 64

    /// BLE effective MTU.
    public static let effectiveMTU = 512

    /// Worst-case max payload: addressed + signed = 512 - 16 - 8 - 8 - 64 = 416.
    public static let maxPayloadAddressedSigned = 416

    /// Broadcast + signed = 512 - 16 - 8 - 64 = 424.
    public static let maxPayloadBroadcastSigned = 424

    /// Addressed + unsigned = 512 - 16 - 8 - 8 = 480.
    public static let maxPayloadAddressedUnsigned = 480

    /// Broadcast + unsigned = 512 - 16 - 8 = 488.
    public static let maxPayloadBroadcastUnsigned = 488

    /// Fragmentation threshold (worst case addressed + signed).
    public static let fragmentationThreshold = 416

    /// Current protocol version.
    public static let currentVersion: UInt8 = 0x01

    /// Valid TTL range.
    public static let ttlRange: ClosedRange<UInt8> = 0 ... 7

    // MARK: - Header fields

    /// Protocol version (currently 0x01).
    public var version: UInt8

    /// Packet type.
    public var type: MessageType

    /// Time-to-live hop count (0-7).
    public var ttl: UInt8

    /// Timestamp in milliseconds since Unix epoch.
    public var timestamp: UInt64

    /// Flags bitmask.
    public var flags: PacketFlags

    // MARK: - Variable fields

    /// Sender PeerID (always present, 8 bytes).
    public var senderID: PeerID

    /// Recipient PeerID (present when `flags.contains(.hasRecipient)`).
    public var recipientID: PeerID?

    /// Message payload (variable length).
    public var payload: Data

    /// Ed25519 signature (present when `flags.contains(.hasSignature)`).
    public var signature: Data?

    // MARK: - Initializer

    public init(
        version: UInt8 = Packet.currentVersion,
        type: MessageType,
        ttl: UInt8,
        timestamp: UInt64,
        flags: PacketFlags,
        senderID: PeerID,
        recipientID: PeerID? = nil,
        payload: Data,
        signature: Data? = nil
    ) {
        self.version = version
        self.type = type
        self.ttl = ttl
        self.timestamp = timestamp
        self.flags = flags
        self.senderID = senderID
        self.recipientID = recipientID
        self.payload = payload
        self.signature = signature
    }

    // MARK: - Computed properties

    /// Payload length as stored in the header (UInt32).
    public var payloadLength: UInt32 {
        UInt32(payload.count)
    }

    /// Total serialized size of this packet.
    public var wireSize: Int {
        var size = Packet.headerSize + PeerID.length + payload.count
        if flags.contains(.hasRecipient) { size += PeerID.length }
        if flags.contains(.hasSignature) { size += Packet.signatureSize }
        return size
    }

    /// Maximum payload that fits in one BLE packet with the current flags.
    public var maxPayloadForFlags: Int {
        var overhead = Packet.headerSize + PeerID.length
        if flags.contains(.hasRecipient) { overhead += PeerID.length }
        if flags.contains(.hasSignature) { overhead += Packet.signatureSize }
        return Packet.effectiveMTU - overhead
    }

    /// Timestamp as a `Date`.
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
    }

    /// Create a timestamp (ms since epoch) from the current time.
    public static func currentTimestamp() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}
