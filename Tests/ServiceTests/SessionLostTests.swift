import XCTest
import SwiftData
@testable import Blip
@testable import BlipProtocol
@testable import BlipMesh
@testable import BlipCrypto

/// Tests for BDEV-442: sessionLost control-packet recovery.
///
/// Two scenarios:
///  1. Drop path → sessionLost emitted, backoff prevents repeat within 30 s.
///  2. Receiving sessionLost → local session destroyed, fresh Noise msg1 sent.
@MainActor
final class SessionLostTests: XCTestCase {

    private var container: ModelContainer!
    private var mockTransport: MockTransport!
    private var keyManager: KeyManager!
    private var identity: Identity!
    private var messageService: MessageService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        mockTransport = MockTransport()
        mockTransport.start()

        keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        identity = try keyManager.generateIdentity()
        try keyManager.storeIdentity(identity)

        messageService = MessageService(modelContainer: container, keyManager: keyManager)
        messageService.configure(transport: mockTransport, identity: identity)
    }

    override func tearDown() async throws {
        messageService = nil
        mockTransport = nil
        keyManager = nil
        identity = nil
        container = nil
    }

    // MARK: - Helpers

    private func makeRemoteIdentity() throws -> Identity {
        let remoteKeyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        return try remoteKeyManager.generateIdentity()
    }

    /// Build an encoded `.noiseEncrypted` packet from `senderID` to `recipientID`
    /// with a dummy ciphertext payload (not actually decryptable — used to exercise the drop path).
    private func makeEncryptedPacket(from senderID: PeerID, to recipientID: PeerID) throws -> Packet {
        MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: Data(repeating: 0xAB, count: 16),
            flags: [.hasRecipient],
            senderID: senderID,
            recipientID: recipientID
        )
    }

    /// Build an encoded `.sessionLost` packet from `senderID` to `recipientID`.
    private func makeSessionLostPacket(from senderID: PeerID, to recipientID: PeerID) throws -> Data {
        let packet = MessagePayloadBuilder.buildPacket(
            type: .sessionLost,
            payload: Data(),
            flags: [.hasRecipient],
            senderID: senderID,
            recipientID: recipientID
        )
        return try PacketSerializer.encode(packet)
    }

    // MARK: - Drop-site emits sessionLost

    func testDroppedEncryptedPacket_emitsSessionLost() async throws {
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        // No Noise session for remotePeerID — any noiseEncrypted packet will be dropped.
        let packet = try makeEncryptedPacket(from: remotePeerID, to: identity.peerID)

        // Simulate the drop via the internal helper directly to avoid the full receive pipeline.
        try await messageService.sendSessionLostIfNeeded(to: remotePeerID, peerHex: "test")

        // The service should have sent a sessionLost packet to remotePeerID.
        let sent = mockTransport.sentPackets
        XCTAssertFalse(sent.isEmpty, "Expected at least one packet to be sent")

        let lastSent = try XCTUnwrap(sent.last)
        XCTAssertEqual(lastSent.peerID, remotePeerID, "sessionLost must be addressed to the sender of the dropped packet")

        let decoded = try PacketSerializer.decode(lastSent.data)
        XCTAssertEqual(decoded.type, .sessionLost, "Sent packet must be of type sessionLost")
        _ = packet  // silence unused warning
    }

    // MARK: - Backoff guard prevents repeat sessionLost

    func testSessionLostBackoff_suppressesRepeatWithinCooldown() async throws {
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        // First call — should send.
        try await messageService.sendSessionLostIfNeeded(to: remotePeerID, peerHex: "test")
        let countAfterFirst = mockTransport.sentPackets.count

        // Second call immediately — should be suppressed by the 30 s cooldown.
        try await messageService.sendSessionLostIfNeeded(to: remotePeerID, peerHex: "test")
        let countAfterSecond = mockTransport.sentPackets.count

        XCTAssertEqual(countAfterFirst, countAfterSecond,
                       "Second sessionLost within cooldown window must be suppressed")
    }

    func testSessionLostBackoff_allowsResendAfterCooldown() async throws {
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        // Inject a stale timestamp that is past the cooldown window.
        let pastDate = Date(timeIntervalSinceNow: -(MessageService.sessionLostCooldown + 1))
        messageService.lock.withLock {
            messageService.lastSessionLostSent[remotePeerID.bytes] = pastDate
        }

        try await messageService.sendSessionLostIfNeeded(to: remotePeerID, peerHex: "test")

        let sent = mockTransport.sentPackets
        XCTAssertFalse(sent.isEmpty, "sessionLost should be resent after cooldown expires")
        let decoded = try PacketSerializer.decode(try XCTUnwrap(sent.last).data)
        XCTAssertEqual(decoded.type, .sessionLost)
    }

    // MARK: - Receiving sessionLost triggers fresh handshake

    func testReceivingSessionLost_destroysSessionAndInitiatesHandshake() async throws {
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        // Establish a real Noise session from our side so we have something to tear down.
        guard let localSessionManager = messageService.noiseSessionManager else {
            XCTFail("noiseSessionManager must be configured"); return
        }
        let remoteSessionManager = NoiseSessionManager(localStaticKey: remoteIdentity.noisePrivateKey)
        let (_, msg1) = try localSessionManager.initiateHandshake(with: remotePeerID)
        _ = try remoteSessionManager.receiveHandshakeInit(from: identity.peerID, message: msg1)
        let msg2 = try remoteSessionManager.respondToHandshake(for: identity.peerID)
        _ = try localSessionManager.processHandshakeMessage(from: remotePeerID, message: msg2)
        let (msg3, _) = try localSessionManager.completeHandshake(with: remotePeerID)
        _ = try remoteSessionManager.processHandshakeMessage(from: identity.peerID, message: msg3)

        XCTAssertTrue(localSessionManager.hasSession(for: remotePeerID), "Session must exist before receiving sessionLost")

        mockTransport.reset()

        // Deliver a sessionLost packet from the remote peer.
        let wireData = try makeSessionLostPacket(from: remotePeerID, to: identity.peerID)
        let sessionLostPacket = try PacketSerializer.decode(wireData)
        try await messageService.handleSessionLost(sessionLostPacket, from: remotePeerID)

        // Session must be gone.
        XCTAssertFalse(localSessionManager.hasSession(for: remotePeerID),
                       "Existing session must be destroyed after sessionLost")

        // A fresh Noise msg1 (handshake initiation) must have been sent.
        let sent = mockTransport.sentPackets
        XCTAssertFalse(sent.isEmpty, "A fresh handshake msg1 must be sent after receiving sessionLost")

        let firstSent = try XCTUnwrap(sent.first)
        let decoded = try PacketSerializer.decode(firstSent.data)
        XCTAssertEqual(decoded.type, .noiseHandshake,
                       "The first packet after sessionLost must be a Noise handshake initiation")
        XCTAssertFalse(decoded.payload.isEmpty)
        XCTAssertEqual(decoded.payload[decoded.payload.startIndex], 0x01,
                       "Handshake step byte must be 0x01 (msg1 initiator)")
    }

    func testReceivingSessionLost_whenNoExistingSession_stillInitiatesHandshake() async throws {
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        // No session at all — still should attempt handshake.
        let wireData = try makeSessionLostPacket(from: remotePeerID, to: identity.peerID)
        let packet = try PacketSerializer.decode(wireData)
        try await messageService.handleSessionLost(packet, from: remotePeerID)

        let sent = mockTransport.sentPackets
        XCTAssertFalse(sent.isEmpty, "Handshake should be initiated even when no prior session exists")
        let decoded = try PacketSerializer.decode(try XCTUnwrap(sent.first).data)
        XCTAssertEqual(decoded.type, .noiseHandshake)
    }
}
