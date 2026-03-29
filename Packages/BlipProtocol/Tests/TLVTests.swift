import Testing
@testable import BlipProtocol
import Foundation

@Suite("TLVEncoder")
struct TLVTests {

    // MARK: - Basic encode/decode

    @Test("Single field round-trips")
    func singleField() throws {
        let fields = [TLVField(type: .username, value: Data("alice".utf8))]
        let encoded = try TLVEncoder.encode(fields)
        let decoded = try TLVEncoder.decode(encoded)

        #expect(decoded.count == 1)
        #expect(decoded[0].type == .username)
        #expect(String(data: decoded[0].value, encoding: .utf8) == "alice")
    }

    @Test("Multiple fields round-trip preserving order")
    func multipleFields() throws {
        let noiseKey = Data(repeating: 0xAA, count: 32)
        let signingKey = Data(repeating: 0xBB, count: 32)
        let fields = [
            TLVField(type: .username, value: Data("bob".utf8)),
            TLVField(type: .noiseKey, value: noiseKey),
            TLVField(type: .signingKey, value: signingKey),
        ]

        let encoded = try TLVEncoder.encode(fields)
        let decoded = try TLVEncoder.decode(encoded)

        #expect(decoded.count == 3)
        #expect(decoded[0].type == .username)
        #expect(decoded[1].type == .noiseKey)
        #expect(decoded[1].value == noiseKey)
        #expect(decoded[2].type == .signingKey)
        #expect(decoded[2].value == signingKey)
    }

    // MARK: - Wire format

    @Test("Wire layout: type(1) + length(2 BE) + value")
    func wireFormat() throws {
        let fields = [TLVField(type: .username, value: Data("hi".utf8))]
        let encoded = try TLVEncoder.encode(fields)

        #expect(encoded.count == 5)
        #expect(encoded[0] == 0x01)   // type = username
        #expect(encoded[1] == 0x00)   // length high
        #expect(encoded[2] == 0x02)   // length low = 2
        #expect(encoded[3] == 0x68)   // 'h'
        #expect(encoded[4] == 0x69)   // 'i'
    }

    @Test("Length field is big-endian")
    func lengthBigEndian() throws {
        let value = Data(repeating: 0x42, count: 200)
        let fields = [TLVField(type: .noiseKey, value: value)]
        let encoded = try TLVEncoder.encode(fields)

        #expect(encoded[1] == 0x00)   // high byte
        #expect(encoded[2] == 0xC8)   // low byte = 200
    }

    // MARK: - Field types

    @Test("TLVFieldType raw values")
    func fieldTypeRawValues() {
        #expect(TLVFieldType.username.rawValue == 0x01)
        #expect(TLVFieldType.noiseKey.rawValue == 0x02)
        #expect(TLVFieldType.signingKey.rawValue == 0x03)
        #expect(TLVFieldType.capabilities.rawValue == 0x04)
        #expect(TLVFieldType.neighbors.rawValue == 0x05)
        #expect(TLVFieldType.avatarHash.rawValue == 0x06)
    }

    // MARK: - Error cases

    @Test("Unknown field type throws unknownFieldType")
    func unknownFieldType() {
        var data = Data()
        data.append(0xFF)
        data.append(contentsOf: [0x00, 0x01])
        data.append(0x42)

        #expect(throws: TLVError.self) {
            try TLVEncoder.decode(data)
        }
    }

    @Test("Truncated header throws dataTooShort")
    func truncatedHeader() {
        let data = Data([0x01, 0x00])
        #expect(throws: TLVError.self) {
            try TLVEncoder.decode(data)
        }
    }

    @Test("Truncated value throws dataTooShort")
    func truncatedValue() {
        var data = Data()
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x0A])  // length=10
        data.append(contentsOf: [0x41, 0x42, 0x43])  // only 3

        #expect(throws: TLVError.self) {
            try TLVEncoder.decode(data)
        }
    }

    @Test("Duplicate field throws duplicateField")
    func duplicateField() {
        var data = Data()
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x01])
        data.append(0x41)
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x01])
        data.append(0x42)

        #expect(throws: TLVError.self) {
            try TLVEncoder.decode(data)
        }
    }

    @Test("Username > 32 bytes throws usernameTooLong")
    func usernameTooLong() {
        let longName = String(repeating: "A", count: 40)
        let fields = [TLVField(type: .username, value: Data(longName.utf8))]
        #expect(throws: TLVError.self) {
            try TLVEncoder.encode(fields)
        }
    }

    // MARK: - Lenient decoding

    @Test("Lenient decoding skips unknown types")
    func lenientSkipsUnknown() {
        var data = Data()
        // Known field
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x03])
        data.append(contentsOf: Data("bob".utf8))
        // Unknown field
        data.append(0xFE)
        data.append(contentsOf: [0x00, 0x02])
        data.append(contentsOf: [0x99, 0x99])
        // Known field
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x04])
        data.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])

        let fields = TLVEncoder.decodeLenient(data)
        #expect(fields.count == 2)
        #expect(fields[0].type == .username)
        #expect(fields[1].type == .noiseKey)
    }

    // MARK: - Announcement

    @Test("Announcement round-trips with all fields")
    func announcementRoundTrip() throws {
        let username = "festival_goer"
        let noiseKey = Data(repeating: 0x11, count: 32)
        let signingKey = Data(repeating: 0x22, count: 32)
        let capabilities: UInt16 = 0x000F
        let neighbor1 = PeerID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))!
        let neighbor2 = PeerID(bytes: Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]))!
        let avatarHash = Data(repeating: 0xAA, count: 32)

        let encoded = try TLVEncoder.buildAnnouncement(
            username: username,
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            capabilities: capabilities,
            neighborPeerIDs: [neighbor1, neighbor2],
            avatarHash: avatarHash
        )

        #expect(encoded.count <= 488)

        let ann = try TLVEncoder.parseAnnouncement(encoded)
        #expect(ann.username == username)
        #expect(ann.noisePublicKey == noiseKey)
        #expect(ann.signingPublicKey == signingKey)
        #expect(ann.capabilities == capabilities)
        #expect(ann.neighborPeerIDs.count == 2)
        #expect(ann.neighborPeerIDs[0] == neighbor1)
        #expect(ann.neighborPeerIDs[1] == neighbor2)
        #expect(ann.avatarHash == avatarHash)
    }

    @Test("Announcement without optional fields")
    func announcementMinimal() throws {
        let encoded = try TLVEncoder.buildAnnouncement(
            username: "min",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            capabilities: 0,
            neighborPeerIDs: [],
            avatarHash: nil
        )

        let ann = try TLVEncoder.parseAnnouncement(encoded)
        #expect(ann.username == "min")
        #expect(ann.neighborPeerIDs.isEmpty)
        #expect(ann.avatarHash == nil)
    }

    @Test("Announcement max 8 neighbors")
    func announcementMaxNeighbors() throws {
        let neighbors = (0..<8).map { PeerID(bytes: Data(repeating: UInt8($0), count: 8))! }
        let encoded = try TLVEncoder.buildAnnouncement(
            username: "test",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            capabilities: 0xFFFF,
            neighborPeerIDs: neighbors,
            avatarHash: nil
        )
        let ann = try TLVEncoder.parseAnnouncement(encoded)
        #expect(ann.neighborPeerIDs.count == 8)
    }

    @Test("Announcement truncates excess neighbors to 8")
    func announcementTruncatesNeighbors() throws {
        let neighbors = (0..<10).map { PeerID(bytes: Data(repeating: UInt8($0), count: 8))! }
        let encoded = try TLVEncoder.buildAnnouncement(
            username: "test",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            capabilities: 0,
            neighborPeerIDs: neighbors,
            avatarHash: nil
        )
        let ann = try TLVEncoder.parseAnnouncement(encoded)
        #expect(ann.neighborPeerIDs.count == 8)
    }

    @Test("Capabilities encoded big-endian")
    func capabilitiesBigEndian() throws {
        let encoded = try TLVEncoder.buildAnnouncement(
            username: "test",
            noisePublicKey: Data(repeating: 0, count: 32),
            signingPublicKey: Data(repeating: 0, count: 32),
            capabilities: 0x1234,
            neighborPeerIDs: [],
            avatarHash: nil
        )
        let fields = try TLVEncoder.decode(encoded)
        let capField = fields.first { $0.type == .capabilities }
        #expect(capField != nil)
        #expect(capField?.value.count == 2)
        #expect(capField?.value[0] == 0x12)
        #expect(capField?.value[1] == 0x34)
    }

    // MARK: - Empty data

    @Test("Decode empty data returns empty array")
    func decodeEmpty() throws {
        let fields = try TLVEncoder.decode(Data())
        #expect(fields.isEmpty)
    }

    @Test("Encode empty fields returns empty data")
    func encodeEmpty() throws {
        let encoded = try TLVEncoder.encode([])
        #expect(encoded.isEmpty)
    }
}
