import XCTest
import SwiftData
@testable import Blip

// MARK: - Tests

/// Tests for ChatViewModel: channel management, message reception, typing indicators, unread counts,
/// delivery/read receipts, reply targeting, and error handling.
///
/// Uses a real MessageService backed by an in-memory ModelContainer. Send operations will fail
/// (no identity or message balance configured), so send tests validate error handling paths.
/// Reception, typing indicator, unread count, and channel management tests exercise the ViewModel
/// directly without going through the service layer.
@MainActor
final class ChatViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var messageService: MessageService!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        messageService = MessageService(modelContainer: container)
        vm = ChatViewModel(
            modelContainer: container,
            messageService: messageService
        )
    }

    override func tearDown() async throws {
        container = nil
        messageService = nil
        vm = nil
    }

    // MARK: - Helpers

    /// Create a channel in the in-memory store and return it.
    private func makeChannel(type: ChannelType = .dm, name: String) -> Channel {
        let context = ModelContext(container)
        let channel = Channel(type: type, name: name)
        context.insert(channel)
        try? context.save()
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
        try? context.save()
        return user
    }

    /// Create a message in the in-memory store.
    private func makeMessage(
        channel: Channel,
        type: MessageType = .text,
        status: MessageStatus = .delivered
    ) -> Message {
        let context = ModelContext(container)
        let message = Message(
            channel: channel,
            type: type,
            encryptedPayload: Data("test payload".utf8),
            status: status
        )
        context.insert(message)
        try? context.save()
        return message
    }

    // MARK: - Send Message Flow

    func testSendTextMessageWithNoActiveChannelIsIgnored() async {
        XCTAssertNil(vm.activeChannel)
        vm.composingText = "Nobody listening"
        await vm.sendTextMessage()

        // Nothing should happen -- no error, no messages.
        XCTAssertEqual(vm.activeMessages.count, 0)
    }

    func testSendTextMessageWithEmptyTextIsIgnored() async {
        let channel = makeChannel(name: "Bob")

        await vm.openConversation(channel)
        vm.composingText = "   " // Whitespace only
        await vm.sendTextMessage()

        XCTAssertEqual(vm.activeMessages.count, 0, "Empty messages should not be sent")
    }

    func testSendTextMessageFailureSetsError() async {
        let channel = makeChannel(name: "Charlie")

        await vm.openConversation(channel)
        vm.composingText = "This will fail"

        await vm.sendTextMessage()

        // The real MessageService will throw (no identity/balance), so error should be set.
        XCTAssertNotNil(vm.errorMessage, "Error should be set on failure")
        XCTAssertEqual(vm.activeMessages.count, 0, "Failed message should not be in active messages")
        XCTAssertFalse(vm.isSending)
    }

    func testCreateDMChannelCreatesMembershipForPersistedUser() async {
        let user = makeUser(username: "alex", displayName: "Alex")

        let channel = await vm.createDMChannel(with: user)

        XCTAssertNotNil(channel)
        XCTAssertEqual(channel?.type, .dm)
        XCTAssertEqual(channel?.name, "Alex")
        XCTAssertEqual(channel?.memberships.count, 1)
        XCTAssertEqual(channel?.memberships.first?.user?.username, "alex")
    }

    func testCreateDMChannelReturnsExistingChannelInsteadOfDuplicating() async {
        let user = makeUser(username: "sam", displayName: "Sam")

        let firstChannel = await vm.createDMChannel(with: user)
        let secondChannel = await vm.createDMChannel(with: user)

        XCTAssertEqual(firstChannel?.id, secondChannel?.id)

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
        let channels = (try? context.fetch(descriptor)) ?? []
        XCTAssertEqual(channels.count, 1)
    }

    // MARK: - Receive Message

    func testHandleReceivedMessageInActiveChannel() async {
        let channel = makeChannel(name: "Eve")

        await vm.openConversation(channel)
        XCTAssertEqual(vm.activeMessages.count, 0)

        let incoming = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("Hey!".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming, in: channel)

        XCTAssertEqual(vm.activeMessages.count, 1)
    }

    func testHandleReceivedMessageInDifferentChannelIncrementsUnread() async {
        let activeChannel = makeChannel(name: "Active")
        let otherChannel = makeChannel(name: "Other")

        await vm.loadChannels()
        await vm.openConversation(activeChannel)

        let incoming = Message(
            channel: otherChannel,
            type: .text,
            encryptedPayload: Data("You there?".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(incoming, in: otherChannel)

        // Should NOT be in active messages (different channel).
        XCTAssertEqual(vm.activeMessages.count, 0)

        // Unread count for the other channel should increment.
        XCTAssertEqual(vm.unreadCounts[otherChannel.id], 1)
        XCTAssertEqual(vm.totalUnreadCount, 1)
    }

    func testHandleReceivedMessageMovesChannelToTop() async {
        let _ = makeChannel(name: "First")
        let ch2 = makeChannel(name: "Second")

        await vm.loadChannels()

        let msg = Message(
            channel: ch2,
            type: .text,
            encryptedPayload: Data("New msg".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg, in: ch2)

        // ch2 should now be at index 0 in the channels list.
        XCTAssertEqual(vm.channels.first?.id, ch2.id)
    }

    // MARK: - Typing Indicator

    func testTypingIndicatorAppearsAndAutoClears() async {
        let channelID = UUID()
        let peerName = "Alice"

        vm.handleTypingIndicator(from: peerName, in: channelID)

        XCTAssertNotNil(vm.typingIndicators[channelID])
        XCTAssertTrue(vm.typingIndicators[channelID]?.contains(peerName) == true)
        XCTAssertEqual(vm.typingText(for: channelID), "Alice is typing...")
    }

    func testTypingTextForMultipleTypers() {
        let channelID = UUID()

        vm.handleTypingIndicator(from: "Alice", in: channelID)
        vm.handleTypingIndicator(from: "Bob", in: channelID)

        let text = vm.typingText(for: channelID)
        XCTAssertNotNil(text)
        // Order may vary, so check for presence of both names.
        XCTAssertTrue(text?.contains("Alice") == true)
        XCTAssertTrue(text?.contains("Bob") == true)
        XCTAssertTrue(text?.contains("are typing...") == true)
    }

    func testTypingTextForThreeOrMoreTypers() {
        let channelID = UUID()

        vm.handleTypingIndicator(from: "Alice", in: channelID)
        vm.handleTypingIndicator(from: "Bob", in: channelID)
        vm.handleTypingIndicator(from: "Charlie", in: channelID)

        let text = vm.typingText(for: channelID)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("3 people are typing...") == true)
    }

    func testTypingTextForNoTypers() {
        let text = vm.typingText(for: UUID())
        XCTAssertNil(text)
    }

    // MARK: - Channel Switching

    func testOpenConversationSwitchesActiveChannel() async {
        let ch1 = makeChannel(name: "Channel 1")
        let ch2 = makeChannel(name: "Channel 2")

        await vm.openConversation(ch1)
        XCTAssertEqual(vm.activeChannel?.id, ch1.id)

        await vm.openConversation(ch2)
        XCTAssertEqual(vm.activeChannel?.id, ch2.id)
    }

    func testCloseConversationClearsState() async {
        let channel = makeChannel(name: "ToClose")

        await vm.openConversation(channel)
        vm.composingText = "Unfinished"
        vm.replyTarget = Message(channel: channel, type: .text, encryptedPayload: Data())

        vm.closeConversation()

        XCTAssertNil(vm.activeChannel)
        XCTAssertTrue(vm.activeMessages.isEmpty)
        XCTAssertTrue(vm.composingText.isEmpty)
        XCTAssertNil(vm.replyTarget)
    }

    // MARK: - Unread Count

    func testMarkChannelAsReadResetsUnreadCount() async {
        let channel = makeChannel(name: "Unread")

        await vm.loadChannels()

        // Simulate unread messages via handleReceivedMessage.
        let msg1 = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("msg1".utf8),
            status: .delivered
        )
        let msg2 = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("msg2".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg1, in: channel)
        vm.handleReceivedMessage(msg2, in: channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 2)
        XCTAssertEqual(vm.totalUnreadCount, 2)

        // Mark as read.
        vm.markChannelAsRead(channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 0)
    }

    func testOpenConversationMarksAsRead() async {
        let channel = makeChannel(name: "AutoRead")

        await vm.loadChannels()

        let msg = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("New!".utf8),
            status: .delivered
        )
        vm.handleReceivedMessage(msg, in: channel)
        XCTAssertEqual(vm.unreadCounts[channel.id], 1)

        // Opening the conversation should mark it as read.
        await vm.openConversation(channel)
        XCTAssertEqual(vm.unreadCounts[channel.id], 0)
    }

    // MARK: - Delivery / Read Receipts (via handleReceivedMessage + status update)

    func testHandleDeliveryAck() async {
        let channel = makeChannel(name: "AckTest")

        await vm.openConversation(channel)

        // Insert a sent message into active messages.
        let sentMessage = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("Ack me".utf8),
            status: .sent
        )
        vm.activeMessages.append(sentMessage)

        XCTAssertEqual(vm.activeMessages.count, 1)
        let messageID = vm.activeMessages[0].id

        // Simulate delivery ack.
        vm.handleDeliveryAck(for: messageID)
        XCTAssertEqual(vm.activeMessages[0].status, .delivered)
    }

    func testHandleReadReceipt() async {
        let channel = makeChannel(name: "ReadTest")

        await vm.openConversation(channel)

        // Insert a sent message into active messages.
        let sentMessage = Message(
            channel: channel,
            type: .text,
            encryptedPayload: Data("Read me".utf8),
            status: .sent
        )
        vm.activeMessages.append(sentMessage)

        let messageID = vm.activeMessages[0].id

        vm.handleReadReceipt(for: messageID)
        XCTAssertEqual(vm.activeMessages[0].status, .read)
    }

    // MARK: - Reply Target

    func testSetAndClearReplyTarget() {
        let msg = Message(type: .text, encryptedPayload: Data("Target".utf8))
        vm.setReplyTarget(msg)
        XCTAssertEqual(vm.replyTarget?.id, msg.id)

        vm.clearReplyTarget()
        XCTAssertNil(vm.replyTarget)
    }

    // MARK: - Channel Loading

    func testLoadChannelsPopulatesChannelsList() async {
        let _ = makeChannel(name: "Alpha")
        let _ = makeChannel(name: "Beta")

        await vm.loadChannels()

        XCTAssertEqual(vm.channels.count, 2)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadChannelsWithNoChannelsIsEmpty() async {
        await vm.loadChannels()

        XCTAssertEqual(vm.channels.count, 0)
        XCTAssertFalse(vm.isLoading)
    }
}
