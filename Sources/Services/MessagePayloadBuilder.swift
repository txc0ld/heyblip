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

    /// Build a public channel payload using the same channel-scoped text envelope as groups.
    static func buildPublicChannelTextPayload(content: String, channelID: UUID, messageID: UUID, replyToID: UUID?) -> Data {
        buildGroupTextPayload(content: content, channelID: channelID, messageID: messageID, replyToID: replyToID)
    }

    /// Parse a public channel payload into (channelID, messageID, content, replyToID).
    static func parsePublicChannelTextPayload(_ data: Data) -> (channelID: UUID?, messageID: UUID, content: Data, replyToID: UUID?) {
        parseGroupTextPayload(data)
    }

    // MARK: - Media Payloads

    /// Build a media payload.
    ///
    /// Wire format: `[messageID: UTF-8 UUID string (36B)][0x00][duration: 8 little-endian
    /// bytes, if `hasDuration`][mediaData...]`.
    ///
    /// The leading messageID is encoded as a 36-byte UTF-8 UUID string (not raw 16 bytes)
    /// to match the text payload encoding and keep all message IDs uniformly parseable via
    /// `parseLeadingMessageID`. A 0x00 terminator separates the ID from the binary tail.
    ///
    /// - Parameters:
    ///   - data: Raw media bytes (Opus frames or JPEG data).
    ///   - messageID: UUID identifying this message for dedup + ack routing.
    ///   - duration: Optional duration in seconds (voice notes include it; images don't).
    ///     When non-nil, emitted as 8 raw bytes of a little-endian `TimeInterval`.
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

    /// Parsed media payload.
    struct ParsedMediaPayload {
        /// UUID decoded from the leading UTF-8 string. `parseMediaPayload` returns
        /// `nil` rather than fabricating one when the wire is malformed — see the
        /// dedup discussion in `parseMediaPayload`.
        let messageID: UUID?
        /// Duration in seconds (voice notes only), or `nil` for images.
        let duration: TimeInterval?
        /// Raw media bytes (Opus frames or JPEG data).
        let media: Data

        /// Backwards-compatible accessor: a synthesised UUID for callers that
        /// previously expected a non-optional `messageID`. New callers should
        /// branch on `messageID` directly so they can drop malformed packets
        /// instead of indexing them under a never-deduplicable random UUID.
        var resolvedMessageID: UUID { messageID ?? UUID() }
    }

    /// Parse a media payload produced by ``buildMediaPayload(data:messageID:duration:)``.
    ///
    /// Symmetric with `buildMediaPayload`: find the 0x00 terminator, decode the 36-byte
    /// leading UTF-8 UUID string, optionally read 8 bytes of duration, and return the
    /// remaining bytes as the media payload.
    ///
    /// **Malformed-input contract**: when the leading UUID is missing, truncated, or
    /// non-UTF-8, `messageID` is `nil`. The previous implementation manufactured a fresh
    /// UUID in that case, which broke the receive-side dedup: every retransmit got its
    /// own ID and was inserted as a duplicate row. Callers should now drop the message
    /// when `messageID == nil`.
    ///
    /// - Parameters:
    ///   - data: Full decrypted media payload.
    ///   - hasDuration: Whether the payload was built with a duration (voice notes = true,
    ///     images = false). The wire format gives no self-describing flag, so the caller
    ///     must know the message type from the `EncryptedSubType` envelope.
    static func parseMediaPayload(_ data: Data, hasDuration: Bool) -> ParsedMediaPayload {
        let bytes = [UInt8](data)
        guard let separatorIndex = bytes.firstIndex(of: 0x00) else {
            return ParsedMediaPayload(messageID: nil, duration: nil, media: Data())
        }
        let idBytes = Data(bytes[0 ..< separatorIndex])
        let messageID = String(data: idBytes, encoding: .utf8).flatMap(UUID.init)
        var cursor = separatorIndex + 1

        let duration: TimeInterval?
        if hasDuration {
            // Strict bounds check — without it a truncated payload (cursor + n where n < 8)
            // would either crash on the unsafe load or read uninitialised stack bytes.
            guard cursor + 8 <= bytes.count else {
                return ParsedMediaPayload(messageID: messageID, duration: nil, media: Data())
            }
            let durationBytes = Data(bytes[cursor ..< cursor + 8])
            duration = durationBytes.withUnsafeBytes { raw -> TimeInterval in
                raw.load(as: TimeInterval.self)
            }
            cursor += 8
        } else {
            duration = nil
        }

        let media = cursor <= bytes.count ? Data(bytes[cursor ..< bytes.count]) : Data()
        return ParsedMediaPayload(messageID: messageID, duration: duration, media: media)
    }

    // MARK: - Reaction Payloads

    /// Build a reaction payload: `[messageID: UTF-8 UUID string (36B)][0x00][emoji UTF-8 bytes]`.
    ///
    /// An empty trailing emoji payload (i.e., `emoji == nil` or `emoji == ""`) signals that the
    /// sender cleared their reaction on the target message.
    static func buildReactionPayload(messageID: UUID, emoji: String?) -> Data {
        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)
        if let emoji {
            payload.append(emoji.data(using: .utf8) ?? Data())
        }
        return payload
    }

    /// Parse a reaction payload produced by ``buildReactionPayload(messageID:emoji:)``.
    ///
    /// Returns `(messageID, emoji)`. `emoji == nil` means the sender cleared their reaction.
    /// If the leading messageID prefix is missing/non-UTF-8, returns a fresh UUID — callers
    /// should then fail to find a matching `Message` and drop the update gracefully.
    static func parseReactionPayload(_ data: Data) -> (messageID: UUID, emoji: String?) {
        let bytes = [UInt8](data)
        let firstSep = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let messageIDBytes = Data(bytes[0 ..< firstSep])
        let messageID = String(data: messageIDBytes, encoding: .utf8).flatMap(UUID.init) ?? UUID()
        let contentStart = min(firstSep + 1, bytes.endIndex)
        let emojiBytes = Data(bytes[contentStart...])
        let emoji = emojiBytes.isEmpty ? nil : String(data: emojiBytes, encoding: .utf8)
        return (messageID, emoji)
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
