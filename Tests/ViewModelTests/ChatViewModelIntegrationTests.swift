import XCTest
import SwiftData
@testable import Blip

// MARK: - ChatViewModelIntegrationTests

/// Integration tests for ChatViewModel: channel loading, message management,
/// unread count tracking, and mark-as-read flows.
///
/// Uses a real MessageService backed by an in-memory ModelContainer.
/// Exercises the ViewModel's data flow without real transport or encryption.
@MainActor
final class ChatViewModelIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var messageService: MessageService!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        messageService = MessageService(modelContainer: container)
        vm = ChatViewModel(
            messageService: messageService
        )
    }

    override func tearDown() async throws {
        container = nil
        messageService = nil
        vm = nil
    }

    // MARK: - Helpers

    private func makeChannel(
        type: ChannelType = .dm,
        name: String,
        lastActivityAt: Date = Date()
    ) -> Channel {
        let context = ModelContext(container)
        let channel = Channel(type: type, name: name, lastActivityAt: lastActivityAt)
        context.insert(channel)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save channel: \(error)")
        }
        return channel
    }

    private func makeUser(username: String, displayName: String? = nil) -> User {
        let context = ModelContext(container)
        let user = User(
            username: username,
            displayName: displayName ?? username,
            emailHash: "\(username)-hash",
            noisePublicKey: Data(username.utf8),
            signingPublicKey: Data("\(username)-signing".utf8)
        )
        context.insert(user)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save user: \(error)")
        }
        return user
    }

    private func makeDMChannel(
        with user: User,
        name: String,
        lastActivityAt: Date = Date()
    ) -> Channel {
        let context = ModelContext(container)
        let userID = user.id
        let descriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == userID })
        let persistedUser: User
        do {
            guard let fetchedUser = try context.fetch(descriptor).first else {
                XCTFail("Failed to fetch persisted user for DM channel")
                return Channel(type: .dm, name: name, lastActivityAt: lastActivityAt)
            }
            persistedUser = fetchedUser
        } catch {
            XCTFail("Failed to fetch persisted user for DM channel: \(error)")
            return Channel(type: .dm, name: name, lastActivityAt: lastActivityAt)
        }

        let channel = Channel(type: .dm, name: name, lastActivityAt: lastActivityAt)
        let membership = GroupMembership(user: persistedUser, channel: channel, role: .member)
        context.insert(channel)
        context.insert(membership)

        do {
            try context.save()
        } catch {
            XCTFail("Failed to save DM channel: \(error)")
        }

        return channel
    }

    private func makeMessage(
        channel: Channel,
        type: MessageType = .text,
        content: String = "test",
        status: MessageStatus = .delivered,
        createdAt: Date = Date()
    ) -> Message {
        let context = ModelContext(container)
        let message = Message(
            channel: channel,
            type: type,
            rawPayload: content.data(using: .utf8) ?? Data(),
            status: status,
            createdAt: createdAt
        )
        context.insert(message)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save message: \(error)")
        }
        return message
    }

    // MARK: - Load Channels

    func testLoadChannels_populatesChannelList() async {
        let now = Date()
        let _ = makeChannel(name: "Alpha", lastActivityAt: now.addingTimeInterval(-300))
        let _ = makeChannel(name: "Beta", lastActivityAt: now.addingTimeInterval(-100))
        let _ = makeChannel(name: "Gamma", lastActivityAt: now)

        await vm.loadChannels()

        XCTAssertEqual(vm.channels.count, 3, "All 3 channels should be loaded")
        XCTAssertFalse(vm.isLoading, "Loading flag should be cleared")
    }

    func testLoadChannels_sortedByLastActivityDescending() async {
        let now = Date()
        let _ = makeChannel(name: "Old", lastActivityAt: now.addingTimeInterval(-3600))
        let _ = makeChannel(name: "Recent", lastActivityAt: now)
        let _ = makeChannel(name: "Middle", lastActivityAt: now.addingTimeInterval(-600))

        await vm.loadChannels()

        XCTAssertEqual(vm.channels.count, 3)
        XCTAssertEqual(vm.channels[0].name, "Recent", "Most recent channel should be first")
        XCTAssertEqual(vm.channels[1].name, "Middle", "Middle channel should be second")
        XCTAssertEqual(vm.channels[2].name, "Old", "Oldest channel should be last")
    }

    func testLoadChannels_emptyDatabase_returnsEmpty() async {
        await vm.loadChannels()

        XCTAssertEqual(vm.channels.count, 0)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Send Message

    func testSendMessage_appendsToActiveMessages() async {
        let channel = makeChannel(name: "TestChannel")
        await vm.openConversation(channel)

        // Manually add a message to activeMessages (simulating a received message)
        let msg = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("Hello".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg, in: channel)

        XCTAssertEqual(vm.activeMessages.count, 1, "Active messages should grow by 1")
    }

    func testSendTextMessage_failsWithoutIdentity() async {
        let channel = makeChannel(name: "NoIdentity")
        await vm.openConversation(channel)

        vm.composingText = "This will fail"
        await vm.sendTextMessage()

        // Without identity, message send should fail and set an error
        XCTAssertNotNil(vm.errorMessage, "Error should be set when no identity is configured")
        XCTAssertEqual(vm.activeMessages.count, 0, "No message should be added on failure")
    }

    // MARK: - Unread Count

    func testUnreadCount_updatesOnNewMessage() async {
        let activeChannel = makeChannel(name: "Active")
        let otherChannel = makeChannel(name: "Other")

        await vm.loadChannels()
        await vm.openConversation(activeChannel)

        // Simulate receiving a message in the non-active channel
        let incoming = Message(
            channel: otherChannel,
            type: .text,
            rawPayload: Data("New message".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming, in: otherChannel)

        XCTAssertEqual(vm.unreadCounts[otherChannel.id], 1, "Unread count should increment for inactive channel")
        XCTAssertEqual(vm.totalUnreadCount, 1, "Total unread should be 1")

        // Second message to same channel
        let incoming2 = Message(
            channel: otherChannel,
            type: .text,
            rawPayload: Data("Another message".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming2, in: otherChannel)

        XCTAssertEqual(vm.unreadCounts[otherChannel.id], 2, "Unread count should be 2")
        XCTAssertEqual(vm.totalUnreadCount, 2, "Total unread should be 2")
    }

    func testUnreadCount_doesNotIncrementForActiveChannel() async {
        let channel = makeChannel(name: "Active")

        await vm.loadChannels()
        await vm.openConversation(channel)

        let incoming = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("Seen immediately".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming, in: channel)

        // Message in active channel should not increment unread count
        XCTAssertEqual(vm.unreadCounts[channel.id] ?? 0, 0, "Active channel should have 0 unread")
        XCTAssertEqual(vm.totalUnreadCount, 0, "Total unread should be 0")
    }

    // MARK: - Mark As Read

    func testMarkAsRead_clearsUnreadCount() async {
        let channel = makeChannel(name: "UnreadTest")

        await vm.loadChannels()

        // Add unread messages
        let msg1 = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("msg1".utf8),
            status: .delivered
        )
        let msg2 = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("msg2".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg1, in: channel)
        vm.handleReceivedMessage(msg2, in: channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 2, "Should have 2 unread messages")
        XCTAssertEqual(vm.totalUnreadCount, 2)

        // Mark as read
        vm.markChannelAsRead(channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 0, "Unread count should be 0 after marking as read")
        XCTAssertEqual(vm.totalUnreadCount, 0, "Total unread should be 0 after marking as read")
    }

    func testOpenConversation_marksChannelAsRead() async {
        let channel = makeChannel(name: "AutoRead")

        await vm.loadChannels()

        // Add an unread message
        let msg = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("Unread".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg, in: channel)
        XCTAssertEqual(vm.unreadCounts[channel.id], 1)

        // Opening conversation should clear unreads
        await vm.openConversation(channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 0, "Opening conversation should mark as read")
    }

    // MARK: - Channel Activity Ordering

    func testReceivedMessage_movesChannelToTop() async {
        let now = Date()
        let _ = makeChannel(name: "First", lastActivityAt: now)
        let ch2 = makeChannel(name: "Second", lastActivityAt: now.addingTimeInterval(-600))

        await vm.loadChannels()
        XCTAssertEqual(vm.channels.first?.name, "First", "First channel should be on top initially")

        // Receiving a message in Second should bump it to the top
        let msg = Message(
            channel: ch2,
            type: .text,
            rawPayload: Data("New!".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg, in: ch2)

        XCTAssertEqual(vm.channels.first?.id, ch2.id, "Channel with new message should be first")
    }

    func testOpenConversation_loadsMessagesAcrossDuplicateDMChannels() async {
        let remoteUser = makeUser(username: "tay", displayName: "Tay")
        let now = Date()
        let olderChannel = makeDMChannel(
            with: remoteUser,
            name: "Tay",
            lastActivityAt: now.addingTimeInterval(-60)
        )
        let newerChannel = makeDMChannel(
            with: remoteUser,
            name: "Tay",
            lastActivityAt: now
        )

        let _ = makeMessage(
            channel: olderChannel,
            content: "older",
            createdAt: now.addingTimeInterval(-30)
        )
        let _ = makeMessage(
            channel: newerChannel,
            content: "newer",
            createdAt: now.addingTimeInterval(-10)
        )

        await vm.loadChannels()
        guard let loadedOlderChannel = vm.channels.first(where: { $0.id == olderChannel.id }) else {
            XCTFail("Failed to load older channel")
            return
        }

        await vm.openConversation(loadedOlderChannel)

        XCTAssertEqual(vm.activeChannel?.id, newerChannel.id, "Newest duplicate DM channel should become active")
        XCTAssertEqual(vm.activeMessages.count, 2, "Messages from duplicate DM channels should load together")
        XCTAssertEqual(
            vm.activeMessages.compactMap { String(data: $0.rawPayload, encoding: .utf8) },
            ["older", "newer"]
        )
    }

    func testHandleReceivedMessage_inDuplicateDMChannelStaysInOpenConversation() async {
        let remoteUser = makeUser(username: "tay", displayName: "Tay")
        let primaryChannel = makeDMChannel(with: remoteUser, name: "Tay")
        let duplicateChannel = makeDMChannel(with: remoteUser, name: "Tay")

        await vm.loadChannels()
        guard let loadedPrimaryChannel = vm.channels.first(where: { $0.id == primaryChannel.id }) else {
            XCTFail("Failed to load primary channel")
            return
        }
        guard let loadedDuplicateChannel = vm.channels.first(where: { $0.id == duplicateChannel.id }) else {
            XCTFail("Failed to load duplicate channel")
            return
        }

        await vm.openConversation(loadedPrimaryChannel)

        let incoming = Message(
            channel: loadedDuplicateChannel,
            type: .text,
            rawPayload: Data("relay message".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming, in: loadedDuplicateChannel)

        XCTAssertEqual(vm.activeMessages.count, 1, "Duplicate DM channel message should stay visible in the open conversation")
        XCTAssertEqual(vm.unreadCounts[loadedDuplicateChannel.id] ?? 0, 0, "Equivalent DM channel should not accumulate unread while open")
        XCTAssertEqual(vm.totalUnreadCount, 0)
    }

    func testOpenConversationReloadsSentMessagesWrittenThroughMessageServiceContext() async throws {
        let channel = makeChannel(name: "Relay DM")

        await vm.openConversation(channel)
        XCTAssertTrue(vm.activeMessages.isEmpty)

        vm.closeConversation()

        let context = messageService.context
        let channelID = channel.id
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let persistedChannel = try context.fetch(descriptor).first else {
            return XCTFail("Failed to fetch persisted channel from MessageService context")
        }

        let sentMessage = Message(
            channel: persistedChannel,
            type: .text,
            rawPayload: Data("persisted sent message".utf8),
            status: .sent
        )
        context.insert(sentMessage)
        try context.save()

        await vm.openConversation(channel)

        XCTAssertEqual(vm.activeMessages.map(\.id), [sentMessage.id])
        XCTAssertEqual(vm.activeMessages.first?.status, .sent)
    }
}
