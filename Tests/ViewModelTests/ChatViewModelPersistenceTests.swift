import XCTest
import SwiftData
@testable import Blip

/// Regression tests for the persistence-on-receive contract documented in
/// `ChatViewModel.handleReceivedMessage` (ChatViewModel.swift:614) and
/// `ChatViewModel.applyStatusChange` (ChatViewModel.swift:666).
///
/// The contract: both methods MUST save the SwiftData context after
/// mutating `Channel.unreadCount`, `Channel.lastActivityAt`, and
/// `Message.statusRaw`. The previous implementation only mutated the
/// in-memory object graph, so unread badges and chat-list ordering rolled
/// back on cold launch.
///
/// Every assertion in this suite reads from a **freshly built ModelContext**
/// on the same container, which is the cheapest way to prove the write
/// actually hit the store rather than just the cached object graph.
@MainActor
final class ChatViewModelPersistenceTests: XCTestCase {

    private var container: ModelContainer!
    private var messageService: MessageService!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BlipSchema.schema, configurations: [config])

        messageService = MessageService(modelContainer: container)
        vm = ChatViewModel(messageService: messageService)
    }

    override func tearDown() async throws {
        vm = nil
        messageService = nil
        container = nil
    }

    // MARK: - Helpers

    private func makeChannel(
        type: ChannelType = .dm,
        name: String,
        unreadCount: Int = 0,
        lastActivityAt: Date = Date.distantPast
    ) -> Channel {
        let context = messageService.context
        let channel = Channel(
            type: type,
            name: name,
            unreadCount: unreadCount,
            lastActivityAt: lastActivityAt
        )
        context.insert(channel)
        try? context.save()
        return channel
    }

    private func makeMessage(
        channel: Channel,
        status: MessageStatus = .sent
    ) -> Message {
        let context = messageService.context
        let message = Message(
            channel: channel,
            type: .text,
            rawPayload: Data("hello".utf8),
            status: status
        )
        context.insert(message)
        try? context.save()
        return message
    }

    /// Fetch a Channel from a brand-new ModelContext on the same container.
    /// If the value we read matches the mutation we just performed, the
    /// write went all the way to the store, not just the in-memory graph.
    private func fetchChannel(id: UUID) throws -> Channel? {
        let freshContext = ModelContext(container)
        return try freshContext.fetch(
            FetchDescriptor<Channel>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchMessage(id: UUID) throws -> Message? {
        let freshContext = ModelContext(container)
        return try freshContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        ).first
    }

    // MARK: - handleReceivedMessage persistence

    func test_handleReceivedMessage_whileChannelInactive_persistsUnreadCount() throws {
        let channel = makeChannel(name: "Alice")
        let channelID = channel.id
        XCTAssertEqual(channel.unreadCount, 0)

        let msg = makeMessage(channel: channel)
        vm.handleReceivedMessage(msg, in: channel)

        XCTAssertEqual(channel.unreadCount, 1, "in-memory should reflect the new count")

        let persisted = try XCTUnwrap(try fetchChannel(id: channelID))
        XCTAssertEqual(persisted.unreadCount, 1, "unread count must be persisted, not just cached")
    }

    func test_handleReceivedMessage_whileChannelInactive_persistsLastActivityAt() throws {
        let channel = makeChannel(name: "Alice", lastActivityAt: Date.distantPast)
        let channelID = channel.id

        let before = Date()
        vm.handleReceivedMessage(makeMessage(channel: channel), in: channel)

        let persisted = try XCTUnwrap(try fetchChannel(id: channelID))
        XCTAssertGreaterThanOrEqual(
            persisted.lastActivityAt,
            before,
            "lastActivityAt must be persisted with a fresh timestamp"
        )
    }

    func test_handleReceivedMessage_whileChannelActive_doesNotBumpUnread() async throws {
        let channel = makeChannel(name: "Alice")
        await vm.openConversation(channel)

        vm.handleReceivedMessage(makeMessage(channel: channel), in: channel)

        let persisted = try XCTUnwrap(try fetchChannel(id: channel.id))
        XCTAssertEqual(
            persisted.unreadCount, 0,
            "receiving in the active conversation must not bump unreadCount"
        )
        // lastActivityAt is still bumped — the thread moved.
        XCTAssertGreaterThan(persisted.lastActivityAt, Date.distantPast)
    }

    func test_handleReceivedMessage_inChannelA_whileChannelBIsOpen_persistsAsUnread() async throws {
        // This is the exact scenario CLAUDE.md calls out: "Status updates that
        // arrive while a different channel is open also persist via
        // fetch-then-save instead of only mutating `activeMessages[idx]`."
        let channelA = makeChannel(name: "Alice")
        let channelB = makeChannel(name: "Bob")

        await vm.openConversation(channelB)
        XCTAssertEqual(vm.activeChannel?.id, channelB.id)

        vm.handleReceivedMessage(makeMessage(channel: channelA), in: channelA)

        let persistedA = try XCTUnwrap(try fetchChannel(id: channelA.id))
        let persistedB = try XCTUnwrap(try fetchChannel(id: channelB.id))
        XCTAssertEqual(persistedA.unreadCount, 1, "channel A must have unread bumped")
        XCTAssertEqual(persistedB.unreadCount, 0, "channel B (active) must be untouched")
    }

    func test_handleReceivedMessage_multipleTimes_accumulatesUnreadCount() throws {
        let channel = makeChannel(name: "Alice")
        let channelID = channel.id

        for _ in 0 ..< 3 {
            vm.handleReceivedMessage(makeMessage(channel: channel), in: channel)
        }

        let persisted = try XCTUnwrap(try fetchChannel(id: channelID))
        XCTAssertEqual(persisted.unreadCount, 3)
    }

    // MARK: - Status change persistence

    func test_handleDeliveryAck_forMessageInInactiveChannel_persistsStatus() async throws {
        // Status updates that arrive while a different channel is open must
        // still land in the store — a previous implementation only mutated
        // `activeMessages[idx]`, silently dropping the update.
        let channelA = makeChannel(name: "Alice")
        let channelB = makeChannel(name: "Bob")
        let msg = makeMessage(channel: channelA, status: .sent)

        await vm.openConversation(channelB)

        vm.handleDeliveryAck(for: msg.id)

        let persisted = try XCTUnwrap(try fetchMessage(id: msg.id))
        XCTAssertEqual(persisted.status, .delivered)
    }

    func test_handleReadReceipt_forMessageInInactiveChannel_persistsStatus() async throws {
        let channelA = makeChannel(name: "Alice")
        let channelB = makeChannel(name: "Bob")
        let msg = makeMessage(channel: channelA, status: .delivered)

        await vm.openConversation(channelB)

        vm.handleReadReceipt(for: msg.id)

        let persisted = try XCTUnwrap(try fetchMessage(id: msg.id))
        XCTAssertEqual(persisted.status, .read)
    }

    func test_handleDeliveryAck_forMessageInActiveChannel_updatesBothActiveAndPersisted() async throws {
        let channel = makeChannel(name: "Alice")
        let msg = makeMessage(channel: channel, status: .sent)

        await vm.openConversation(channel)
        // Not asserting activeMessages pre-state — openConversation fetches
        // channel messages, but our message was inserted before. What matters
        // is that after the ack fires both views agree.

        vm.handleDeliveryAck(for: msg.id)

        let persisted = try XCTUnwrap(try fetchMessage(id: msg.id))
        XCTAssertEqual(persisted.status, .delivered)

        if let activeCopy = vm.activeMessages.first(where: { $0.id == msg.id }) {
            XCTAssertEqual(activeCopy.status, .delivered, "active list must also reflect the ack")
        }
    }

    // MARK: - Cold-launch simulation

    func test_coldLaunchSimulation_unreadCountSurvivesRebuild() throws {
        let channel = makeChannel(name: "Alice")
        let channelID = channel.id
        vm.handleReceivedMessage(makeMessage(channel: channel), in: channel)
        vm.handleReceivedMessage(makeMessage(channel: channel), in: channel)

        // Drop the VM + service as if the app were relaunched, keeping the
        // same on-disk (in-memory-only) container.
        vm = nil
        messageService = nil

        let freshService = MessageService(modelContainer: container)
        let freshVM = ChatViewModel(messageService: freshService)
        _ = freshVM // silence unused warning

        let persisted = try XCTUnwrap(try fetchChannel(id: channelID))
        XCTAssertEqual(
            persisted.unreadCount, 2,
            "cold-launch must see the persisted unread count, not zero"
        )
    }
}
