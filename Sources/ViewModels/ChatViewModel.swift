import Foundation
import SwiftData
import BlipProtocol
import BlipMesh
import os.log

// MARK: - Chat View Model

/// Manages the chat list, active conversations, message send/receive, typing indicators, and unread counts.
///
/// Observes `MessageService` for incoming messages and status updates.
/// Publishes sorted channel lists with unread counts for the UI.
@MainActor
@Observable
final class ChatViewModel {

    // MARK: - Published State

    /// All channels sorted by last activity (most recent first).
    var channels: [Channel] = []

    /// Messages in the currently active channel, sorted oldest to newest.
    var activeMessages: [Message] = []

    /// The currently selected/active channel.
    var activeChannel: Channel?

    /// Total unread message count across all channels.
    var totalUnreadCount: Int = 0

    /// Per-channel unread counts keyed by channel ID.
    var unreadCounts: [UUID: Int] = [:]

    /// Peer IDs currently showing typing indicators, keyed by channel ID.
    var typingIndicators: [UUID: Set<String>] = [:]

    /// Text currently being composed in the active channel.
    var composingText: String = ""

    /// Whether a message send is in progress.
    var isSending = false

    /// The most recent error, if any.
    var errorMessage: String?

    /// Whether the chat list is loading.
    var isLoading = false

    /// Selected message for reply threading.
    var replyTarget: Message?

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let messageService: MessageService
    private let audioService: AudioService
    private let imageService: ImageService
    private let logger = Logger(subsystem: "com.blip", category: "ChatViewModel")

    /// Set of channel IDs the user has read up to (last read message timestamp).
    private var lastReadTimestamps: [UUID: Date] = [:]

    /// Typing indicator cleanup tasks keyed by "\(channelID)_\(peerID)".
    @ObservationIgnored private var typingResetTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        messageService: MessageService,
        audioService: AudioService = AudioService(),
        imageService: ImageService = ImageService()
    ) {
        self.modelContainer = modelContainer
        self.messageService = messageService
        self.audioService = audioService
        self.imageService = imageService
        self.messageService.delegate = self
    }

    deinit {
        for task in typingResetTasks.values {
            task.cancel()
        }
        typingResetTasks.removeAll()
    }

    // MARK: - Channel List

    /// Load all channels from SwiftData, sorted by last activity.
    func loadChannels() async {
        isLoading = true
        defer { isLoading = false }

        let context = ModelContext(modelContainer)

        do {
            channels = try context.fetch(FetchDescriptor<Channel>())
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            recalculateUnreadCounts()
        } catch {
            errorMessage = "Failed to load channels: \(error.localizedDescription)"
        }
    }

    /// Create a new DM channel with a user.
    func createDMChannel(with user: User) async -> Channel? {
        let context = ModelContext(modelContainer)
        let userID = user.id

        let persistedUser: User
        do {
            guard let fetchedUser = try context.fetch(FetchDescriptor<User>())
                .first(where: { $0.id == userID }) else {
                errorMessage = "Could not find the selected user."
                return nil
            }
            persistedUser = fetchedUser
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        // Check if DM already exists
        let username = persistedUser.username
        do {
            let existing = try context.fetch(FetchDescriptor<Channel>())
                .filter { $0.typeRaw == "dm" }
            for channel in existing {
                for membership in channel.memberships {
                    if membership.user?.username == username {
                        return channel
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        // Create new DM channel
        let channel = Channel(type: .dm, name: persistedUser.resolvedDisplayName)
        context.insert(channel)

        let membership = GroupMembership(user: persistedUser, channel: channel, role: .member)
        context.insert(membership)

        do {
            try context.save()
            await loadChannels()
            return channel
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Create a new group channel.
    func createGroupChannel(name: String, members: [User]) async -> Channel? {
        let context = ModelContext(modelContainer)

        let channel = Channel(type: .group, name: name)
        context.insert(channel)

        for member in members {
            let membership = GroupMembership(user: member, channel: channel, role: .member)
            context.insert(membership)
        }

        do {
            try context.save()
            await loadChannels()
            return channel
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Delete a channel and all its messages.
    func deleteChannel(_ channel: Channel) async {
        let context = ModelContext(modelContainer)
        context.delete(channel)
        do {
            try context.save()
            if activeChannel?.id == channel.id {
                activeChannel = nil
                activeMessages = []
            }
            await loadChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle mute status for a channel.
    func toggleMute(for channel: Channel) {
        let context = ModelContext(modelContainer)
        channel.muteStatus = channel.isMuted ? .unmuted : .mutedForever
        do {
            try context.save()
        } catch {
            logger.error("Failed to save mute status: \(error.localizedDescription)")
            errorMessage = "Failed to save mute status: \(error.localizedDescription)"
        }
    }

    /// Toggle pin status for a channel.
    func togglePin(for channel: Channel) {
        let context = ModelContext(modelContainer)
        channel.isPinned.toggle()
        do {
            try context.save()
        } catch {
            logger.error("Failed to save pin status: \(error.localizedDescription)")
            errorMessage = "Failed to save pin status: \(error.localizedDescription)"
        }
    }

    // MARK: - Active Conversation

    /// Open a conversation by loading its messages.
    func openConversation(_ channel: Channel) async {
        activeChannel = channel
        replyTarget = nil
        composingText = ""

        let context = ModelContext(modelContainer)
        let channelID = channel.id

        do {
            activeMessages = try context.fetch(FetchDescriptor<Message>())
                .filter { $0.channel?.id == channelID }
                .sorted { $0.createdAt < $1.createdAt }
            markChannelAsRead(channel)
        } catch {
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    /// Close the active conversation.
    func closeConversation() {
        activeChannel = nil
        activeMessages = []
        replyTarget = nil
        composingText = ""
    }

    // MARK: - Send Messages

    /// Send a text message in the active channel.
    /// - Parameter override: Pre-captured text from the send button. When provided,
    ///   this is used instead of `composingText` to avoid the race where the input
    ///   binding clears `composingText` before this async method reads it.
    func sendTextMessage(text override: String? = nil) async {
        guard let channel = activeChannel else { return }
        let text = (override ?? composingText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        composingText = ""
        errorMessage = nil

        do {
            let message = try await messageService.sendTextMessage(
                content: text,
                to: channel,
                replyTo: replyTarget
            )
            activeMessages.append(message)
            replyTarget = nil
            channel.lastActivityAt = Date()
            await loadChannels()
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }

        isSending = false
    }

    /// Send a voice note in the active channel.
    func sendVoiceNote(audioData: Data, duration: TimeInterval) async {
        guard let channel = activeChannel else { return }

        isSending = true
        errorMessage = nil

        do {
            let message = try await messageService.sendVoiceNote(
                audioData: audioData,
                duration: duration,
                to: channel
            )
            activeMessages.append(message)
            channel.lastActivityAt = Date()
            await loadChannels()
        } catch {
            errorMessage = "Failed to send voice note: \(error.localizedDescription)"
        }

        isSending = false
    }

    /// Send an image in the active channel.
    func sendImage(imageData: Data) async {
        guard let channel = activeChannel else { return }

        isSending = true
        errorMessage = nil

        do {
            let compressed = try imageService.compress(data: imageData)
            let thumbnail = try imageService.generateThumbnail(from: imageData, size: .messagePreview)
            let message = try await messageService.sendImage(
                imageData: compressed,
                thumbnail: thumbnail,
                to: channel
            )
            activeMessages.append(message)
            channel.lastActivityAt = Date()
            await loadChannels()
        } catch {
            errorMessage = "Failed to send image: \(error.localizedDescription)"
        }

        isSending = false
    }

    // MARK: - Typing Indicators

    /// Send a typing indicator for the active channel.
    func sendTypingIndicator() {
        guard let channel = activeChannel else { return }
        Task {
            do {
                try await messageService.sendTypingIndicator(to: channel)
            } catch {
                logger.warning("Failed to send typing indicator: \(error.localizedDescription)")
            }
        }
    }

    /// Handle an incoming typing indicator.
    func handleTypingIndicator(from peerDescription: String, in channelID: UUID) {
        var indicators = typingIndicators[channelID] ?? []
        indicators.insert(peerDescription)
        typingIndicators[channelID] = indicators

        // Auto-clear after 4 seconds
        let timerKey = "\(channelID.uuidString)_\(peerDescription)"
        typingResetTasks[timerKey]?.cancel()
        typingResetTasks[timerKey] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }

            await MainActor.run {
                self?.typingIndicators[channelID]?.remove(peerDescription)
                if self?.typingIndicators[channelID]?.isEmpty == true {
                    self?.typingIndicators.removeValue(forKey: channelID)
                }
                self?.typingResetTasks.removeValue(forKey: timerKey)
            }
        }
    }

    /// Get the typing indicator text for a channel (e.g., "Alice is typing..." or "Alice and Bob are typing...").
    func typingText(for channelID: UUID) -> String? {
        guard let typers = typingIndicators[channelID], !typers.isEmpty else { return nil }

        let names = Array(typers)
        switch names.count {
        case 1:
            return "\(names[0]) is typing..."
        case 2:
            return "\(names[0]) and \(names[1]) are typing..."
        default:
            return "\(names.count) people are typing..."
        }
    }

    // MARK: - Unread Counts

    /// Mark a channel as read up to the current time.
    func markChannelAsRead(_ channel: Channel) {
        lastReadTimestamps[channel.id] = Date()
        unreadCounts[channel.id] = 0
        recalculateUnreadCounts()

        // Send read receipts for recent messages
        let context = ModelContext(modelContainer)
        do {
            let unread = try context.fetch(FetchDescriptor<Message>())
                .filter { $0.channel?.id == channel.id && $0.statusRaw == "delivered" }
            for message in unread {
                if let sender = message.sender {
                    let peerID = PeerID(noisePublicKey: sender.noisePublicKey)
                    Task {
                        do {
                            try await messageService.sendReadReceipt(for: message.id, to: peerID)
                        } catch {
                            logger.warning("Failed to send read receipt: \(error.localizedDescription)")
                        }
                    }
                }
                message.status = .read
            }
            do {
                try context.save()
            } catch {
                logger.error("Failed to save read status: \(error.localizedDescription)")
                errorMessage = "Failed to save read status: \(error.localizedDescription)"
            }
        } catch {
            logger.error("Failed to fetch unread messages: \(error.localizedDescription)")
            errorMessage = "Failed to fetch unread messages: \(error.localizedDescription)"
        }
    }

    /// Recalculate unread counts for all channels.
    private func recalculateUnreadCounts() {
        var total = 0
        for channel in channels {
            let lastRead = lastReadTimestamps[channel.id] ?? .distantPast
            let unread = channel.messages.filter { $0.createdAt > lastRead && $0.status != .read }.count
            unreadCounts[channel.id] = unread
            total += unread
        }
        totalUnreadCount = total
    }

    /// Handle a newly received message (called by delegate or notification).
    func handleReceivedMessage(messageID: UUID, channelID: UUID) {
        let context = ModelContext(modelContainer)
        guard let message = try? context.fetch(FetchDescriptor<Message>())
            .first(where: { $0.id == messageID }),
              let channel = try? context.fetch(FetchDescriptor<Channel>())
            .first(where: { $0.id == channelID }) else {
            return
        }

        // Add to active messages if this is the open channel
        if activeChannel?.id == channel.id {
            activeMessages.append(message)
        } else {
            // Increment unread count
            let current = unreadCounts[channel.id] ?? 0
            unreadCounts[channel.id] = current + 1
            totalUnreadCount += 1
        }

        // Update channel list ordering
        if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
            channels.remove(at: idx)
            channels.insert(channel, at: 0)
        } else {
            channels.insert(channel, at: 0)
        }
    }

    /// Handle a delivery acknowledgement.
    func handleDeliveryAck(for messageID: UUID) {
        if let idx = activeMessages.firstIndex(where: { $0.id == messageID }) {
            activeMessages[idx].status = .delivered
        }
    }

    /// Handle a read receipt.
    func handleReadReceipt(for messageID: UUID) {
        if let idx = activeMessages.firstIndex(where: { $0.id == messageID }) {
            activeMessages[idx].status = .read
        }
    }

    // MARK: - Message Actions

    /// Delete a message.
    func deleteMessage(_ message: Message) async {
        let context = ModelContext(modelContainer)
        context.delete(message)
        do {
            try context.save()
            activeMessages.removeAll { $0.id == message.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Set a message as the reply target.
    func setReplyTarget(_ message: Message?) {
        replyTarget = message
    }

    /// Clear reply target.
    func clearReplyTarget() {
        replyTarget = nil
    }
}

extension ChatViewModel: MessageServiceDelegate {
    func messageService(_ service: MessageService, didReceiveMessageWithID messageID: UUID, in channelID: UUID) {
        handleReceivedMessage(messageID: messageID, channelID: channelID)
    }

    func messageService(_ service: MessageService, didUpdateStatus status: MessageStatus, for messageID: UUID) {
        if let activeIndex = self.activeMessages.firstIndex(where: { $0.id == messageID }) {
            self.activeMessages[activeIndex].status = status
        }
    }

    func messageService(_ service: MessageService, didReceiveTypingIndicatorFrom peerID: PeerID, in channelID: UUID) {
        let peerLabel = peerID.bytes
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()

        self.handleTypingIndicator(from: "Peer \(peerLabel)", in: channelID)
    }

    func messageService(_ service: MessageService, didReceiveDeliveryAck messageID: UUID) {
        self.handleDeliveryAck(for: messageID)
    }

    func messageService(_ service: MessageService, didReceiveReadReceipt messageID: UUID) {
        self.handleReadReceipt(for: messageID)
    }
}
