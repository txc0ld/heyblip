import Foundation
import BlipProtocol

// MARK: - Message Payload Builder

/// Pure functions for constructing and parsing Blip message payloads.
/// Extracted from MessageService to reduce its size and improve testability.
enum MessagePayloadBuilder {

    // MARK: - Channel-Scoped Payloads

    /// Build a channel-scoped payload: [channelID(36B) 0x00 content]
    static func buildChannelScopedPayload(channelID: UUID, content: Data) -> Data {
        var payload = Data()
        payload.append(channelID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(content)
        return payload
    }

    /// Parse a channel-scoped payload into (channelID, content).
    static func parseChannelScopedPayload(_ data: Data) -> (channelID: UUID?, content: Data) {
        let bytes = [UInt8](data)
        let separatorIndex = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let channelIDBytes = Data(bytes[0 ..< separatorIndex])
        let channelID = String(data: channelIDBytes, encoding: .utf8).flatMap(UUID.init)
        let contentStart = min(separatorIndex + 1, bytes.endIndex)
        let content = Data(bytes[contentStart...])
        return (channelID, content)
    }

    // MARK: - Text Payloads

    /// Build a text message payload: [messageID(36B) 0x00 replyToID(36B)? 0x00 content(UTF-8)]
    static func buildTextPayload(content: String, messageID: UUID, replyToID: UUID?) -> Data {
        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)
        if let replyToID {
            payload.append(replyToID.uuidString.data(using: .utf8) ?? Data())
        }
        payload.append(0x00)
        payload.append(content.data(using: .utf8) ?? Data())
        return payload
    }

    /// Parse a text payload into (messageID, content, replyToID).
    static func parseTextPayload(_ data: Data) -> (messageID: UUID, content: Data, replyToID: UUID?) {
        let bytes = [UInt8](data)

        let firstSep = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let messageIDBytes = Data(bytes[0 ..< firstSep])
        let messageID = String(data: messageIDBytes, encoding: .utf8).flatMap(UUID.init) ?? UUID()

        let afterFirstSep = min(firstSep + 1, bytes.endIndex)
        let secondSep = bytes[afterFirstSep...].firstIndex(of: 0x00) ?? bytes.endIndex
        let replyToBytes = Data(bytes[afterFirstSep ..< secondSep])
        let replyToID: UUID? = String(data: replyToBytes, encoding: .utf8).flatMap(UUID.init)

        let contentStart = min(secondSep + 1, bytes.endIndex)
        let content = Data(bytes[contentStart...])

        return (messageID, content, replyToID)
    }

    /// Parse the leading message ID prefix shared by text and media payloads.
    static func parseLeadingMessageID(_ data: Data) -> UUID? {
        let bytes = [UInt8](data)
        let firstSep = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let messageIDBytes = Data(bytes[0 ..< firstSep])
        return String(data: messageIDBytes, encoding: .utf8).flatMap(UUID.init)
    }

    /// Build a group text payload: [channelID(36B) 0x00 textPayload]
    static func buildGroupTextPayload(content: String, channelID: UUID, messageID: UUID, replyToID: UUID?) -> Data {
        let textPayload = buildTextPayload(content: content, messageID: messageID, replyToID: replyToID)
        return buildChannelScopedPayload(channelID: channelID, content: textPayload)
    }

    /// Parse a group text payload into (channelID, messageID, content, replyToID).
    static func parseGroupTextPayload(_ data: Data) -> (channelID: UUID?, messageID: UUID, content: Data, replyToID: UUID?) {
        let (channelID, scopedContent) = parseChannelScopedPayload(data)
        let (messageID, content, replyToID) = parseTextPayload(scopedContent)
        return (channelID, messageID, content, replyToID)
    }

    // MARK: - Media Payloads

    /// Build a media payload: [messageID(36B) 0x00 duration?(8B) mediaData]
    static func buildMediaPayload(data: Data, messageID: UUID, duration: TimeInterval?) -> Data {
        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)
        if let duration {
            var dur = duration
            payload.append(Data(bytes: &dur, count: 8))
        }
        payload.append(data)
        return payload
    }

    // MARK: - Friend Payloads

    /// Parse friend request/accept payload: username + 0x00 + displayName (optional)
    static func parseFriendPayload(_ data: Data) -> (username: String?, displayName: String?) {
        let bytes = [UInt8](data)
        guard let sepIndex = bytes.firstIndex(of: 0x00) else {
            return (String(data: data, encoding: .utf8), nil)
        }
        let usernameData = Data(bytes[0 ..< sepIndex])
        let username = String(data: usernameData, encoding: .utf8)
        let afterSep = sepIndex + 1
        let displayName: String?
        if afterSep < bytes.count {
            displayName = String(data: Data(bytes[afterSep...]), encoding: .utf8)
        } else {
            displayName = nil
        }
        return (username, displayName)
    }

    // MARK: - SubType Tagging

    /// Prepend the EncryptedSubType byte to a payload.
    static func prependSubType(_ subType: EncryptedSubType, to payload: Data) -> Data {
        var tagged = Data(capacity: 1 + payload.count)
        tagged.append(subType.rawValue)
        tagged.append(payload)
        return tagged
    }

    // MARK: - Packet Construction

    /// Build a Packet with standard Blip header fields.
    static func buildPacket(
        type: BlipProtocol.MessageType,
        payload: Data,
        flags: PacketFlags,
        senderID: PeerID,
        recipientID: PeerID?
    ) -> Packet {
        var effectiveFlags = flags
        effectiveFlags.remove(.hasSignature)
        if recipientID != nil {
            effectiveFlags.insert(.hasRecipient)
        }

        return Packet(
            type: type,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: effectiveFlags,
            senderID: senderID,
            recipientID: recipientID,
            payload: payload,
            signature: nil
        )
    }

    /// Build a Bloom filter packet ID from sender + timestamp + type.
    static func buildPacketID(_ packet: Packet) -> Data {
        var idData = Data()
        packet.senderID.appendTo(&idData)
        var ts = packet.timestamp.bigEndian
        idData.append(Data(bytes: &ts, count: 8))
        idData.append(packet.type.rawValue)
        return idData
    }
}
