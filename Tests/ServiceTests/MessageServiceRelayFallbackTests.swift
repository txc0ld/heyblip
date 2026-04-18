import XCTest
import SwiftData
@testable import Blip
@testable import BlipProtocol
@testable import BlipMesh
@testable import BlipCrypto

/// Regression tests for the broadcast-fallback removal described in
/// CLAUDE.md:
///
/// > WebSocket relay TOCTOU: send errors are now surfaced via
/// > `TransportDelegate.transport(_:didFailDelivery:to:)` so the mesh layer
/// > can re-route instead of silently leaking DMs via a broadcast fallback.
///
/// The failure path flows Transport → `AppCoordinator.transport(_:didFailDelivery:to:)`
/// → `.didFailMessageDelivery` NotificationCenter → `MessageService.handleDeliveryFailureNotification`.
///
/// These tests post the notification directly and assert:
///
/// 1. The target `Message.status` is flipped to `.failed` and persisted.
/// 2. The failure path does NOT re-broadcast the packet (no silent fallback).
/// 3. A delivery failure for an already-delivered/read message is ignored
///    (no regression of a more-recent status).
@MainActor
final class MessageServiceRelayFallbackTests: XCTestCase {

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

    private func makeChannel(name: String = "Channel") -> Channel {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: name)
        context.insert(channel)
        try? context.save()
        return channel
    }

    private func makeMessage(channel: Channel, status: MessageStatus = .sent) -> Message {
        let context = ModelContext(container)
        let message = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("test".utf8),
            status: status
        )
        context.insert(message)
        try? context.save()
        return message
    }

    /// Build a broadcast (non-addressed) `.noiseEncrypted` packet whose
    /// payload declares subType `.privateMessage` and embeds `messageID` in
    /// the leading UUID slot so that `extractMessageID(fromFailedPacket:)`
    /// can recover it.
    private func buildFailedPacket(messageID: UUID, senderID: PeerID) throws -> Data {
        var payload = Data()
        payload.append(EncryptedSubType.privateMessage.rawValue)
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00) // end of messageID
        payload.append(0x00) // empty replyToID
        payload.append(Data("body".utf8))

        let packet = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: payload,
            flags: [],
            senderID: senderID,
            recipientID: nil
        )
        return try PacketSerializer.encode(packet)
    }

    /// Post a `.didFailMessageDelivery` notification and wait for the
    /// async handler in `MessageService` to drain.
    private func postFailureAndWait(
        data: Data,
        peerID: PeerID? = nil
    ) async {
        var userInfo: [AnyHashable: Any] = ["data": data]
        if let peerID {
            userInfo["peerID"] = peerID.bytes
        }
        NotificationCenter.default.post(
            name: .didFailMessageDelivery,
            object: nil,
            userInfo: userInfo
        )

        // Handler hops to @MainActor via a Task — give it a beat.
        let expectation = expectation(description: "delivery-failure handler")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Tests

    func test_deliveryFailureNotification_marksMessageAsFailed() async throws {
        let channel = makeChannel()
        let message = makeMessage(channel: channel, status: .sent)
        let broadcastsBefore = mockTransport.broadcastPackets.count
        let sentsBefore = mockTransport.sentPackets.count

        let data = try buildFailedPacket(messageID: message.id, senderID: identity.peerID)
        await postFailureAndWait(data: data)

        // Fresh context to prove persistence.
        let freshContext = ModelContext(container)
        let messageID = message.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let persisted = try XCTUnwrap(try freshContext.fetch(descriptor).first)
        XCTAssertEqual(persisted.status, .failed)

        // Critical: we must NOT have silently re-broadcast or re-sent.
        XCTAssertEqual(
            mockTransport.broadcastPackets.count, broadcastsBefore,
            "delivery failure must not trigger a silent broadcast fallback"
        )
        XCTAssertEqual(
            mockTransport.sentPackets.count, sentsBefore,
            "delivery failure must not trigger a silent unicast retry"
        )
    }

    func test_deliveryFailureForDeliveredMessage_doesNotRegressStatus() async throws {
        let channel = makeChannel()
        let message = makeMessage(channel: channel, status: .delivered)

        let data = try buildFailedPacket(messageID: message.id, senderID: identity.peerID)
        await postFailureAndWait(data: data)

        let freshContext = ModelContext(container)
        let messageID = message.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let persisted = try XCTUnwrap(try freshContext.fetch(descriptor).first)
        XCTAssertEqual(
            persisted.status, .delivered,
            "a later delivery-failure notification must not regress an already-delivered message"
        )
    }

    func test_deliveryFailureForReadMessage_doesNotRegressStatus() async throws {
        let channel = makeChannel()
        let message = makeMessage(channel: channel, status: .read)

        let data = try buildFailedPacket(messageID: message.id, senderID: identity.peerID)
        await postFailureAndWait(data: data)

        let freshContext = ModelContext(container)
        let messageID = message.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let persisted = try XCTUnwrap(try freshContext.fetch(descriptor).first)
        XCTAssertEqual(persisted.status, .read)
    }

    func test_deliveryFailureForUnknownMessageID_isNoOp() async throws {
        // Build a packet referencing a messageID that doesn't exist in the
        // store. The handler must swallow it cleanly — no crash, no writes.
        let channel = makeChannel()
        let existing = makeMessage(channel: channel, status: .sent)

        let strayID = UUID()
        XCTAssertNotEqual(strayID, existing.id)

        let data = try buildFailedPacket(messageID: strayID, senderID: identity.peerID)
        await postFailureAndWait(data: data)

        // The existing message is untouched.
        let freshContext = ModelContext(container)
        let existingID = existing.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == existingID })
        let persisted = try XCTUnwrap(try freshContext.fetch(descriptor).first)
        XCTAssertEqual(persisted.status, .sent)
    }
}
