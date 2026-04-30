import Testing
@testable import BlipProtocol
import CryptoKit
import Foundation

@Suite("MessageType")
struct MessageTypeTests {

    @Test("Raw values match spec Section 6.4")
    func rawValues() {
        #expect(MessageType.announce.rawValue == 0x01)
        #expect(MessageType.meshBroadcast.rawValue == 0x02)
        #expect(MessageType.leave.rawValue == 0x03)
        #expect(MessageType.noiseHandshake.rawValue == 0x10)
        #expect(MessageType.noiseEncrypted.rawValue == 0x11)
        #expect(MessageType.fragment.rawValue == 0x20)
        #expect(MessageType.syncRequest.rawValue == 0x21)
        #expect(MessageType.fileTransfer.rawValue == 0x22)
        #expect(MessageType.pttAudio.rawValue == 0x23)
        #expect(MessageType.orgAnnouncement.rawValue == 0x30)
        #expect(MessageType.channelUpdate.rawValue == 0x31)
        #expect(MessageType.sessionLost.rawValue == 0x32)
        #expect(MessageType.sosAlert.rawValue == 0x40)
        #expect(MessageType.sosAccept.rawValue == 0x41)
        #expect(MessageType.sosPreciseLocation.rawValue == 0x42)
        #expect(MessageType.sosResolve.rawValue == 0x43)
        #expect(MessageType.sosNearbyAssist.rawValue == 0x44)
        #expect(MessageType.locationShare.rawValue == 0x50)
        #expect(MessageType.locationRequest.rawValue == 0x51)
        #expect(MessageType.proximityPing.rawValue == 0x52)
        #expect(MessageType.iAmHereBeacon.rawValue == 0x53)
        #expect(MessageType.friendRequest.rawValue == 0x60)
        #expect(MessageType.friendAccept.rawValue == 0x61)
    }

    @Test("All cases count is 23")
    func allCasesCount() {
        #expect(MessageType.allCases.count == 23)
    }

    @Test("SOS types identified correctly")
    func sosTypes() {
        #expect(MessageType.sosAlert.isSOS)
        #expect(MessageType.sosAccept.isSOS)
        #expect(MessageType.sosPreciseLocation.isSOS)
        #expect(MessageType.sosResolve.isSOS)
        #expect(MessageType.sosNearbyAssist.isSOS)
        #expect(!MessageType.announce.isSOS)
        #expect(!MessageType.noiseEncrypted.isSOS)
    }

    @Test("Encrypted type identified")
    func encryptedType() {
        #expect(MessageType.noiseEncrypted.isEncrypted)
        #expect(!MessageType.announce.isEncrypted)
        #expect(!MessageType.sosAlert.isEncrypted)
    }
}

@Suite("PacketFlags")
struct PacketFlagsTests {

    @Test("Flag masks match spec Section 6.2")
    func masks() {
        #expect(PacketFlags.hasRecipient.rawValue == 0x01)
        #expect(PacketFlags.hasSignature.rawValue == 0x02)
        #expect(PacketFlags.isCompressed.rawValue == 0x04)
        #expect(PacketFlags.hasRoute.rawValue == 0x08)
        #expect(PacketFlags.isReliable.rawValue == 0x10)
        #expect(PacketFlags.isPriority.rawValue == 0x20)
    }

    @Test("Flag combinations work correctly")
    func combinations() {
        let flags: PacketFlags = [.hasRecipient, .hasSignature]
        #expect(flags.contains(.hasRecipient))
        #expect(flags.contains(.hasSignature))
        #expect(!flags.contains(.isCompressed))
        #expect(flags.rawValue == 0x03)
    }

    @Test("Description includes set flag names")
    func description() {
        let flags: PacketFlags = [.hasRecipient, .isPriority]
        let desc = flags.description
        #expect(desc.contains("hasRecipient"))
        #expect(desc.contains("isPriority"))
    }
}

@Suite("PeerID")
struct PeerIDTests {

    @Test("Length is 8 bytes")
    func length() {
        #expect(PeerID.length == 8)
    }

    @Test("Init from valid bytes succeeds")
    func fromBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let peerID = PeerID(bytes: data)
        #expect(peerID != nil)
        #expect(peerID?.bytes == data)
    }

    @Test("Init from wrong-length bytes returns nil")
    func fromBytesWrongLength() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(PeerID(bytes: data) == nil)
    }

    @Test("Derived from Noise public key matches SHA256(key)[0..<8]")
    func fromNoisePublicKey() {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        let peerID = PeerID(noisePublicKey: publicKey)
        #expect(peerID.bytes.count == 8)

        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        let expected = Data(hash.prefix(8))
        #expect(peerID.bytes == expected)
    }

    @Test("Derivation is deterministic")
    func deterministic() {
        let keyData = Data(repeating: 0xAB, count: 32)
        let id1 = PeerID(noisePublicKey: keyData)
        let id2 = PeerID(noisePublicKey: keyData)
        #expect(id1 == id2)
    }

    @Test("Broadcast address is all 0xFF")
    func broadcast() {
        let broadcast = PeerID.broadcast
        #expect(broadcast.isBroadcast)
        #expect(broadcast.bytes == Data(repeating: 0xFF, count: 8))
    }

    @Test("Non-broadcast is not broadcast")
    func notBroadcast() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let peerID = PeerID(bytes: data)!
        #expect(!peerID.isBroadcast)
    }

    @Test("Codable round-trip preserves value")
    func codable() throws {
        let original = PeerID(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x00, 0x42]))!
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PeerID.self, from: encoded)
        #expect(original == decoded)
    }

    @Test("Hashable deduplication in Set")
    func hashable() {
        let id1 = PeerID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!
        let id2 = PeerID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!
        let id3 = PeerID(bytes: Data([8, 7, 6, 5, 4, 3, 2, 1]))!

        var set = Set<PeerID>()
        set.insert(id1)
        set.insert(id2)
        #expect(set.count == 1)
        set.insert(id3)
        #expect(set.count == 2)
    }

    @Test("Read/write to Data buffer round-trips")
    func readWrite() {
        let original = PeerID(bytes: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))!
        var data = Data()
        original.appendTo(&data)
        #expect(data.count == 8)

        var offset = 0
        let read = PeerID.read(from: data, offset: &offset)
        #expect(read == original)
        #expect(offset == 8)
    }

    @Test("Read from insufficient data returns nil")
    func readInsufficient() {
        let data = Data([0x01, 0x02])
        var offset = 0
        #expect(PeerID.read(from: data, offset: &offset) == nil)
    }
}

@Suite("Packet")
struct PacketStructTests {

    @Test("Header size is 16 bytes")
    func headerSize() {
        #expect(Packet.headerSize == 16)
    }

    @Test("Max payload arithmetic matches spec Section 5.1")
    func maxPayloads() {
        #expect(Packet.maxPayloadAddressedSigned == 416)
        #expect(Packet.maxPayloadBroadcastSigned == 424)
        #expect(Packet.maxPayloadAddressedUnsigned == 480)
        #expect(Packet.maxPayloadBroadcastUnsigned == 488)

        // Verify arithmetic: MTU - header - sender - recipient - signature
        let addressedSigned: Int = 512 - 16 - 8 - 8 - 64
        let broadcastSigned: Int = 512 - 16 - 8 - 64
        let addressedUnsigned: Int = 512 - 16 - 8 - 8
        let broadcastUnsigned: Int = 512 - 16 - 8
        #expect(addressedSigned == 416)
        #expect(broadcastSigned == 424)
        #expect(addressedUnsigned == 480)
        #expect(broadcastUnsigned == 488)
    }

    @Test("Fragmentation threshold is 416")
    func fragmentationThreshold() {
        #expect(Packet.fragmentationThreshold == 416)
    }

    @Test("Wire size calculated correctly for various configurations")
    func wireSize() {
        let sender = PeerID(bytes: Data(repeating: 0x01, count: 8))!
        let recipient = PeerID(bytes: Data(repeating: 0x02, count: 8))!
        let sig = Data(repeating: 0xAA, count: 64)
        let payload = Data(repeating: 0xBB, count: 100)

        let p1 = Packet(
            type: .noiseEncrypted, ttl: 5,
            timestamp: 1000, flags: [.hasRecipient, .hasSignature],
            senderID: sender, recipientID: recipient,
            payload: payload, signature: sig
        )
        let expected1 = 196 // 16 + 8 + 8 + 100 + 64
        #expect(p1.wireSize == expected1)

        let p2 = Packet(
            type: .meshBroadcast, ttl: 3,
            timestamp: 1000, flags: [],
            senderID: sender, payload: payload
        )
        let expected2 = 124 // 16 + 8 + 100
        #expect(p2.wireSize == expected2)
    }

    @Test("Timestamp produces recent Date")
    func timestamp() {
        let ts = Packet.currentTimestamp()
        #expect(ts > 0)

        let packet = Packet(
            type: .announce, ttl: 3,
            timestamp: ts, flags: [],
            senderID: PeerID(bytes: Data(repeating: 0x01, count: 8))!,
            payload: Data()
        )

        let date = packet.date
        let now = Date()
        #expect(abs(date.timeIntervalSince(now)) < 2.0)
    }

    @Test("maxPayloadForFlags returns correct values")
    func maxPayloadForFlags() {
        let sender = PeerID(bytes: Data(repeating: 0x01, count: 8))!

        let broadcastUnsigned = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [], senderID: sender, payload: Data()
        )
        #expect(broadcastUnsigned.maxPayloadForFlags == 488)

        let broadcastSigned = Packet(
            type: .meshBroadcast, ttl: 3, timestamp: 1000,
            flags: [.hasSignature], senderID: sender, payload: Data(),
            signature: Data(repeating: 0, count: 64)
        )
        #expect(broadcastSigned.maxPayloadForFlags == 424)

        let addressedSigned = Packet(
            type: .noiseEncrypted, ttl: 5, timestamp: 1000,
            flags: [.hasRecipient, .hasSignature], senderID: sender,
            recipientID: PeerID(bytes: Data(repeating: 0x02, count: 8))!,
            payload: Data(),
            signature: Data(repeating: 0, count: 64)
        )
        #expect(addressedSigned.maxPayloadForFlags == 416)
    }
}

@Suite("ProximityPingPayload")
struct ProximityPingPayloadTests {

    @Test("Proximity ping round-trips")
    func roundTrip() {
        let payload = ProximityPingPayload(rssiHint: -72)
        let data = payload.serialize()

        #expect(data.count == ProximityPingPayload.serializedSize)
        #expect(ProximityPingPayload.deserialize(from: data)?.rssiHint == -72)
    }

    @Test("Default RSSI hint is unavailable")
    func unavailableRSSI() {
        let payload = ProximityPingPayload()
        #expect(payload.rssiHint == ProximityPingPayload.unavailableRSSI)
    }

    @Test("Too-short data returns nil")
    func tooShortReturnsNil() {
        #expect(ProximityPingPayload.deserialize(from: Data([0x01])) == nil)
        #expect(ProximityPingPayload.deserialize(from: Data()) == nil)
    }
}

@Suite("EncryptedSubType")
struct EncryptedSubTypeTests {

    @Test("Raw values match spec Section 6.5")
    func rawValues() {
        #expect(EncryptedSubType.privateMessage.rawValue == 0x01)
        #expect(EncryptedSubType.groupMessage.rawValue == 0x02)
        #expect(EncryptedSubType.deliveryAck.rawValue == 0x03)
        #expect(EncryptedSubType.readReceipt.rawValue == 0x04)
        #expect(EncryptedSubType.voiceNote.rawValue == 0x05)
        #expect(EncryptedSubType.imageMessage.rawValue == 0x06)
        #expect(EncryptedSubType.friendRequest.rawValue == 0x07)
        #expect(EncryptedSubType.friendAccept.rawValue == 0x08)
        #expect(EncryptedSubType.typingIndicator.rawValue == 0x09)
        #expect(EncryptedSubType.messageDelete.rawValue == 0x0A)
        #expect(EncryptedSubType.messageEdit.rawValue == 0x0B)
        #expect(EncryptedSubType.profileRequest.rawValue == 0x10)
        #expect(EncryptedSubType.profileResponse.rawValue == 0x11)
        #expect(EncryptedSubType.groupKeyDistribution.rawValue == 0x12)
        #expect(EncryptedSubType.groupMemberAdd.rawValue == 0x13)
        #expect(EncryptedSubType.groupMemberRemove.rawValue == 0x14)
        #expect(EncryptedSubType.groupAdminChange.rawValue == 0x15)
        #expect(EncryptedSubType.blockVote.rawValue == 0x16)
        #expect(EncryptedSubType.pttAudio.rawValue == 0x17)
    }

    @Test("All cases count is 20")
    func allCasesCount() {
        #expect(EncryptedSubType.allCases.count == 20)
    }

    @Test("Group management sub-types identified")
    func groupManagement() {
        #expect(EncryptedSubType.groupKeyDistribution.isGroupManagement)
        #expect(EncryptedSubType.groupMemberAdd.isGroupManagement)
        #expect(EncryptedSubType.groupMemberRemove.isGroupManagement)
        #expect(EncryptedSubType.groupAdminChange.isGroupManagement)
        #expect(!EncryptedSubType.privateMessage.isGroupManagement)
    }

    @Test("Free (non-billable) actions identified")
    func freeActions() {
        #expect(EncryptedSubType.deliveryAck.isFreeAction)
        #expect(EncryptedSubType.readReceipt.isFreeAction)
        #expect(EncryptedSubType.typingIndicator.isFreeAction)
        #expect(EncryptedSubType.friendRequest.isFreeAction)
        #expect(EncryptedSubType.friendAccept.isFreeAction)
        #expect(!EncryptedSubType.privateMessage.isFreeAction)
        #expect(!EncryptedSubType.voiceNote.isFreeAction)
        #expect(!EncryptedSubType.pttAudio.isFreeAction)
    }
}

@Suite("PacketValidator")
struct PacketValidatorTests {

    private func makeValidPacket() -> Packet {
        Packet(
            type: .meshBroadcast,
            ttl: 5,
            timestamp: Packet.currentTimestamp(),
            flags: [],
            senderID: PeerID(bytes: Data(repeating: 0x01, count: 8))!,
            payload: Data("hello".utf8)
        )
    }

    @Test("Valid packet passes validation")
    func validPacket() {
        let packet = makeValidPacket()
        let errors = PacketValidator.validate(packet)
        #expect(errors.isEmpty)
        #expect(PacketValidator.isValid(packet))
    }

    @Test("Invalid version reported")
    func invalidVersion() {
        var packet = makeValidPacket()
        packet.version = 0x99
        let errors = PacketValidator.validate(packet)
        #expect(errors.contains(.unknownVersion(0x99)))
    }

    @Test("TTL out of range reported")
    func invalidTTL() {
        var packet = makeValidPacket()
        packet.ttl = 8
        let errors = PacketValidator.validate(packet)
        #expect(errors.contains(.ttlOutOfRange(8)))
    }

    @Test("Future timestamp beyond tolerance is flagged")
    func futureTimestamp() {
        var packet = makeValidPacket()
        packet.timestamp = Packet.currentTimestamp() + 60_000
        let errors = PacketValidator.validate(packet)
        #expect(errors.contains(where: {
            if case .timestampInFuture = $0 { return true }
            return false
        }))
    }

    @Test("Timestamp within tolerance passes")
    func withinTolerance() {
        var packet = makeValidPacket()
        packet.timestamp = Packet.currentTimestamp() + 20_000
        let errors = PacketValidator.validate(packet)
        #expect(!errors.contains(where: {
            if case .timestampInFuture = $0 { return true }
            return false
        }))
    }

    @Test("hasRecipient flag without recipientID is inconsistent")
    func inconsistentRecipient() {
        var packet = makeValidPacket()
        packet.flags = [.hasRecipient]
        packet.recipientID = nil
        let errors = PacketValidator.validate(packet)
        #expect(errors.contains(where: {
            if case .flagsInconsistent = $0 { return true }
            return false
        }))
    }

    @Test("hasSignature flag without signature is inconsistent")
    func inconsistentSignature() {
        var packet = makeValidPacket()
        packet.flags = [.hasSignature]
        packet.signature = nil
        let errors = PacketValidator.validate(packet)
        #expect(errors.contains(where: {
            if case .flagsInconsistent = $0 { return true }
            return false
        }))
    }

    @Test("Quick validate checks header fields")
    func quickValidate() {
        var data = Data(repeating: 0, count: 16)
        data[0] = 0x01
        data[2] = 3
        #expect(PacketValidator.quickValidate(data).isEmpty)

        let short = Data(repeating: 0, count: 5)
        let shortErrors = PacketValidator.quickValidate(short)
        #expect(shortErrors.contains(where: {
            if case .packetTooSmall = $0 { return true }
            return false
        }))
    }

    @Test("Quick validate rejects oversized payload claims from the header")
    func quickValidateRejectsOversizedPayload() {
        var data = Data(repeating: 0, count: 16)
        data[0] = Packet.currentVersion
        data[2] = 3
        data[12] = 0x00
        data[13] = 0x04
        data[14] = 0x00
        data[15] = 0x01

        let errors = PacketValidator.quickValidate(data)
        #expect(errors.contains(.payloadTooLarge(PacketValidator.maxPayloadLength + 1)))
    }
}
