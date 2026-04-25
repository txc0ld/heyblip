import XCTest
@testable import Blip
@testable import BlipProtocol

/// Round-trip tests for `MessagePayloadBuilder` encoders and decoders.
///
/// Regression coverage for the media payload encoding mismatch: the encoder
/// writes a 36-byte UTF-8 UUID string followed by a 0x00 terminator, but a
/// previous version of the decoder read the first 16 raw bytes as a UUID,
/// producing garbage IDs and corrupt media for every voice note and image.
final class MessagePayloadBuilderTests: XCTestCase {

    // MARK: - Text payload

    func testTextPayloadRoundTripWithoutReply() {
        let messageID = UUID()
        let content = "Hello, mesh!"
        let payload = MessagePayloadBuilder.buildTextPayload(
            content: content,
            messageID: messageID,
            replyToID: nil
        )

        let parsed = MessagePayloadBuilder.parseTextPayload(payload)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(String(data: parsed.content, encoding: .utf8), content)
        XCTAssertNil(parsed.replyToID)
    }

    func testTextPayloadRoundTripWithReply() {
        let messageID = UUID()
        let replyToID = UUID()
        let content = "Yep, hear you loud and clear."
        let payload = MessagePayloadBuilder.buildTextPayload(
            content: content,
            messageID: messageID,
            replyToID: replyToID
        )

        let parsed = MessagePayloadBuilder.parseTextPayload(payload)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(parsed.replyToID, replyToID)
        XCTAssertEqual(String(data: parsed.content, encoding: .utf8), content)
    }

    func testGroupTextPayloadRoundTrip() {
        let channelID = UUID()
        let messageID = UUID()
        let content = "Group shout"
        let payload = MessagePayloadBuilder.buildGroupTextPayload(
            content: content,
            channelID: channelID,
            messageID: messageID,
            replyToID: nil
        )

        let parsed = MessagePayloadBuilder.parseGroupTextPayload(payload)
        XCTAssertEqual(parsed.channelID, channelID)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(String(data: parsed.content, encoding: .utf8), content)
        XCTAssertNil(parsed.replyToID)
    }

    // MARK: - Media payload

    /// Regression test for the encoder/decoder asymmetry bug: the decoder used
    /// to read the first 16 bytes as a raw UUID, but the encoder writes a
    /// 36-byte UTF-8 UUID string. Now they must round-trip.
    func testMediaPayloadRoundTripWithDuration() {
        let messageID = UUID()
        let duration: TimeInterval = 4.2
        let mediaBytes = Data((0 ..< 300).map { UInt8($0 & 0xff) })

        let payload = MessagePayloadBuilder.buildMediaPayload(
            data: mediaBytes,
            messageID: messageID,
            duration: duration
        )

        let parsed = MessagePayloadBuilder.parseMediaPayload(payload, hasDuration: true)
        XCTAssertEqual(parsed.messageID, messageID, "messageID must round-trip exactly")
        XCTAssertEqual(parsed.duration ?? -1, duration, accuracy: 0.0001)
        XCTAssertEqual(parsed.media, mediaBytes, "media bytes must round-trip without truncation or prefix contamination")
    }

    func testMediaPayloadRoundTripWithoutDuration() {
        let messageID = UUID()
        let mediaBytes = Data((0 ..< 500).map { UInt8(($0 * 7) & 0xff) })

        let payload = MessagePayloadBuilder.buildMediaPayload(
            data: mediaBytes,
            messageID: messageID,
            duration: nil
        )

        let parsed = MessagePayloadBuilder.parseMediaPayload(payload, hasDuration: false)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertNil(parsed.duration)
        XCTAssertEqual(parsed.media, mediaBytes)
    }

    /// The wire format has no self-describing duration flag; the caller must
    /// pass `hasDuration` matching the sender's encoding. Mismatched callers
    /// should still recover a sane media payload (even if `duration` is lost)
    /// rather than corrupt the bytes.
    func testMediaPayloadParserHonorsHasDurationFlag() {
        let messageID = UUID()
        let mediaBytes = Data(repeating: 0xA5, count: 128)

        let encodedWithDuration = MessagePayloadBuilder.buildMediaPayload(
            data: mediaBytes,
            messageID: messageID,
            duration: 1.5
        )

        // Decoding with `hasDuration: false` keeps the 8 duration bytes as a
        // prefix of "media". This mismatch doesn't corrupt the underlying
        // decoder but does prove the caller must pass the right flag.
        let mismatchedParse = MessagePayloadBuilder.parseMediaPayload(encodedWithDuration, hasDuration: false)
        XCTAssertEqual(mismatchedParse.messageID, messageID)
        XCTAssertEqual(mismatchedParse.media.count, mediaBytes.count + 8)

        let correctParse = MessagePayloadBuilder.parseMediaPayload(encodedWithDuration, hasDuration: true)
        XCTAssertEqual(correctParse.messageID, messageID)
        XCTAssertEqual(correctParse.media, mediaBytes)
    }

    func testMediaPayloadParserHandlesMalformedInput() {
        // Payload without any 0x00 separator — parser must not crash.
        let garbage = Data(repeating: 0xFF, count: 40)
        let parsed = MessagePayloadBuilder.parseMediaPayload(garbage, hasDuration: false)
        XCTAssertEqual(parsed.media.count, 0)
        XCTAssertNil(parsed.duration)
        // Regression for the "malformed payload silently dedups against a fresh UUID
        // every time" bug: when the parser can't recover a real ID, it must surface
        // `nil` so the receive pipeline can drop the message instead of indexing it
        // under an ID that will never collide.
        XCTAssertNil(parsed.messageID, "missing UUID prefix must surface as nil, not a synthesised UUID")
    }

    func testMediaPayloadParserDoesNotSynthesizeMessageIDForUndecodableUTF8() {
        // The leading bytes are non-UTF-8 garbage followed by a 0x00 separator.
        // The parser must NOT manufacture a UUID — that would defeat the dedup
        // path, since every retransmit would surface as a new "unique" message.
        var payload = Data([0xFF, 0xFE, 0xFD, 0xFC])
        payload.append(0x00)
        payload.append(Data([0xAA, 0xBB]))

        let parsed = MessagePayloadBuilder.parseMediaPayload(payload, hasDuration: false)
        XCTAssertNil(parsed.messageID)
        XCTAssertEqual(parsed.media, Data([0xAA, 0xBB]))
    }

    func testMediaPayloadParserHandlesTruncatedDuration() {
        // Payload that claims to carry a duration but is truncated mid-field.
        // Parser must not over-read; duration should come back nil and media
        // should contain whatever bytes were present.
        let messageID = UUID()
        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8)!)
        payload.append(0x00)
        payload.append(Data([0x01, 0x02, 0x03])) // only 3 bytes — not a full 8-byte duration

        let parsed = MessagePayloadBuilder.parseMediaPayload(payload, hasDuration: true)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertNil(parsed.duration, "parser must refuse to load a truncated duration")
        XCTAssertEqual(parsed.media, Data([0x01, 0x02, 0x03]))
    }

    // MARK: - Reaction payload

    func testReactionPayloadRoundTripWithEmoji() {
        let messageID = UUID()
        let emoji = "👍"

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: emoji)
        let parsed = MessagePayloadBuilder.parseReactionPayload(payload)

        XCTAssertEqual(parsed.messageID, messageID, "messageID must round-trip exactly")
        XCTAssertEqual(parsed.emoji, emoji, "emoji must round-trip exactly")
    }

    func testReactionPayloadRoundTripWithEmpty() {
        let messageID = UUID()

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: nil)
        let parsed = MessagePayloadBuilder.parseReactionPayload(payload)

        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertNil(parsed.emoji, "nil emoji signals 'clear my reaction' — must not become empty string")
    }

    func testReactionPayloadRoundTripWithMultiByteEmoji() {
        let messageID = UUID()
        let emoji = "🎉"

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: emoji)
        let parsed = MessagePayloadBuilder.parseReactionPayload(payload)

        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(parsed.emoji, emoji, "multi-byte emoji must round-trip")
    }

    func testReactionPayloadRoundTripWithCompoundEmoji() {
        // Skin-tone modifier + ZWJ sequences are common reactions and span many bytes.
        let messageID = UUID()
        let emoji = "👍🏽"

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: emoji)
        let parsed = MessagePayloadBuilder.parseReactionPayload(payload)

        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(parsed.emoji, emoji)
    }

    // MARK: - Leading message ID

    func testParseLeadingMessageIDRecognizesTextPayload() {
        let messageID = UUID()
        let payload = MessagePayloadBuilder.buildTextPayload(
            content: "hi",
            messageID: messageID,
            replyToID: nil
        )
        XCTAssertEqual(MessagePayloadBuilder.parseLeadingMessageID(payload), messageID)
    }

    func testParseLeadingMessageIDRecognizesMediaPayload() {
        let messageID = UUID()
        let payload = MessagePayloadBuilder.buildMediaPayload(
            data: Data([0xDE, 0xAD]),
            messageID: messageID,
            duration: 1.25
        )
        XCTAssertEqual(
            MessagePayloadBuilder.parseLeadingMessageID(payload),
            messageID,
            "media and text payloads share the same UUID-string prefix format"
        )
    }
}
