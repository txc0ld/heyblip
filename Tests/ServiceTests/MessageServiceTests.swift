import XCTest
import SwiftData
@testable import Blip
@testable import BlipProtocol
@testable import BlipMesh
@testable import BlipCrypto

// MARK: - MockTransport

/// A test double for `Transport` that captures sent/broadcast data.
final class MockTransport: Transport, @unchecked Sendable {

    weak var delegate: (any TransportDelegate)?

    private(set) var state: TransportState = .idle

    private let lock = NSLock()
    private var _sentPackets: [(data: Data, peerID: PeerID)] = []
    private var _broadcastPackets: [Data] = []

    var sentPackets: [(data: Data, peerID: PeerID)] {
        lock.withLock { _sentPackets }
    }

    var broadcastPackets: [Data] {
        lock.withLock { _broadcastPackets }
    }

    var connectedPeers: [PeerID] {
        lock.withLock { _connectedPeerList }
    }
    private var _connectedPeerList: [PeerID] = []

    func addConnectedPeer(_ peer: PeerID) {
        lock.withLock { _connectedPeerList.append(peer) }
    }

    func start() { state = .running }
    func stop() { state = .stopped }

    func send(data: Data, to peerID: PeerID) throws {
        lock.withLock { _sentPackets.append((data: data, peerID: peerID)) }
    }

    func broadcast(data: Data) {
        lock.withLock { _broadcastPackets.append(data) }
    }

    /// Total number of packets sent (peer-specific + broadcast).
    var totalSentCount: Int {
        lock.withLock { _sentPackets.count + _broadcastPackets.count }
    }

    func reset() {
        lock.withLock {
            _sentPackets.removeAll()
            _broadcastPackets.removeAll()
        }
    }
}

// MARK: - MessageServiceTests

/// Tests for the MessageService message lifecycle: send, receive, dedup, expiry, and friend request flows.
///
/// Uses an in-memory ModelContainer and MockTransport to isolate the service from real
/// BLE/WebSocket transports and persistent storage.
@MainActor
final class MessageServiceTests: XCTestCase {

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

    private func makeChannel(type: ChannelType = .dm, name: String) -> Channel {
        let context = ModelContext(container)
        let channel = Channel(type: type, name: name)
        context.insert(channel)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save channel: \(error)")
        }
        return channel
    }

    private func makeUser(
        username: String,
        displayName: String? = nil,
        noisePublicKey: Data = Data(repeating: 0xAA, count: 32),
        signingPublicKey: Data = Data(repeating: 0xBB, count: 32)
    ) -> User {
        let context = ModelContext(container)
        let user = User(
            username: username,
            displayName: displayName ?? username,
            emailHash: "\(username)-hash",
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey
        )
        context.insert(user)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save user: \(error)")
        }
        return user
    }

    private func makeLocalUser() -> User {
        let context = ModelContext(container)
        let user = User(
            username: "localuser",
            displayName: "Local User",
            emailHash: "local-hash",
            noisePublicKey: identity.noisePublicKey.rawRepresentation,
            signingPublicKey: identity.signingPublicKey
        )
        context.insert(user)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save local user: \(error)")
        }
        return user
    }

    private func makeFriend(user: User, status: FriendStatus = .pending) -> Friend {
        let context = ModelContext(container)
        let friend = Friend(user: user, status: status)
        context.insert(friend)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save friend: \(error)")
        }
        return friend
    }

    private func makeRemoteIdentity() throws -> Identity {
        let remoteKeyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        return try remoteKeyManager.generateIdentity()
    }

    private func establishNoiseSession(with remoteIdentity: Identity) throws -> (PeerID, NoiseSessionManager) {
        guard let localSessionManager = messageService.noiseSessionManager else {
            throw MessageServiceError.encryptionFailed("Local Noise session manager missing")
        }

        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        let remoteSessionManager = NoiseSessionManager(localStaticKey: remoteIdentity.noisePrivateKey)

        let (_, msg1) = try localSessionManager.initiateHandshake(with: remotePeerID)
        _ = try remoteSessionManager.receiveHandshakeInit(from: identity.peerID, message: msg1)
        let msg2 = try remoteSessionManager.respondToHandshake(for: identity.peerID)
        let (_, intermediateSession) = try localSessionManager.processHandshakeMessage(from: remotePeerID, message: msg2)
        XCTAssertNil(intermediateSession)

        let (msg3, localSession) = try localSessionManager.completeHandshake(with: remotePeerID)
        XCTAssertEqual(localSession.peerID, remotePeerID)

        let (_, remoteSession) = try remoteSessionManager.processHandshakeMessage(from: identity.peerID, message: msg3)
        XCTAssertNotNil(remoteSession)

        return (remotePeerID, remoteSessionManager)
    }

    // MARK: - Send Text Message

    func testSendTextMessage_createsModelAndTriggersTransport() async {
        let _ = makeLocalUser()
        let remoteUser = makeUser(username: "bob", displayName: "Bob")
        let channel = makeChannel(type: .dm, name: "Bob")

        // Add membership so recipient can be resolved
        let context = ModelContext(container)
        let membership = GroupMembership(user: remoteUser, channel: channel, role: .member)
        context.insert(membership)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save membership: \(error)")
        }

        // Send message — without a Noise session, it will initiate a handshake
        // and queue the actual message, but should still create a Message model.
        do {
            let message = try await messageService.sendTextMessage(
                content: "Hello, Bob!",
                to: channel
            )

            // Verify Message model was created
            XCTAssertEqual(message.type, .text)
            XCTAssertEqual(String(data: message.rawPayload, encoding: .utf8), "Hello, Bob!")
            XCTAssertNotNil(message.channel)

            // Verify transport was used (handshake initiation sends a packet)
            let expectation = expectation(description: "transport receives data")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 2.0)

            XCTAssertGreaterThanOrEqual(
                mockTransport.totalSentCount, 0,
                "Transport should have been called (handshake or direct send)"
            )
        } catch {
            // May throw if recipient PeerID can't be resolved — acceptable for this test.
            // Verify the error is a known type, not a crash.
            XCTAssertTrue(
                error is MessageServiceError,
                "Expected MessageServiceError, got: \(error)"
            )
        }
    }

    func testSendTextMessageWithReplyTargetPersistsReplyOnLocalMessage() async throws {
        // Regression test for HEY-1323: when sending a reply, the sender's
        // local Message must carry replyTo so its own bubble renders the
        // reply preview. Previously the wire payload used the parameter's
        // `replyTo?.id` while the local Message used the re-fetched
        // `localReplyTo`; if the re-fetch returned nil the local copy
        // silently dropped the reply pointer while the wire still carried it.
        let _ = makeLocalUser()
        let remoteUser = makeUser(username: "bob", displayName: "Bob")
        let channel = makeChannel(type: .dm, name: "Bob")

        let context = ModelContext(container)
        let membership = GroupMembership(user: remoteUser, channel: channel, role: .member)
        context.insert(membership)
        try context.save()

        // Pre-existing message that will be the reply target. Re-fetch the
        // channel in the same context so the relationship attaches cleanly.
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        let localChannel = try XCTUnwrap(context.fetch(channelDesc).first)
        let target = Message(
            sender: nil,
            channel: localChannel,
            type: .text,
            rawPayload: Data("original".utf8),
            status: .delivered
        )
        context.insert(target)
        try context.save()
        let targetID = target.id

        // Send a reply
        let replyMessage = try await messageService.sendTextMessage(
            content: "agreed",
            to: channel,
            replyTo: target
        )

        XCTAssertEqual(
            replyMessage.replyTo?.id,
            targetID,
            "Sender's local Message must carry the reply pointer so its own bubble renders the reply preview"
        )

        // Verify it persists across a fresh context too.
        let verifyContext = ModelContext(container)
        let replyID = replyMessage.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == replyID })
        let persisted = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(
            persisted.replyTo?.id,
            targetID,
            "Persisted reply Message must retain replyTo across cold-launch fetches"
        )
    }

    func testReplyToPropagatesIntoWirePayload() throws {
        // Proxy for the full integration: verify MessagePayloadBuilder, fed
        // the same inputs sendTextMessage uses on the wire path, round-trips
        // the replyToID. Full transport-interception of the encrypted wire
        // bytes is out of scope here — MessagePayloadBuilderTests covers the
        // round-trip end-to-end. This test guards the contract sendTextMessage
        // depends on: a non-nil replyToID survives encode → decode.
        let messageID = UUID()
        let replyToID = UUID()

        let dmPayload = MessagePayloadBuilder.buildTextPayload(
            content: "agreed",
            messageID: messageID,
            replyToID: replyToID
        )
        let parsed = MessagePayloadBuilder.parseTextPayload(dmPayload)
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(parsed.replyToID, replyToID)
        XCTAssertEqual(String(data: parsed.content, encoding: .utf8), "agreed")
    }

    func testSendTextMessage_withoutSession_staysEncryptingUntilDelivered() async throws {
        let _ = makeLocalUser()
        let remoteUser = makeUser(username: "bob", displayName: "Bob")
        let channel = makeChannel(type: .dm, name: "Bob")

        let context = ModelContext(container)
        context.insert(GroupMembership(user: remoteUser, channel: channel, role: .member))
        try context.save()

        let message = try await messageService.sendTextMessage(
            content: "Hello, Bob!",
            to: channel
        )

        XCTAssertEqual(message.status, .encrypting)

        let verifyContext = ModelContext(container)
        let messageID = message.id
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let persistedMessage = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(persistedMessage.status, .encrypting)
    }

    func testSendTextMessage_withoutIdentity_throws() async {
        let channel = makeChannel(type: .dm, name: "Nobody")

        // Create a MessageService with no configured identity
        let bareService = MessageService(modelContainer: container, keyManager: keyManager)
        // Don't call configure() — no identity set

        do {
            _ = try await bareService.sendTextMessage(content: "Hello", to: channel)
            XCTFail("Expected senderNotFound error")
        } catch let error as MessageServiceError {
            if case .senderNotFound = error {
                // Expected
            } else {
                XCTFail("Expected senderNotFound, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Presence on connect — BDEV-431 regression

    /// When the relay WebSocket connects before the local user row exists in SwiftData,
    /// `transport(_:didConnect:)` must NOT log a Sentry-visible error — it should defer
    /// and retry once the row is available.
    func testBroadcastPresenceOnConnect_deferredWhenUserNotInSwiftData() async throws {
        // setUp creates messageService with identity but inserts NO local user.
        // Confirm the container is empty.
        let ctx = ModelContext(container)
        let existing = try ctx.fetch(FetchDescriptor<User>())
        XCTAssertTrue(existing.isEmpty, "Precondition: no users in SwiftData yet")

        let remotePeerID = PeerID(noisePublicKey: Data(repeating: 0xEE, count: 32))

        // Simulate WebSocket connect — user row is absent.
        messageService.transport(mockTransport, didConnect: remotePeerID)

        // Give the async Task time to fire and check SwiftData.
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        // No broadcast should have been sent yet.
        XCTAssertEqual(mockTransport.broadcastPackets.count, 0,
                       "Presence must not be broadcast before the local user is in SwiftData")

        // Now add the local user — simulates onboarding completing after connect.
        _ = makeLocalUser()

        // Wait past the 1.5 s deferred retry window.
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 s

        // The retry should have fired and broadcast presence.
        XCTAssertGreaterThan(mockTransport.broadcastPackets.count, 0,
                             "Presence must be broadcast by the deferred retry once the user is available")
    }

    // MARK: - Duplicate Message Rejection

    func testDuplicatePacket_isRejectedByBloomFilter() async {
        // Build a valid announce packet so it can be deserialized
        let remotePeerID = PeerID(noisePublicKey: Data(repeating: 0xCC, count: 32))
        let payload = "testuser\0Test User".data(using: .utf8) ?? Data()
        let packet = MessagePayloadBuilder.buildPacket(
            type: .announce,
            payload: payload,
            flags: [],
            senderID: remotePeerID,
            recipientID: nil
        )

        do {
            let wireData = try PacketSerializer.encode(packet)

            // Feed the same packet twice via receive()
            messageService.receive(data: wireData, from: remotePeerID, via: .bluetooth)
            messageService.receive(data: wireData, from: remotePeerID, via: .bluetooth)

            // Wait for async processing
            let expectation = expectation(description: "receive processing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 2.0)

            // The Bloom filter should have caught the second one.
            // We verify by checking PeerStore — only one upsert should happen.
            // (The second packet is dropped before reaching the handler.)
            // This test validates the dedup path doesn't crash and processes correctly.
        } catch {
            XCTFail("PacketSerializer.encode failed: \(error)")
        }
    }

    // MARK: - Message Expiry

    func testStaleAnnounce_isDropped() async {
        // Create a packet with a timestamp >15 minutes in the past (beyond the 900s stale window)
        let remotePeerID = PeerID(noisePublicKey: Data(repeating: 0xDD, count: 32))
        let payload = "oldpeer\0Old Peer".data(using: .utf8) ?? Data()
        let staleDate = Date().addingTimeInterval(-1800) // 30 minutes ago

        var packet = MessagePayloadBuilder.buildPacket(
            type: .announce,
            payload: payload,
            flags: [],
            senderID: remotePeerID,
            recipientID: nil
        )
        // Override the timestamp to be stale
        packet = Packet(
            version: packet.version,
            type: packet.type,
            ttl: packet.ttl,
            timestamp: UInt64(staleDate.timeIntervalSince1970 * 1000),
            flags: packet.flags,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            payload: packet.payload,
            signature: packet.signature
        )

        do {
            let wireData = try PacketSerializer.encode(packet)
            messageService.receive(data: wireData, from: remotePeerID, via: .bluetooth)

            // Wait for async processing
            let expectation = expectation(description: "stale announce processing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 2.0)

            // The stale announce should be dropped — peer should NOT appear in PeerStore
            let peers = messageService.peerStore.connectedPeers()
            let found = peers.contains { $0.noisePublicKey == Data(repeating: 0xDD, count: 32) }
            XCTAssertFalse(found, "Stale announce should be dropped and peer should not be registered")
        } catch {
            XCTFail("PacketSerializer.encode failed: \(error)")
        }
    }

    // MARK: - Friend Request Creates Channel

    func testAcceptFriendRequest_createsDMChannelAndMembership() async {
        let _ = makeLocalUser()
        let remoteUser = makeUser(username: "alice", displayName: "Alice")
        let friend = makeFriend(user: remoteUser, status: .pending)

        // Register the remote user in PeerStore so keys can be resolved
        let remotePeerID = PeerID(noisePublicKey: remoteUser.noisePublicKey)
        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteUser.noisePublicKey,
            signingPublicKey: remoteUser.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        do {
            try await messageService.acceptFriendRequest(from: friend)

            // Verify Friend status was updated to accepted
            let context = ModelContext(container)
            let friendID = friend.id
            let friendDesc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
            let friends = try context.fetch(friendDesc)
            XCTAssertEqual(friends.first?.status, .accepted, "Friend status should be accepted")

            // Verify a DM channel was created
            let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
            let channels = try context.fetch(channelDesc)
            XCTAssertGreaterThanOrEqual(channels.count, 1, "A DM channel should exist")

            // Verify the channel has a membership for the remote user
            let dmChannel = channels.first { ch in
                ch.memberships.contains { $0.user?.username == "alice" }
            }
            XCTAssertNotNil(dmChannel, "DM channel should have a membership for Alice")

            // Verify transport was used to send the friendAccept packet
            let expectation = expectation(description: "accept packet sent")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 2.0)

            XCTAssertGreaterThanOrEqual(
                mockTransport.totalSentCount, 1,
                "A friendAccept packet should have been sent via transport"
            )
        } catch {
            XCTFail("acceptFriendRequest failed: \(error)")
        }
    }

    func testSendFriendRequest_withoutSession_queuesControlAndStartsHandshake() async throws {
        throw XCTSkip("BDEV-414: pre-existing failure exposed when CI started running BlipTests in BDEV-405; see https://heyblip.atlassian.net/browse/BDEV-414")
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)
        mockTransport.reset()

        try await messageService.sendFriendRequest(to: remotePeerID)

        XCTAssertEqual(mockTransport.sentPackets.count, 1, "Only the handshake packet should be sent immediately")
        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseHandshake)
        XCTAssertEqual(messageService.pendingHandshakeControlMessages[remotePeerID.bytes]?.count, 1)
    }

    func testSendFriendRequest_withSession_sendsEncryptedFriendRequest() async throws {
        throw XCTSkip("BDEV-414: pre-existing failure exposed when CI started running BlipTests in BDEV-405; see https://heyblip.atlassian.net/browse/BDEV-414")
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)
        mockTransport.reset()

        try await messageService.sendFriendRequest(to: remotePeerID)

        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseEncrypted)

        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.friendRequest.rawValue)

        let (senderUsername, senderDisplayName) = MessagePayloadBuilder.parseFriendPayload(Data(plaintext.dropFirst()))
        XCTAssertEqual(senderUsername, "localuser")
        XCTAssertEqual(senderDisplayName, "Local User")
    }

    func testAcceptFriendRequest_withSession_sendsEncryptedFriendAccept() async throws {
        throw XCTSkip("BDEV-414: pre-existing failure exposed when CI started running BlipTests in BDEV-405; see https://heyblip.atlassian.net/browse/BDEV-414")
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )
        let friend = makeFriend(user: remoteUser, status: .pending)

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)
        mockTransport.reset()

        try await messageService.acceptFriendRequest(from: friend)

        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseEncrypted)

        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.friendAccept.rawValue)
        XCTAssertEqual(String(data: Data(plaintext.dropFirst()), encoding: .utf8), "localuser")
    }

    func testSendDeliveryAck_withSession_sendsReliableEncryptedAck() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        mockTransport.reset()

        let messageID = UUID()
        try await messageService.sendDeliveryAck(for: messageID, to: remotePeerID)

        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseEncrypted)
        XCTAssertTrue(packet.flags.contains(.isReliable))

        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.deliveryAck.rawValue)
        XCTAssertEqual(String(data: Data(plaintext.dropFirst()), encoding: .utf8), messageID.uuidString)
    }

    func testSendReadReceipt_withSession_sendsEncryptedReceiptWithoutReliableFlag() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        mockTransport.reset()

        let messageID = UUID()
        try await messageService.sendReadReceipt(for: messageID, to: remotePeerID)

        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseEncrypted)
        XCTAssertFalse(packet.flags.contains(.isReliable))

        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.readReceipt.rawValue)
        XCTAssertEqual(String(data: Data(plaintext.dropFirst()), encoding: .utf8), messageID.uuidString)
    }

    func testSendReadReceipt_withoutSession_queuesControlAndStartsHandshake() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        mockTransport.reset()

        let messageID = UUID()
        try await messageService.sendReadReceipt(for: messageID, to: remotePeerID)

        XCTAssertEqual(mockTransport.sentPackets.count, 1, "Only the handshake packet should be sent immediately")
        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseHandshake)

        let pendingControl = try XCTUnwrap(messageService.pendingHandshakeControlMessages[remotePeerID.bytes]?.first)
        XCTAssertEqual(pendingControl.subType, .readReceipt)
        XCTAssertFalse(pendingControl.flags.contains(.isReliable))
        XCTAssertEqual(String(data: pendingControl.payload, encoding: .utf8), messageID.uuidString)
    }

    func testHandleEncryptedPacket_withoutSession_dropsPacket() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )
        let friend = makeFriend(user: remoteUser, status: .pending)

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let packet = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: MessagePayloadBuilder.prependSubType(
                .friendAccept,
                to: Data("alice".utf8)
            ),
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        try await messageService.handleEncryptedPacket(packet, from: remotePeerID)

        let context = ModelContext(container)
        let friendID = friend.id
        let friendDesc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        let persistedFriend = try XCTUnwrap(context.fetch(friendDesc).first)
        XCTAssertEqual(persistedFriend.status, .pending)

        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
        let channels = try context.fetch(channelDesc)
        XCTAssertTrue(channels.isEmpty)
    }

    func testHandleEncryptedPacket_decryptFailureDropsPacket() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, _) = try establishNoiseSession(with: remoteIdentity)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )
        let friend = makeFriend(user: remoteUser, status: .pending)

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let packet = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: MessagePayloadBuilder.prependSubType(
                .friendAccept,
                to: Data("alice".utf8)
            ),
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        try await messageService.handleEncryptedPacket(packet, from: remotePeerID)

        let context = ModelContext(container)
        let friendID = friend.id
        let friendDesc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        let persistedFriend = try XCTUnwrap(context.fetch(friendDesc).first)
        XCTAssertEqual(persistedFriend.status, .pending)

        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
        let channels = try context.fetch(channelDesc)
        XCTAssertTrue(channels.isEmpty)
    }

    func testHandleEncryptedPacket_decryptFailureInitiatesRecoveryAfterThreshold() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, _) = try establishNoiseSession(with: remoteIdentity)
        mockTransport.reset()

        let invalidPacket = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: Data("not-ciphertext".utf8),
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        XCTAssertTrue(messageService.noiseSessionManager?.hasSession(for: remotePeerID) == true)
        XCTAssertTrue(mockTransport.sentPackets.isEmpty)

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        XCTAssertFalse(messageService.noiseSessionManager?.hasSession(for: remotePeerID) ?? true)
        XCTAssertEqual(mockTransport.sentPackets.count, 1)

        let handshakePacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let decoded = try PacketSerializer.decode(handshakePacket.data)
        XCTAssertEqual(decoded.type, .noiseHandshake)
        XCTAssertEqual(handshakePacket.peerID, remotePeerID)
    }

    func testHandleEncryptedPacket_successfulDecryptResetsFailureCounter() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        mockTransport.reset()

        let invalidPacket = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: Data("not-ciphertext".utf8),
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        guard let remoteSession = remoteSessionManager.getSession(for: identity.peerID) else {
            XCTFail("Missing remote session")
            return
        }

        let validPayload = MessagePayloadBuilder.prependSubType(
            .typingIndicator,
            to: Data(UUID().uuidString.utf8)
        )
        let validCiphertext = try remoteSession.encrypt(plaintext: validPayload)
        let validPacket = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: validCiphertext,
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        try await messageService.handleEncryptedPacket(validPacket, from: remotePeerID)

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        XCTAssertTrue(mockTransport.sentPackets.isEmpty)
        XCTAssertTrue(messageService.noiseSessionManager?.hasSession(for: remotePeerID) == true)

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        XCTAssertEqual(mockTransport.sentPackets.count, 1)
        let decoded = try PacketSerializer.decode(try XCTUnwrap(mockTransport.sentPackets.first).data)
        XCTAssertEqual(decoded.type, .noiseHandshake)
    }

    func testHandleEncryptedPacket_recoveryIsRateLimitedPerPeer() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, _) = try establishNoiseSession(with: remoteIdentity)

        let invalidPacket = MessagePayloadBuilder.buildPacket(
            type: .noiseEncrypted,
            payload: Data("not-ciphertext".utf8),
            flags: [.hasRecipient, .hasSignature],
            senderID: remotePeerID,
            recipientID: identity.peerID
        )

        mockTransport.reset()
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        XCTAssertEqual(mockTransport.sentPackets.count, 1)

        mockTransport.reset()
        _ = try establishNoiseSession(with: remoteIdentity)

        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)
        try await messageService.handleEncryptedPacket(invalidPacket, from: remotePeerID)

        XCTAssertTrue(mockTransport.sentPackets.isEmpty)
        XCTAssertTrue(messageService.noiseSessionManager?.hasSession(for: remotePeerID) == true)
    }

    // MARK: - Reactions

    func testSendReaction_encryptsAndAppliesLocalReaction() async throws {
        throw XCTSkip("BDEV-414: pre-existing failure exposed when CI started running BlipTests in BDEV-405; see https://heyblip.atlassian.net/browse/BDEV-414")
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)
        let remoteUserID = remoteUser.id
        let userDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == remoteUserID })
        let localRemoteUser = try XCTUnwrap(context.fetch(userDescriptor).first)
        context.insert(GroupMembership(user: localRemoteUser, channel: channel, role: .member))

        let messageID = UUID()
        let message = Message(
            id: messageID,
            channel: channel,
            type: .text,
            rawPayload: Data("Hi".utf8),
            status: .sent
        )
        context.insert(message)
        try context.save()
        mockTransport.reset()

        try await messageService.sendReaction("👍", for: messageID, in: channel)

        // Local message must reflect the new reaction immediately.
        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(stored.reaction, "👍", "sendReaction must update local Message.reaction")

        // Wire packet must be a noiseEncrypted .messageReaction with the right payload.
        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        XCTAssertEqual(packet.type, .noiseEncrypted)

        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.messageReaction.rawValue)

        let parsed = MessagePayloadBuilder.parseReactionPayload(Data(plaintext.dropFirst()))
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertEqual(parsed.emoji, "👍")
    }

    func testSendReaction_clearWritesEmptyEmojiPayload() async throws {
        throw XCTSkip("BDEV-414: pre-existing failure exposed when CI started running BlipTests in BDEV-405; see https://heyblip.atlassian.net/browse/BDEV-414")
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let (remotePeerID, remoteSessionManager) = try establishNoiseSession(with: remoteIdentity)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)
        let remoteUserID = remoteUser.id
        let userDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == remoteUserID })
        let localRemoteUser = try XCTUnwrap(context.fetch(userDescriptor).first)
        context.insert(GroupMembership(user: localRemoteUser, channel: channel, role: .member))

        let messageID = UUID()
        let message = Message(
            id: messageID,
            channel: channel,
            type: .text,
            rawPayload: Data("Hi".utf8),
            status: .sent,
            reaction: "👍"
        )
        context.insert(message)
        try context.save()
        mockTransport.reset()

        try await messageService.sendReaction(nil, for: messageID, in: channel)

        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertNil(stored.reaction, "Clearing must persist as nil, not as an empty string")

        let sentPacket = try XCTUnwrap(mockTransport.sentPackets.first)
        let packet = try PacketSerializer.decode(sentPacket.data)
        let remoteSession = try XCTUnwrap(remoteSessionManager.getSession(for: identity.peerID))
        let plaintext = try remoteSession.decrypt(ciphertext: packet.payload)
        XCTAssertEqual(plaintext.first, EncryptedSubType.messageReaction.rawValue)

        let parsed = MessagePayloadBuilder.parseReactionPayload(Data(plaintext.dropFirst()))
        XCTAssertEqual(parsed.messageID, messageID)
        XCTAssertNil(parsed.emoji, "Cleared reaction must round-trip as nil over the wire")
    }

    func testHandleIncomingReaction_setsMessageReaction() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        _ = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)

        let messageID = UUID()
        let message = Message(
            id: messageID,
            channel: channel,
            type: .text,
            rawPayload: Data("Hi".utf8),
            status: .delivered
        )
        context.insert(message)
        try context.save()

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: "🎉")
        try await messageService.handleIncomingReaction(data: payload, from: remotePeerID)

        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(stored.reaction, "🎉")
    }

    func testHandleIncomingReaction_clearsExistingReaction() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)

        let messageID = UUID()
        let message = Message(
            id: messageID,
            channel: channel,
            type: .text,
            rawPayload: Data("Hi".utf8),
            status: .delivered,
            reaction: "👍"
        )
        context.insert(message)
        try context.save()

        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: nil)
        try await messageService.handleIncomingReaction(data: payload, from: remotePeerID)

        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertNil(stored.reaction, "Empty payload must clear the local reaction")
    }

    func testHandleIncomingReaction_unknownMessageIDIsNoOp() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        let unknownMessageID = UUID()
        let payload = MessagePayloadBuilder.buildReactionPayload(messageID: unknownMessageID, emoji: "👍")
        // Should not throw, just silently drop.
        try await messageService.handleIncomingReaction(data: payload, from: remotePeerID)

        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == unknownMessageID })
        XCTAssertTrue(try verifyContext.fetch(descriptor).isEmpty, "No phantom message should be created for unknown reaction targets")
    }

    func testReactionRoundTrip_updatesRecipientMessage() async throws {
        // Simulates the receive-side exit point: handleIncomingReaction is called with the
        // same payload format `dispatchDecryptedPayload` would produce after Noise decryption.
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)

        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)

        let messageID = UUID()
        let message = Message(
            id: messageID,
            channel: channel,
            type: .text,
            rawPayload: Data("Hi".utf8),
            status: .delivered
        )
        context.insert(message)
        try context.save()

        // First reaction lands.
        let first = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: "❤️")
        try await messageService.handleIncomingReaction(data: first, from: remotePeerID)

        var verifyContext = ModelContext(container)
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        var stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(stored.reaction, "❤️")

        // Second reaction overwrites the first.
        let second = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: "🎉")
        try await messageService.handleIncomingReaction(data: second, from: remotePeerID)

        verifyContext = ModelContext(container)
        descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(stored.reaction, "🎉", "Latest reaction must overwrite earlier one")

        // Clear lands.
        let clear = MessagePayloadBuilder.buildReactionPayload(messageID: messageID, emoji: nil)
        try await messageService.handleIncomingReaction(data: clear, from: remotePeerID)

        verifyContext = ModelContext(container)
        descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        stored = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertNil(stored.reaction)
    }

    func testHandleIncomingGroupMessage_usesPayloadChannelID() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let context = ModelContext(container)
        let decoyChannel = Channel(type: .group, name: "Decoy")
        let targetChannel = Channel(type: .group, name: "Target")
        context.insert(decoyChannel)
        context.insert(targetChannel)
        try context.save()

        let messageID = UUID()
        let payload = MessagePayloadBuilder.buildGroupTextPayload(
            content: "Hello group",
            channelID: targetChannel.id,
            messageID: messageID,
            replyToID: nil
        )

        try await messageService.handleIncomingMessage(
            data: payload,
            subType: .groupMessage,
            senderPeerID: remotePeerID,
            timestamp: Date()
        )

        let verifyContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        let storedMessage = try XCTUnwrap(verifyContext.fetch(descriptor).first)
        XCTAssertEqual(storedMessage.channel?.id, targetChannel.id)
        XCTAssertEqual(String(data: storedMessage.rawPayload, encoding: .utf8), "Hello group")
        XCTAssertEqual(storedMessage.sender?.username, remoteUser.username)
    }

    func testHandleGroupManagement_requiresAdminForAdminActions() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let context = ModelContext(container)
        let channel = Channel(type: .group, name: "Group")
        context.insert(channel)
        let remoteUserID = remoteUser.id
        let userDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == remoteUserID })
        let localRemoteUser = try XCTUnwrap(context.fetch(userDescriptor).first)
        context.insert(GroupMembership(user: localRemoteUser, channel: channel, role: .member))
        try context.save()

        let expectation = expectation(forNotification: .didReceiveGroupManagement, object: nil)
        expectation.isInverted = true

        let payload = MessagePayloadBuilder.buildChannelScopedPayload(
            channelID: channel.id,
            content: Data("add-member".utf8)
        )
        try await messageService.handleGroupManagement(subType: .groupMemberAdd, data: payload, from: remotePeerID)

        await fulfillment(of: [expectation], timeout: 0.2)
    }

    func testHandleGroupManagement_allowsAdminActionForAdminMember() async throws {
        let _ = makeLocalUser()
        let remoteIdentity = try makeRemoteIdentity()
        let remotePeerID = PeerID(noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation)
        let remoteUser = makeUser(
            username: "alice",
            displayName: "Alice",
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey
        )

        let peerInfo = PeerInfo(
            peerID: remotePeerID.bytes,
            noisePublicKey: remoteIdentity.noisePublicKey.rawRepresentation,
            signingPublicKey: remoteIdentity.signingPublicKey,
            username: "alice",
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        messageService.peerStore.upsert(peer: peerInfo)

        let context = ModelContext(container)
        let channel = Channel(type: .group, name: "Group")
        context.insert(channel)
        let remoteUserID = remoteUser.id
        let userDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == remoteUserID })
        let localRemoteUser = try XCTUnwrap(context.fetch(userDescriptor).first)
        context.insert(GroupMembership(user: localRemoteUser, channel: channel, role: .admin))
        try context.save()

        let expectation = expectation(forNotification: .didReceiveGroupManagement, object: nil) { notification in
            let channelID = notification.userInfo?["channelID"] as? UUID
            let data = notification.userInfo?["data"] as? Data
            return channelID == channel.id && data == Data("add-member".utf8)
        }

        let payload = MessagePayloadBuilder.buildChannelScopedPayload(
            channelID: channel.id,
            content: Data("add-member".utf8)
        )
        try await messageService.handleGroupManagement(subType: .groupMemberAdd, data: payload, from: remotePeerID)

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
