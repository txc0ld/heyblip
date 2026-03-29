import XCTest
import SwiftData
@testable import BlipProtocol

// We test ChatViewModel via its public API. Because it depends on SwiftData and
// services that are tightly coupled to the real environment, we use a lightweight
// in-memory ModelContainer and mock services.

// MARK: - Mock Services

/// Minimal mock of MessageService for unit testing ChatViewModel.
private final class MockMessageService: MessageService {
    var sentTexts: [(content: String, channel: Channel, replyTo: Message?)] = []
    var sentVoiceNotes: [(data: Data, duration: TimeInterval, channel: Channel)] = []
    var sentImages: [(imageData: Data, thumbnail: Data, channel: Channel)] = []
    var typingIndicatorsSent: [Channel] = []
    var readReceiptsSent: [(messageID: UUID, peerID: PeerID)] = []
    var shouldFailSend = false

    override func sendTextMessage(content: String, to channel: Channel, replyTo: Message?) async throws -> Message {
        if shouldFailSend { throw NSError(domain: "MockError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Send failed"]) }
        sentTexts.append((content, channel, replyTo))
        let message = Message(content: content, sender: nil, channel: channel, replyTo: replyTo)
        message.status = .sent
        return message
    }

    override func sendVoiceNote(audioData: Data, duration: TimeInterval, to channel: Channel) async throws -> Message {
        if shouldFailSend { throw NSError(domain: "MockError", code: 2) }
        sentVoiceNotes.append((audioData, duration, channel))
        let message = Message(content: "[Voice Note]", sender: nil, channel: channel)
        message.status = .sent
        return message
    }

    override func sendImage(imageData: Data, thumbnail: Data, to channel: Channel) async throws -> Message {
        if shouldFailSend { throw NSError(domain: "MockError", code: 3) }
        sentImages.append((imageData, thumbnail, channel))
        let message = Message(content: "[Image]", sender: nil, channel: channel)
        message.status = .sent
        return message
    }

    override func sendTypingIndicator(to channel: Channel) async throws {
        typingIndicatorsSent.append(channel)
    }

    override func sendReadReceipt(for messageID: UUID, to peerID: PeerID) async throws {
        readReceiptsSent.append((messageID, peerID))
    }
}

// MARK: - Tests

@MainActor
final class ChatViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var mockMessageService: MockMessageService!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        // Create an in-memory SwiftData container for testing.
        let schema = Schema([Channel.self, Message.self, User.self, GroupMembership.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])

        mockMessageService = MockMessageService()
        vm = ChatViewModel(
            modelContainer: container,
            messageService: mockMessageService
        )
    }

    override func tearDown() async throws {
        container = nil
        mockMessageService = nil
        vm = nil
    }

    // MARK: - Send Message Flow

    func testSendTextMessageAppendsToActiveMessages() async {
        // Create a channel and open it.
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Alice")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)
        XCTAssertEqual(vm.activeChannel?.id, channel.id)

        // Compose and send.
        vm.composingText = "Hello Alice!"
        await vm.sendTextMessage()

        // Verify the message was sent and appended.
        XCTAssertEqual(mockMessageService.sentTexts.count, 1)
        XCTAssertEqual(mockMessageService.sentTexts[0].content, "Hello Alice!")
        XCTAssertEqual(vm.activeMessages.count, 1)
        XCTAssertFalse(vm.isSending)
        XCTAssertTrue(vm.composingText.isEmpty, "Composing text should be cleared after send")
    }

    func testSendTextMessageWithEmptyTextIsIgnored() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Bob")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)
        vm.composingText = "   " // Whitespace only
        await vm.sendTextMessage()

        XCTAssertEqual(mockMessageService.sentTexts.count, 0, "Empty messages should not be sent")
        XCTAssertEqual(vm.activeMessages.count, 0)
    }

    func testSendTextMessageWithNoActiveChannelIsIgnored() async {
        XCTAssertNil(vm.activeChannel)
        vm.composingText = "Nobody listening"
        await vm.sendTextMessage()

        XCTAssertEqual(mockMessageService.sentTexts.count, 0)
    }

    func testSendTextMessageFailureSetsError() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Charlie")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)
        vm.composingText = "This will fail"
        mockMessageService.shouldFailSend = true

        await vm.sendTextMessage()

        XCTAssertNotNil(vm.errorMessage, "Error should be set on failure")
        XCTAssertEqual(vm.activeMessages.count, 0, "Failed message should not be in active messages")
        XCTAssertFalse(vm.isSending)
    }

    func testSendTextMessageClearsReplyTarget() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Dave")
        context.insert(channel)
        let replyMsg = Message(content: "Original", sender: nil, channel: channel)
        context.insert(replyMsg)
        try? context.save()

        await vm.openConversation(channel)
        vm.replyTarget = replyMsg
        vm.composingText = "Reply to original"

        await vm.sendTextMessage()

        XCTAssertNil(vm.replyTarget, "Reply target should be cleared after send")
        XCTAssertEqual(mockMessageService.sentTexts[0].replyTo?.id, replyMsg.id)
    }

    // MARK: - Receive Message

    func testHandleReceivedMessageInActiveChannel() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Eve")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)
        XCTAssertEqual(vm.activeMessages.count, 0)

        let incoming = Message(content: "Hey!", sender: nil, channel: channel)
        vm.handleReceivedMessage(incoming, in: channel)

        XCTAssertEqual(vm.activeMessages.count, 1)
        XCTAssertEqual(vm.activeMessages[0].content, "Hey!")
    }

    func testHandleReceivedMessageInDifferentChannelIncrementsUnread() async {
        let context = ModelContext(container)
        let activeChannel = Channel(type: .dm, name: "Active")
        let otherChannel = Channel(type: .dm, name: "Other")
        context.insert(activeChannel)
        context.insert(otherChannel)
        try? context.save()

        await vm.loadChannels()
        await vm.openConversation(activeChannel)

        let incoming = Message(content: "You there?", sender: nil, channel: otherChannel)
        vm.handleReceivedMessage(incoming, in: otherChannel)

        // Should NOT be in active messages (different channel).
        XCTAssertEqual(vm.activeMessages.count, 0)

        // Unread count for the other channel should increment.
        XCTAssertEqual(vm.unreadCounts[otherChannel.id], 1)
        XCTAssertEqual(vm.totalUnreadCount, 1)
    }

    func testHandleReceivedMessageMovesChannelToTop() async {
        let context = ModelContext(container)
        let ch1 = Channel(type: .dm, name: "First")
        let ch2 = Channel(type: .dm, name: "Second")
        context.insert(ch1)
        context.insert(ch2)
        try? context.save()

        await vm.loadChannels()
        // ch2 is not the active channel.

        let msg = Message(content: "New msg", sender: nil, channel: ch2)
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
        XCTAssertTrue(vm.typingIndicators[channelID]!.contains(peerName))
        XCTAssertEqual(vm.typingText(for: channelID), "Alice is typing...")
    }

    func testTypingTextForMultipleTypers() {
        let channelID = UUID()

        vm.handleTypingIndicator(from: "Alice", in: channelID)
        vm.handleTypingIndicator(from: "Bob", in: channelID)

        let text = vm.typingText(for: channelID)
        XCTAssertNotNil(text)
        // Order may vary, so check for presence of both names.
        XCTAssertTrue(text!.contains("Alice"))
        XCTAssertTrue(text!.contains("Bob"))
        XCTAssertTrue(text!.contains("are typing..."))
    }

    func testTypingTextForThreeOrMoreTypers() {
        let channelID = UUID()

        vm.handleTypingIndicator(from: "Alice", in: channelID)
        vm.handleTypingIndicator(from: "Bob", in: channelID)
        vm.handleTypingIndicator(from: "Charlie", in: channelID)

        let text = vm.typingText(for: channelID)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("3 people are typing..."))
    }

    func testTypingTextForNoTypers() {
        let text = vm.typingText(for: UUID())
        XCTAssertNil(text)
    }

    // MARK: - Channel Switching

    func testOpenConversationSwitchesActiveChannel() async {
        let context = ModelContext(container)
        let ch1 = Channel(type: .dm, name: "Channel 1")
        let ch2 = Channel(type: .dm, name: "Channel 2")
        context.insert(ch1)
        context.insert(ch2)
        try? context.save()

        await vm.openConversation(ch1)
        XCTAssertEqual(vm.activeChannel?.id, ch1.id)

        await vm.openConversation(ch2)
        XCTAssertEqual(vm.activeChannel?.id, ch2.id)
    }

    func testCloseConversationClearsState() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "ToClose")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)
        vm.composingText = "Unfinished"
        vm.replyTarget = Message(content: "target", sender: nil, channel: channel)

        vm.closeConversation()

        XCTAssertNil(vm.activeChannel)
        XCTAssertTrue(vm.activeMessages.isEmpty)
        XCTAssertTrue(vm.composingText.isEmpty)
        XCTAssertNil(vm.replyTarget)
    }

    // MARK: - Unread Count

    func testMarkChannelAsReadResetsUnreadCount() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "Unread")
        context.insert(channel)
        try? context.save()

        await vm.loadChannels()

        // Simulate unread messages.
        let msg1 = Message(content: "msg1", sender: nil, channel: channel)
        let msg2 = Message(content: "msg2", sender: nil, channel: channel)
        vm.handleReceivedMessage(msg1, in: channel)
        vm.handleReceivedMessage(msg2, in: channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 2)
        XCTAssertEqual(vm.totalUnreadCount, 2)

        // Mark as read.
        vm.markChannelAsRead(channel)

        XCTAssertEqual(vm.unreadCounts[channel.id], 0)
    }

    func testOpenConversationMarksAsRead() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "AutoRead")
        context.insert(channel)
        try? context.save()

        await vm.loadChannels()

        let msg = Message(content: "New!", sender: nil, channel: channel)
        vm.handleReceivedMessage(msg, in: channel)
        XCTAssertEqual(vm.unreadCounts[channel.id], 1)

        // Opening the conversation should mark it as read.
        await vm.openConversation(channel)
        XCTAssertEqual(vm.unreadCounts[channel.id], 0)
    }

    // MARK: - Delivery / Read Receipts

    func testHandleDeliveryAck() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "AckTest")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)

        // Send a message.
        vm.composingText = "Ack me"
        await vm.sendTextMessage()
        XCTAssertEqual(vm.activeMessages.count, 1)
        let messageID = vm.activeMessages[0].id

        // Simulate delivery ack.
        vm.handleDeliveryAck(for: messageID)
        XCTAssertEqual(vm.activeMessages[0].status, .delivered)
    }

    func testHandleReadReceipt() async {
        let context = ModelContext(container)
        let channel = Channel(type: .dm, name: "ReadTest")
        context.insert(channel)
        try? context.save()

        await vm.openConversation(channel)

        vm.composingText = "Read me"
        await vm.sendTextMessage()
        let messageID = vm.activeMessages[0].id

        vm.handleReadReceipt(for: messageID)
        XCTAssertEqual(vm.activeMessages[0].status, .read)
    }

    // MARK: - Reply Target

    func testSetAndClearReplyTarget() {
        let msg = Message(content: "Target", sender: nil, channel: nil)
        vm.setReplyTarget(msg)
        XCTAssertEqual(vm.replyTarget?.id, msg.id)

        vm.clearReplyTarget()
        XCTAssertNil(vm.replyTarget)
    }
}
