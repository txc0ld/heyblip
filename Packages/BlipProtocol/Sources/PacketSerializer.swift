import Foundation

/// Errors that can occur during packet serialization or deserialization.
public enum PacketSerializerError: Error, Sendable, Equatable {
    case dataTooShort(expected: Int, got: Int)
    case unknownMessageType(UInt8)
    case payloadLengthMismatch(declared: UInt32, actual: Int)
    case missingRecipientID
    case missingSignature
    case signatureSizeMismatch(expected: Int, got: Int)
    case packetExceedsMTU(size: Int)
}

/// Encodes and decodes `Packet` values to and from the Blip binary wire format.
///
/// All multi-byte integers are big-endian (network byte order) per spec Section 6.8.
public enum PacketSerializer {

    // MARK: - Encode

    /// Serialize a `Packet` to its binary wire representation.
    ///
    /// - Throws: `PacketSerializerError` if the packet is inconsistent
    ///   (e.g., `hasRecipient` flag set but `recipientID` is nil).
    public static func encode(_ packet: Packet) throws -> Data {
        var data = Data()
        data.reserveCapacity(packet.wireSize)

        // -- Header (16 bytes) --
        data.append(packet.version)
        data.append(packet.type.rawValue)
        data.append(packet.ttl)
        appendUInt64(&data, packet.timestamp)
        data.append(packet.flags.rawValue)
        appendUInt32(&data, packet.payloadLength)

        // -- Sender ID (8 bytes, always present) --
        packet.senderID.appendTo(&data)

        // -- Recipient ID (8 bytes, conditional) --
        if packet.flags.contains(.hasRecipient) {
            guard let recipientID = packet.recipientID else {
                throw PacketSerializerError.missingRecipientID
            }
            recipientID.appendTo(&data)
        }

        // -- Payload --
        data.append(packet.payload)

        // -- Signature (64 bytes, conditional) --
        if packet.flags.contains(.hasSignature) {
            guard let signature = packet.signature else {
                throw PacketSerializerError.missingSignature
            }
            guard signature.count == Packet.signatureSize else {
                throw PacketSerializerError.signatureSizeMismatch(
                    expected: Packet.signatureSize,
                    got: signature.count
                )
            }
            data.append(signature)
        }

        return data
    }

    // MARK: - Decode

    /// Deserialize a `Packet` from its binary wire representation.
    ///
    /// - Throws: `PacketSerializerError` on malformed data.
    public static func decode(_ data: Data) throws -> Packet {
        var offset = 0

        // -- Header (16 bytes) --
        guard data.count >= Packet.headerSize else {
            throw PacketSerializerError.dataTooShort(
                expected: Packet.headerSize,
                got: data.count
            )
        }

        let version = data[offset]; offset += 1

        let typeRaw = data[offset]; offset += 1
        guard let type = MessageType(rawValue: typeRaw) else {
            throw PacketSerializerError.unknownMessageType(typeRaw)
        }

        let ttl = data[offset]; offset += 1
        let timestamp = readUInt64(data, at: &offset)
        let flags = PacketFlags(rawValue: data[offset]); offset += 1
        let payloadLength = readUInt32(data, at: &offset)

        // Calculate the minimum required data length.
        var minRequired = Packet.headerSize + PeerID.length + Int(payloadLength)
        if flags.contains(.hasRecipient) { minRequired += PeerID.length }
        if flags.contains(.hasSignature) { minRequired += Packet.signatureSize }

        guard data.count >= minRequired else {
            throw PacketSerializerError.dataTooShort(
                expected: minRequired,
                got: data.count
            )
        }

        // -- Sender ID --
        guard let senderID = PeerID.read(from: data, offset: &offset) else {
            throw PacketSerializerError.dataTooShort(
                expected: offset + PeerID.length,
                got: data.count
            )
        }

        // -- Recipient ID --
        var recipientID: PeerID?
        if flags.contains(.hasRecipient) {
            guard let rid = PeerID.read(from: data, offset: &offset) else {
                throw PacketSerializerError.dataTooShort(
                    expected: offset + PeerID.length,
                    got: data.count
                )
            }
            recipientID = rid
        }

        // -- Payload --
        let payloadEnd = offset + Int(payloadLength)
        guard payloadEnd <= data.count else {
            throw PacketSerializerError.dataTooShort(
                expected: payloadEnd,
                got: data.count
            )
        }
        let payload = Data(data[offset ..< payloadEnd])
        offset = payloadEnd

        // -- Signature --
        var signature: Data?
        if flags.contains(.hasSignature) {
            let sigEnd = offset + Packet.signatureSize
            guard sigEnd <= data.count else {
                throw PacketSerializerError.dataTooShort(
                    expected: sigEnd,
                    got: data.count
                )
            }
            signature = Data(data[offset ..< sigEnd])
            offset = sigEnd
        }

        return Packet(
            version: version,
            type: type,
            ttl: ttl,
            timestamp: timestamp,
            flags: flags,
            senderID: senderID,
            recipientID: recipientID,
            payload: payload,
            signature: signature
        )
    }

    // MARK: - Data that is signed

    /// Extract the portion of a serialized packet that should be signed.
    ///
    /// Per spec Section 7.3, the signed data is the entire packet excluding the TTL
    /// field (offset 2, 1 byte) and the signature itself (last 64 bytes if present).
    public static func signableData(from wireData: Data) -> Data {
        var result = Data()
        // Everything before TTL (offset 0-1): version + type
        if wireData.count >= 2 {
            result.append(wireData[0 ..< 2])
        }
        // Skip TTL at offset 2
        // Everything after TTL through end of payload (before signature)
        if wireData.count > 3 {
            // Determine if there's a signature to exclude
            let flags = wireData.count > 11 ? PacketFlags(rawValue: wireData[11]) : PacketFlags(rawValue: 0)
            let endOffset: Int
            if flags.contains(.hasSignature) && wireData.count >= Packet.signatureSize {
                endOffset = wireData.count - Packet.signatureSize
            } else {
                endOffset = wireData.count
            }
            if endOffset > 3 {
                result.append(wireData[3 ..< endOffset])
            }
        }
        return result
    }

    // MARK: - Big-endian helpers

    static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }

    static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 8))
    }

    static func readUInt16(_ data: Data, at offset: inout Int) -> UInt16 {
        let value = data[offset ..< offset + 2].withUnsafeBytes {
            $0.loadUnaligned(as: UInt16.self)
        }
        offset += 2
        return UInt16(bigEndian: value)
    }

    static func readUInt32(_ data: Data, at offset: inout Int) -> UInt32 {
        let value = data[offset ..< offset + 4].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        offset += 4
        return UInt32(bigEndian: value)
    }

    static func readUInt64(_ data: Data, at offset: inout Int) -> UInt64 {
        let value = data[offset ..< offset + 8].withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }
        offset += 8
        return UInt64(bigEndian: value)
    }
}
