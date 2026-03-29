import Testing
@testable import BlipProtocol
import Foundation

@Suite("PacketSerializer")
struct PacketSerializerTests {

    private let sender = PeerID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))!
    private let recipient = PeerID(bytes: Data([0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00]))!

    // MARK: - Header round-trip

    @Test("Header round-trips correctly")
    func headerRoundTrip() throws {
        let payload = Data("hello world".utf8)
        let original = Packet(
            version: 0x01, type: .meshBroadcast, ttl: 5,
            timestamp: 1_700_000_000_000, flags: [],
            senderID: sender, payload: payload
        )

        let encoded = try PacketSerializer.encode(original)
        let decoded = try PacketSerializer.decode(encoded)

        #expect(decoded.version == original.version)
        #expect(decoded.type == original.type)
        #expect(decoded.ttl == original.ttl)
        #expect(decoded.timestamp == original.timestamp)
        #expect(decoded.flags == original.flags)
        #expect(decoded.senderID == original.senderID)
        #expect(decoded.recipientID == nil)
        #expect(decoded.payload == original.payload)
        #expect(decoded.signature == nil)
    }

    @Test("Header is exactly 16 bytes")
    func headerIs16Bytes() throws {
        let packet = Packet(
            type: .announce, ttl: 3, timestamp: 0,
            flags: [], senderID: sender, payload: Data()
        )
        let encoded = try PacketSerializer.encode(packet)
        // Header (16) + sender (8) + payload (0)
        #expect(encoded.count == 24)
        #expect(encoded[0] == 0x01)   // version
        #expect(encoded[1] == 0x01)   // type = announce
        #expect(encoded[2] == 3)      // TTL
    }

    // MARK: - Big-endian encoding

    @Test("Timestamp is big-endian")
    func bigEndianTimestamp() throws {
        let timestamp: UInt64 = 0x0102030405060708
        let packet = Packet(
            type: .announce, ttl: 0,
            timestamp: timestamp, flags: [],
            senderID: sender, payload: Data()
        )
        let encoded = try PacketSerializer.encode(packet)
        // Timestamp at offset 3, 8 bytes big-endian
        #expect(encoded[3] == 0x01)
        #expect(encoded[4] == 0x02)
        #expect(encoded[5] == 0x03)
        #expect(encoded[6] == 0x04)
        #expect(encoded[7] == 0x05)
        #expect(encoded[8] == 0x06)
        #expect(encoded[9] == 0x07)
        #expect(encoded[10] == 0x08)
    }

    @Test("Payload length is big-endian")
    func bigEndianPayloadLength() throws {
        let payload = Data(repeating: 0xCC, count: 300)
        let packet = Packet(
            type: .meshBroadcast, ttl: 3,
            timestamp: 1000, flags: [],
            senderID: sender, payload: payload
        )
        let encoded = try PacketSerializer.encode(packet)
        // Payload length at offset 12, 4 bytes = 300 = 0x0000012C
        #expect(encoded[12] == 0x00)
        #expect(encoded[13] == 0x00)
        #expect(encoded[14] == 0x01)
        #expect(encoded[15] == 0x2C)
    }

    // MARK: - Addressed packet (with recipient)

    @Test("Addressed packet round-trips")
    func addressedRoundTrip() throws {
        let payload = Data("secret message".utf8)
        let original = Packet(
            type: .noiseEncrypted, ttl: 5,
            timestamp: 1_700_000_000_000,
            flags: [.hasRecipient, .isReliable],
            senderID: sender, recipientID: recipient,
            payload: payload
        )

        let encoded = try PacketSerializer.encode(original)
        let decoded = try PacketSerializer.decode(encoded)

        #expect(decoded.recipientID == recipient)
        #expect(decoded.senderID == sender)
        #expect(decoded.payload == payload)
        #expect(decoded.flags.contains(.hasRecipient))
        #expect(decoded.flags.contains(.isReliable))
    }

    // MARK: - Signed packet

    @Test("Signed packet round-trips")
    func signedRoundTrip() throws {
        let signature = Data(repeating: 0xFE, count: 64)
        let payload = Data("signed data".utf8)
        let original = Packet(
            type: .meshBroadcast, ttl: 3,
            timestamp: 1_700_000_000_000,
            flags: [.hasSignature],
            senderID: sender, payload: payload, signature: signature
        )

        let encoded = try PacketSerializer.encode(original)
        let decoded = try PacketSerializer.decode(encoded)

        #expect(decoded.signature == signature)
        #expect(decoded.flags.contains(.hasSignature))
    }

    // MARK: - Full addressed + signed packet

    @Test("Addressed + signed packet round-trips with correct size")
    func addressedSignedRoundTrip() throws {
        let sig = Data(repeating: 0xCC, count: 64)
        let payload = Data(repeating: 0xDD, count: 200)
        let snd = PeerID(bytes: Data(repeating: 0xAA, count: 8))!
        let rcv = PeerID(bytes: Data(repeating: 0xBB, count: 8))!

        let original = Packet(
            type: .noiseEncrypted, ttl: 7,
            timestamp: 1_700_000_000_000,
            flags: [.hasRecipient, .hasSignature, .isReliable],
            senderID: snd, recipientID: rcv,
            payload: payload, signature: sig
        )

        let encoded = try PacketSerializer.encode(original)
        #expect(encoded.count == 296)  // 16 + 8 + 8 + 200 + 64

        let decoded = try PacketSerializer.decode(encoded)
        #expect(decoded == original)
    }

    // MARK: - Max payload at MTU boundary

    @Test("Broadcast signed fills exactly 512 bytes")
    func maxPayloadBroadcastSigned() throws {
        let payload = Data(repeating: 0xAB, count: 424)
        let sig = Data(repeating: 0xCD, count: 64)
        let packet = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [.hasSignature], senderID: sender,
            payload: payload, signature: sig
        )
        let encoded = try PacketSerializer.encode(packet)
        #expect(encoded.count == 512)
    }

    @Test("Addressed signed fills exactly 512 bytes")
    func maxPayloadAddressedSigned() throws {
        let payload = Data(repeating: 0xAB, count: 416)
        let sig = Data(repeating: 0xCD, count: 64)
        let packet = Packet(
            type: .noiseEncrypted, ttl: 5, timestamp: 1000,
            flags: [.hasRecipient, .hasSignature],
            senderID: sender, recipientID: recipient,
            payload: payload, signature: sig
        )
        let encoded = try PacketSerializer.encode(packet)
        #expect(encoded.count == 512)
    }

    @Test("Broadcast unsigned fills exactly 512 bytes")
    func maxPayloadBroadcastUnsigned() throws {
        let payload = Data(repeating: 0xAB, count: 488)
        let packet = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [], senderID: sender, payload: payload
        )
        let encoded = try PacketSerializer.encode(packet)
        #expect(encoded.count == 512)
    }

    @Test("Addressed unsigned fills exactly 512 bytes")
    func maxPayloadAddressedUnsigned() throws {
        let payload = Data(repeating: 0xAB, count: 480)
        let packet = Packet(
            type: .noiseEncrypted, ttl: 5, timestamp: 1000,
            flags: [.hasRecipient],
            senderID: sender, recipientID: recipient,
            payload: payload
        )
        let encoded = try PacketSerializer.encode(packet)
        #expect(encoded.count == 512)
    }

    // MARK: - Error cases

    @Test("Decode data too short throws dataTooShort")
    func decodeDataTooShort() {
        let data = Data(repeating: 0, count: 5)
        #expect(throws: PacketSerializerError.self) {
            try PacketSerializer.decode(data)
        }
    }

    @Test("Decode unknown message type throws")
    func decodeUnknownType() {
        var data = Data(repeating: 0, count: 30)
        data[0] = 0x01
        data[1] = 0xFE  // unknown type
        data[2] = 3
        #expect(throws: PacketSerializerError.self) {
            try PacketSerializer.decode(data)
        }
    }

    @Test("Encode missing recipient throws missingRecipientID")
    func encodeMissingRecipient() {
        let packet = Packet(
            type: .noiseEncrypted, ttl: 5, timestamp: 1000,
            flags: [.hasRecipient], senderID: sender,
            recipientID: nil, payload: Data()
        )
        #expect(throws: PacketSerializerError.self) {
            try PacketSerializer.encode(packet)
        }
    }

    @Test("Encode missing signature throws missingSignature")
    func encodeMissingSignature() {
        let packet = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [.hasSignature], senderID: sender,
            payload: Data(), signature: nil
        )
        #expect(throws: PacketSerializerError.self) {
            try PacketSerializer.encode(packet)
        }
    }

    @Test("Encode wrong signature size throws signatureSizeMismatch")
    func encodeWrongSignatureSize() {
        let packet = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [.hasSignature], senderID: sender,
            payload: Data(), signature: Data(repeating: 0xFF, count: 32)
        )
        #expect(throws: PacketSerializerError.self) {
            try PacketSerializer.encode(packet)
        }
    }

    // MARK: - Signable data

    @Test("Signable data excludes TTL byte")
    func signableDataExcludesTTL() throws {
        let payload = Data("test".utf8)
        let sig = Data(repeating: 0xAA, count: 64)

        let p1 = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [.hasSignature], senderID: sender,
            payload: payload, signature: sig
        )
        let p2 = Packet(
            type: .meshBroadcast, ttl: 7, timestamp: 1000,
            flags: [.hasSignature], senderID: sender,
            payload: payload, signature: sig
        )

        let wire1 = try PacketSerializer.encode(p1)
        let wire2 = try PacketSerializer.encode(p2)

        let signable1 = PacketSerializer.signableData(from: wire1)
        let signable2 = PacketSerializer.signableData(from: wire2)

        #expect(signable1 == signable2)
        #expect(wire1 != wire2)
    }

    // MARK: - All flag combinations

    @Test("Various flag combinations round-trip")
    func allFlagCombinations() throws {
        let sig = Data(repeating: 0xFE, count: 64)
        let payload = Data("test payload".utf8)

        func assertRoundTrip(_ p: Packet) throws {
            let enc = try PacketSerializer.encode(p)
            let dec = try PacketSerializer.decode(enc)
            #expect(dec == p)
        }

        // No flags
        try assertRoundTrip(Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [], senderID: sender, payload: payload
        ))

        // hasRecipient only
        try assertRoundTrip(Packet(
            type: .noiseEncrypted, ttl: 5, timestamp: 2000,
            flags: [.hasRecipient],
            senderID: sender, recipientID: recipient, payload: payload
        ))

        // hasSignature only
        try assertRoundTrip(Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 3000,
            flags: [.hasSignature],
            senderID: sender, payload: payload, signature: sig
        ))

        // Both
        try assertRoundTrip(Packet(
            type: .noiseEncrypted, ttl: 7, timestamp: 4000,
            flags: [.hasRecipient, .hasSignature],
            senderID: sender, recipientID: recipient,
            payload: payload, signature: sig
        ))

        // All flags
        try assertRoundTrip(Packet(
            type: .sosAlert, ttl: 7, timestamp: 5000,
            flags: [.hasRecipient, .hasSignature, .isCompressed, .hasRoute, .isReliable, .isPriority],
            senderID: sender, recipientID: recipient,
            payload: payload, signature: sig
        ))
    }

    @Test("Empty payload round-trips")
    func emptyPayload() throws {
        let packet = Packet(
            type: .leave, ttl: 0, timestamp: 1000,
            flags: [], senderID: sender, payload: Data()
        )
        let encoded = try PacketSerializer.encode(packet)
        let decoded = try PacketSerializer.decode(encoded)
        #expect(decoded.payload.count == 0)
        #expect(decoded == packet)
    }
}
