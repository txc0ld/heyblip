import Foundation

/// Validation errors for incoming packets.
public enum PacketValidationError: Error, Sendable, Equatable {
    case unknownVersion(UInt8)
    case ttlOutOfRange(UInt8)
    case timestampInFuture(UInt64)
    case payloadTooLarge(UInt32)
    case payloadLengthMismatch(claimed: Int, actual: Int)
    case packetTooSmall(Int)
    case flagsInconsistent(String)
}

/// Validates that a `Packet` conforms to the Blip protocol rules.
///
/// Checks performed:
/// - Version is known (currently only 0x01)
/// - TTL is in range 0-7
/// - Timestamp is not unreasonably in the future (30 second tolerance)
/// - Payload length does not exceed MTU limits
/// - Flag/field consistency (hasRecipient implies recipientID present, etc.)
public enum PacketValidator {

    /// Maximum clock skew tolerance in milliseconds (30 seconds).
    public static let maxFutureToleranceMs: UInt64 = 30_000

    /// Maximum reasonable payload length (256 KB, well beyond BLE but useful for
    /// reassembled fragments over non-BLE transport).
    public static let maxPayloadLength: UInt32 = 262_144

    /// Validate a `Packet` and return all errors found.
    ///
    /// An empty array means the packet is valid.
    public static func validate(_ packet: Packet) -> [PacketValidationError] {
        var errors: [PacketValidationError] = []

        // Version check
        if packet.version != Packet.currentVersion {
            errors.append(.unknownVersion(packet.version))
        }

        // TTL range
        if !Packet.ttlRange.contains(packet.ttl) {
            errors.append(.ttlOutOfRange(packet.ttl))
        }

        // Timestamp not in the future (with tolerance)
        let now = Packet.currentTimestamp()
        if packet.timestamp > now + maxFutureToleranceMs {
            errors.append(.timestampInFuture(packet.timestamp))
        }

        // Payload size
        if packet.payloadLength > maxPayloadLength {
            errors.append(.payloadTooLarge(packet.payloadLength))
        }

        // Flags / field consistency
        if packet.flags.contains(.hasRecipient) && packet.recipientID == nil {
            errors.append(.flagsInconsistent("hasRecipient flag set but recipientID is nil"))
        }
        if !packet.flags.contains(.hasRecipient) && packet.recipientID != nil {
            errors.append(.flagsInconsistent("recipientID present but hasRecipient flag not set"))
        }
        if packet.flags.contains(.hasSignature) && packet.signature == nil {
            errors.append(.flagsInconsistent("hasSignature flag set but signature is nil"))
        }
        if !packet.flags.contains(.hasSignature) && packet.signature != nil {
            errors.append(.flagsInconsistent("signature present but hasSignature flag not set"))
        }
        if let sig = packet.signature, sig.count != Packet.signatureSize {
            errors.append(.flagsInconsistent(
                "signature must be \(Packet.signatureSize) bytes, got \(sig.count)"
            ))
        }

        return errors
    }

    /// Convenience: returns `true` if the packet passes all validation checks.
    public static func isValid(_ packet: Packet) -> Bool {
        validate(packet).isEmpty
    }

    /// Validate raw wire data before full deserialization (fast-reject).
    ///
    /// Checks only the header fields that can be read without allocating.
    public static func quickValidate(_ data: Data) -> [PacketValidationError] {
        var errors: [PacketValidationError] = []

        guard data.count >= Packet.headerSize else {
            errors.append(.packetTooSmall(data.count))
            return errors
        }

        let version = data[0]
        if version != Packet.currentVersion {
            errors.append(.unknownVersion(version))
        }

        let ttl = data[2]
        if !Packet.ttlRange.contains(ttl) {
            errors.append(.ttlOutOfRange(ttl))
        }

        let flags = PacketFlags(rawValue: data[11])

        // Payload length is the last 4 bytes of the fixed 16-byte header.
        let payloadLength = data[12..<16].withUnsafeBytes { buffer in
            UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))
        }

        // Reject unreasonably large payload claims from the header alone.
        if payloadLength > maxPayloadLength {
            errors.append(.payloadTooLarge(payloadLength))
        }

        // A bare header is enough for quick validation. If more bytes are present, ensure
        // the remaining buffer can satisfy the fixed fields implied by the header.
        var minimumWireSize = Packet.headerSize + PeerID.length + Int(payloadLength)
        if flags.contains(.hasRecipient) {
            minimumWireSize += PeerID.length
        }
        if flags.contains(.hasSignature) {
            minimumWireSize += Packet.signatureSize
        }

        if data.count > Packet.headerSize && minimumWireSize > data.count {
            let actualPayloadBytes = max(0, data.count - (minimumWireSize - Int(payloadLength)))
            errors.append(.payloadLengthMismatch(
                claimed: Int(payloadLength),
                actual: actualPayloadBytes
            ))
        }

        return errors
    }
}
