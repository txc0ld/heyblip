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

    /// Message currently being edited, if any.
    var editingMessage: Message?

    // MARK: - Dependencies

    private let context: ModelContext
    private let messageService: MessageService
    private let audioService: AudioService
    private let imageService: ImageService
    private let notificationService: NotificationService
    private let logger = Logger(subsystem: "com.blip", category: "ChatViewModel")

    /// Typing indicator cleanup tasks keyed by "\(channelID)_\(peerID)".
    @ObservationIgnored private var typingResetTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    init(
        messageService: MessageService,
        audioService: AudioService = AudioService(),
        imageService: ImageService = ImageService(),
        notificationService: NotificationService = NotificationService()
    ) {
        self.messageService = messageService
        self.context = messageService.context
        self.audioService = audioService
        self.imageService = imageService
        self.notificationService = notificationService
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
    /// Used for initial load and pull-to-refresh only.
    func loadChannels() async {
        isLoading = true
        defer { isLoading = false }

        let context = self.context

        do {
            var allChannels = try context.fetch(FetchDescriptor<Channel>())

            // Deduplicate DM channels sharing the same conversation key
            let dmChannels = allChannels.filter { $0.type == .dm }
            let grouped = Dictionary(grouping: dmChannels) { $0.dmConversationKey ?? "unknown:\($0.id)" }
            for (key, duplicates) in grouped where duplicates.count > 1 {
                let sorted = duplicates.sorted { $0.createdAt < $1.createdAt }
                let primary = sorted[0]
                for duplicate in sorted.dropFirst() {
                    for message in duplicate.messages {
                        message.channel = primary
                    }
                    context.delete(duplicate)
                    allChannels.removeAll { $0.id == duplicate.id }
                }
                DebugLogger.shared.log("CHAT", "Deduped \(duplicates.count - 1) duplicate channel(s) for key \(DebugLogger.redact(key))")
            }
            try context.save()

            channels = allChannels
            sortChannels()
            syncUnreadCounts()
        } catch {
            errorMessage = "Failed to load channels: \(error.localizedDescription)"
        }
    }

    /// Sort channels: pinned first, then by lastActivityAt descending.
    private func sortChannels() {
        channels.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.lastActivityAt > b.lastActivityAt
        }
    }

    /// Move a channel to its correct sorted position after an update.
    private func moveChannelToSortedPosition(_ channel: Channel) {
        channels.removeAll { $0.id == channel.id }
        let insertIndex = channels.firstIndex { existing in
            if channel.isPinned != existing.isPinned { return channel.isPinned }
            return channel.lastActivityAt > existing.lastActivityAt
        } ?? channels.endIndex
        channels.insert(channel, at: insertIndex)
    }

    /// Sync the in-memory unreadCounts from stored Channel.unreadCount values.
    private func syncUnreadCounts() {
        var total = 0
        for channel in channels {
            unreadCounts[channel.id] = channel.unreadCount
            total += channel.unreadCount
        }
        totalUnreadCount = total
    }

    private func conversationChannels(for channel: Channel, context: ModelContext) throws -> [Channel] {
        guard channel.type == .dm, let conversationKey = channel.dmConversationKey else {
            let channelID = channel.id
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
            return try context.fetch(descriptor)
        }

        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
        let dmChannels = try context.fetch(descriptor)
        let matchingChannels = dmChannels.filter { $0.dmConversationKey == conversationKey }
        return matchingChannels.isEmpty ? [channel] : matchingChannels
    }

    private func preferredConversationChannel(from channels: [Channel], fallback: Channel) -> Channel {
        var preferredChannel = channels.first ?? fallback

        for candidate in channels.dropFirst() {
            if candidate.lastActivityAt > preferredChannel.lastActivityAt {
                preferredChannel = candidate
                continue
            }
            if candidate.lastActivityAt < preferredChannel.lastActivityAt {
                continue
            }
            if candidate.messages.count > preferredChannel.messages.count {
                preferredChannel = candidate
                continue
            }
            if candidate.messages.count < preferredChannel.messages.count {
                continue
            }
            if candidate.createdAt > preferredChannel.createdAt {
                preferredChannel = candidate
                continue
            }
            if candidate.createdAt < preferredChannel.createdAt {
                continue
            }
            if candidate.id.uuidString < preferredChannel.id.uuidString {
                preferredChannel = candidate
            }
        }

        return preferredChannel
    }

    private func loadMessages(for channels: [Channel], context: ModelContext) throws -> [Message] {
        var messages: [Message] = []

        for channel in channels {
            let channelID = channel.id
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.channel?.id == channelID })
            messages.append(contentsOf: try context.fetch(descriptor))
        }

        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    private func isSameConversation(_ lhs: Channel, _ rhs: Channel) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        guard lhs.type == .dm, rhs.type == .dm else {
            return false
        }

        guard let lhsKey = lhs.dmConversationKey, let rhsKey = rhs.dmConversationKey else {
            return false
        }

        return lhsKey == rhsKey
    }

    private func isActiveConversation(_ channel: Channel) -> Bool {
        // "Active" means the user is currently *looking at* the chat —
        // NotificationService.currentActiveChannelID is the source-of-truth
        // for visibility (set in `openConversation`, cleared in
        // `clearTransientConversationState` / `closeConversation`). The
        // cached `activeChannel` field deliberately outlives the ChatView
        // lifetime so the message cache stays hot for back-and-forth
        // navigation; gating on it alone left local notifications
        // permanently suppressed for any thread that had ever been opened.
        guard notificationService.currentActiveChannelID() != nil else {
            return false
        }
        guard let activeChannel else { return false }
        return isSameConversation(activeChannel, channel)
    }

    /// Create a new DM channel with a user.
    func createDMChannel(with user: User) async -> Channel? {
        let context = self.context
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

        do {
            let channel = try messageService.findOrCreateDMChannel(with: persistedUser, context: context)
            await loadChannels()
            return channel
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Create a new group channel.
    func createGroupChannel(name: String, members: [User]) async -> Channel? {
        let context = self.context

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
        let context = self.context
        let channelID = channel.id
        context.delete(channel)
        do {
            try context.save()
            if activeChannel?.id == channelID {
                activeChannel = nil
                activeMessages = []
            }
            let removedUnread = unreadCounts.removeValue(forKey: channelID) ?? 0
            totalUnreadCount = max(0, totalUnreadCount - removedUnread)
            channels.removeAll { $0.id == channelID }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle mute status for a channel.
    func toggleMute(for channel: Channel) {
        let context = self.context
        channel.muteStatus = channel.isMuted ? .unmuted : .mutedForever
        do {
            try context.save()
            // No re-sort needed — mute doesn't affect ordering
        } catch {
            logger.error("Failed to save mute status: \(error.localizedDescription)")
            errorMessage = "Failed to save mute status: \(error.localizedDescription)"
        }
    }

    /// Toggle pin status for a channel.
    func togglePin(for channel: Channel) {
        let context = self.context
        channel.isPinned.toggle()
        do {
            try context.save()
            sortChannels()
        } catch {
            logger.error("Failed to save pin status: \(error.localizedDescription)")
            errorMessage = "Failed to save pin status: \(error.localizedDescription)"
        }
    }

    // MARK: - Active Conversation

    /// Open a conversation by loading its messages.
    func openConversation(_ channel: Channel) async {
        replyTarget = nil
        composingText = ""

        let context = self.context

        do {
            let conversationChannels = try conversationChannels(for: channel, context: context)
            let preferredChannelID = preferredConversationChannel(from: conversationChannels, fallback: channel).id
            activeChannel = channels.first(where: { $0.id == preferredChannelID }) ?? channel
            activeMessages = try loadMessages(for: conversationChannels, context: context)
            let resolvedChannel = activeChannel ?? channel
            markChannelAsRead(resolvedChannel)
            notificationService.clearNotifications(forChannel: resolvedChannel.id)
            // Tell NotificationService which thread is on screen so foreground banners
            // for it get suppressed (sound-only) instead of duplicating the bubble that
            // is literally about to render.
            notificationService.setActiveChannel(resolvedChannel.id)
        } catch {
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    /// Fully close the active conversation. Clears both the identity of the
    /// active channel and its cached messages. Use this when the conversation
    /// is being deleted or the user signs out.
    func closeConversation() {
        activeChannel = nil
        activeMessages = []
        replyTarget = nil
        composingText = ""
        notificationService.setActiveChannel(nil)
    }

    /// Clear only transient composer state (reply target, composing text) when
    /// the chat view disappears. `activeChannel` and `activeMessages` are left
    /// intact so that returning to the same conversation renders immediately
    /// from cache instead of flashing empty while `openConversation` reloads.
    func clearTransientConversationState() {
        replyTarget = nil
        // Intentionally keep `composingText` so the user's in-progress draft
        // survives a brief back-and-forth. ChatView also mirrors composingText
        // into a local @State, so losing it here would surprise the user.

        // Resume normal foreground notification behavior — the user has stepped
        // out of the thread. We deliberately leave `activeChannel` set so the
        // cached message list survives back-and-forth navigation; only the
        // notification suppression flag is cleared.
        notificationService.setActiveChannel(nil)
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
            moveChannelToSortedPosition(channel)
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
            moveChannelToSortedPosition(channel)
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
            moveChannelToSortedPosition(channel)
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
            return ChatViewModelL10n.singleTyping(names[0])
        case 2:
            return ChatViewModelL10n.twoTyping(names[0], names[1])
        default:
            return ChatViewModelL10n.manyTyping(names.count)
        }
    }

    /// Resolve a PeerID's raw bytes to a human-readable display name.
    ///
    /// Lookup order: PeerStore username → SwiftData User displayName → hex fallback.
    private func resolveDisplayName(for peerData: Data) -> String {
        if let peerInfo = PeerStore.shared.findPeer(byPeerIDBytes: peerData),
           let username = peerInfo.username {
            let targetUsername = username
            var descriptor = FetchDescriptor<User>(
                predicate: #Predicate<User> { $0.username == targetUsername }
            )
            descriptor.fetchLimit = 1
            do {
                if let user = try context.fetch(descriptor).first {
                    return user.resolvedDisplayName
                }
            } catch {
                DebugLogger.shared.log("CHAT", "Failed to fetch user for typing indicator: \(error.localizedDescription)")
            }
            return username
        }

        let peerLabel = peerData
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "Peer \(peerLabel)"
    }

    // MARK: - Unread Counts

    /// Mark a channel as read up to the current time.
    func markChannelAsRead(_ channel: Channel) {
        let previousUnread = unreadCounts[channel.id] ?? 0

        // Batch read receipts: send one per sender (with their latest message ID)
        // instead of one per unread message.
        let context = self.context
        do {
            let conversationChannels = try conversationChannels(for: channel, context: context)
            var removedUnread = previousUnread

            for conversationChannel in conversationChannels where conversationChannel.id != channel.id {
                let unread = unreadCounts[conversationChannel.id] ?? conversationChannel.unreadCount
                unreadCounts[conversationChannel.id] = 0
                conversationChannel.unreadCount = 0
                removedUnread += unread
            }

            unreadCounts[channel.id] = 0
            channel.unreadCount = 0
            totalUnreadCount = max(0, totalUnreadCount - removedUnread)

            let unreadMessages = try loadMessages(for: conversationChannels, context: context)
                .filter { $0.statusRaw == "delivered" }

            // Group by sender and pick the latest message per sender for the receipt
            var latestPerSender: [Data: Message] = [:]
            for message in unreadMessages {
                guard let sender = message.sender else { continue }
                let key = sender.noisePublicKey
                if let existing = latestPerSender[key] {
                    if message.createdAt > existing.createdAt {
                        latestPerSender[key] = message
                    }
                } else {
                    latestPerSender[key] = message
                }
                message.status = .read
            }

            // Send one read receipt per sender (latest message)
            for (senderKey, message) in latestPerSender {
                let peerID = PeerID(noisePublicKey: senderKey)
                Task {
                    do {
                        try await messageService.sendReadReceipt(for: message.id, to: peerID)
                    } catch {
                        logger.warning("Failed to send read receipt: \(error.localizedDescription)")
                    }
                }
            }

            try context.save()
        } catch {
            logger.error("Failed to process read receipts: \(error.localizedDescription)")
            errorMessage = "Failed to process read receipts: \(error.localizedDescription)"
        }
    }

    /// Handle a newly received message (called by delegate or notification).
    ///
    /// Updates `lastActivityAt`, optionally bumps `unreadCount`, and persists both to the
    /// shared SwiftData context so the chat list ordering and the unread badge survive an
    /// app restart. Without the explicit save the in-memory channel object reflects the new
    /// state but the on-disk row does not, so the next cold launch rolls the counters back.
    func handleReceivedMessage(_ message: Message, in channel: Channel) {
        let wasActive = isActiveConversation(channel)

        if wasActive {
            activeMessages.append(message)
        } else {
            channel.unreadCount += 1
            unreadCounts[channel.id] = channel.unreadCount
            totalUnreadCount += 1

            if !channel.isMuted {
                notificationService.notifyNewMessage(
                    senderName: message.sender?.resolvedDisplayName ?? ChatViewModelL10n.someone,
                    messagePreview: String(data: message.rawPayload, encoding: .utf8) ?? "",
                    channelID: channel.id,
                    channelName: channel.type == .group ? channel.name : nil,
                    messageType: message.typeRaw
                )
                DebugLogger.shared.log("NOTIF", "Posted local notif for msg \(message.id) in channel \(channel.id)")
            } else {
                DebugLogger.shared.log("NOTIF", "Suppressed (muted) for msg \(message.id) in channel \(channel.id)")
            }
        }

        channel.lastActivityAt = Date()
        moveChannelToSortedPosition(channel)

        do {
            try context.save()
        } catch {
            DebugLogger.shared.log(
                "DM",
                "Failed to persist channel state after receive: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// Handle a delivery acknowledgement. Updates the persisted Message row and the active
    /// list snapshot, then re-sorts the channel list so the freshly-acknowledged thread
    /// bubbles up like other status-change events.
    func handleDeliveryAck(for messageID: UUID) {
        applyStatusChange(.delivered, for: messageID, category: "delivery ack")
    }

    /// Handle a read receipt. Same persistence + re-sort discipline as delivery ack.
    func handleReadReceipt(for messageID: UUID) {
        applyStatusChange(.read, for: messageID, category: "read receipt")
    }

    /// Persist a status change for a message regardless of whether it's currently in
    /// `activeMessages` and bump the channel's position in the sorted list. The previous
    /// implementation only mutated `activeMessages[idx]` which (a) silently dropped the
    /// update for status changes that arrived while the user was on a different channel and
    /// (b) left the chat-list cell stale until the next reload.
    private func applyStatusChange(_ newStatus: MessageStatus, for messageID: UUID, category: String) {
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })

        let persistedMessage: Message?
        do {
            persistedMessage = try context.fetch(descriptor).first
        } catch {
            DebugLogger.shared.log(
                "DM",
                "Failed to fetch message for \(category): \(error.localizedDescription)",
                isError: true
            )
            return
        }

        guard let message = persistedMessage else { return }
        message.statusRaw = newStatus.rawValue

        if let idx = activeMessages.firstIndex(where: { $0.id == messageID }) {
            activeMessages[idx] = message
        }

        if let owningChannel = message.channel {
            moveChannelToSortedPosition(owningChannel)
        }

        do {
            try context.save()
        } catch {
            DebugLogger.shared.log(
                "DM",
                "Failed to persist \(category): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Message Actions

    /// Mark a message as deleted locally and notify the remote peer.
    func deleteMessage(_ message: Message) async {
        let context = self.context
        let messageID = message.id
        do {
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
            guard let localMessage = try context.fetch(descriptor).first else { return }
            localMessage.isDeleted = true
            localMessage.rawPayload = Data()
            try context.save()
            if let idx = activeMessages.firstIndex(where: { $0.id == messageID }) {
                activeMessages[idx] = localMessage
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Send delete to remote peer
        if let channel = activeChannel {
            do {
                try await messageService.sendMessageDelete(messageID: messageID, to: channel)
            } catch {
                DebugLogger.shared.log("DM", "Failed to send remote delete: \(error.localizedDescription)")
            }
        }
    }

    /// Begin editing a message (only own messages within 5 minutes).
    func startEditing(_ message: Message) {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        guard message.sender == nil, message.createdAt > fiveMinutesAgo else { return }
        editingMessage = message
        composingText = String(data: message.rawPayload, encoding: .utf8) ?? ""
    }

    /// Cancel edit mode.
    func cancelEditing() {
        editingMessage = nil
        composingText = ""
    }

    /// Apply an edit to a message locally and notify the remote peer.
    func applyEdit(newText: String) async {
        guard let editing = editingMessage else { return }
        let editID = editing.id
        let context = self.context
        do {
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == editID })
            guard let localMessage = try context.fetch(descriptor).first else { return }
            localMessage.rawPayload = newText.data(using: .utf8) ?? Data()
            localMessage.isEdited = true
            localMessage.editedAt = Date()
            try context.save()
            if let idx = activeMessages.firstIndex(where: { $0.id == editID }) {
                activeMessages[idx] = localMessage
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        editingMessage = nil
        composingText = ""

        // Send edit to remote peer
        if let channel = activeChannel {
            do {
                try await messageService.sendMessageEdit(messageID: editID, newContent: newText, to: channel)
            } catch {
                DebugLogger.shared.log("DM", "Failed to send remote edit: \(error.localizedDescription)")
            }
        }
    }

    /// Retry sending a failed message.
    func retryMessage(_ message: Message) async {
        guard let channel = activeChannel,
              let text = String(data: message.rawPayload, encoding: .utf8),
              !text.isEmpty else { return }

        // Remove the failed message from the list
        activeMessages.removeAll { $0.id == message.id }

        // Delete the failed record
        let context = self.context
        let failedID = message.id
        do {
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == failedID })
            if let failed = try context.fetch(descriptor).first {
                context.delete(failed)
                try context.save()
            }
        } catch {
            DebugLogger.shared.log("DM", "Failed to clean up failed message: \(error.localizedDescription)")
        }

        // Re-send
        do {
            let newMessage = try await messageService.sendTextMessage(content: text, to: channel)
            activeMessages.append(newMessage)
        } catch {
            errorMessage = "Retry failed: \(error.localizedDescription)"
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

    /// Apply or clear the reaction emoji on a message and transmit it over the wire.
    ///
    /// `MessageService.sendReaction` handles the optimistic local persistence and the
    /// encrypted send. This method just dispatches the async work and refreshes
    /// `activeMessages` so the bubble re-renders immediately. Passing `nil` clears.
    func setReaction(_ emoji: String?, on message: Message) {
        let messageID = message.id
        guard let channel = message.channel ?? activeChannel else {
            DebugLogger.shared.log("DM", "setReaction: no channel for message \(DebugLogger.redact(messageID.uuidString))", isError: true)
            return
        }
        Task { @MainActor in
            do {
                try await self.messageService.sendReaction(emoji, for: messageID, in: channel)
                self.refreshReaction(for: messageID)
            } catch {
                DebugLogger.shared.log("DM", "sendReaction failed: \(error.localizedDescription)", isError: true)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-fetch the message identified by `messageID` and replace it in `activeMessages`
    /// so the chat bubble observes the new reaction. No-op if the message isn't currently
    /// rendered.
    fileprivate func refreshReaction(for messageID: UUID) {
        let context = self.context
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        do {
            guard let updated = try context.fetch(descriptor).first else { return }
            if let idx = activeMessages.firstIndex(where: { $0.id == messageID }) {
                activeMessages[idx] = updated
            }
        } catch {
            DebugLogger.shared.log("DM", "refreshReaction fetch failed: \(error.localizedDescription)", isError: true)
        }
    }
}

extension ChatViewModel: MessageServiceDelegate {
    nonisolated func messageService(_ service: MessageService, didReceiveMessageID messageID: UUID, channelID: UUID) {
        Task { @MainActor in
            let context = self.context
            let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
            let channelDescriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
            do {
                guard let message = try context.fetch(descriptor).first,
                      let channel = try context.fetch(channelDescriptor).first else {
                    DebugLogger.shared.log("DM", "Delegate: could not fetch message \(messageID) or channel \(channelID)")
                    return
                }
                self.handleReceivedMessage(message, in: channel)
            } catch {
                DebugLogger.shared.log("DM", "Delegate: fetch error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func messageService(_ service: MessageService, didUpdateStatus status: MessageStatus, for messageID: UUID) {
        Task { @MainActor in
            self.applyStatusChange(status, for: messageID, category: "status update")
        }
    }

    nonisolated func messageService(_ service: MessageService, didReceiveTypingIndicatorFrom peerID: PeerID, in channelID: UUID) {
        let peerData = peerID.bytes

        Task { @MainActor in
            let displayName = self.resolveDisplayName(for: peerData)
            self.handleTypingIndicator(from: displayName, in: channelID)
        }
    }

    nonisolated func messageService(_ service: MessageService, didReceiveDeliveryAck messageID: UUID) {
        Task { @MainActor in
            self.handleDeliveryAck(for: messageID)
        }
    }

    nonisolated func messageService(_ service: MessageService, didReceiveReadReceipt messageID: UUID) {
        Task { @MainActor in
            self.handleReadReceipt(for: messageID)
        }
    }

    nonisolated func messageService(_ service: MessageService, didUpdateReactionFor messageID: UUID) {
        Task { @MainActor in
            self.refreshReaction(for: messageID)
        }
    }
}

// MARK: - Localization

private enum ChatViewModelL10n {
    static let someone = String(localized: "chat.notification.sender.fallback", defaultValue: "Someone")

    static func singleTyping(_ name: String) -> String {
        String(format: String(localized: "chat.typing.single", defaultValue: "%@ is typing..."), locale: Locale.current, name)
    }

    static func twoTyping(_ name1: String, _ name2: String) -> String {
        String(format: String(localized: "chat.typing.two", defaultValue: "%@ and %@ are typing..."), locale: Locale.current, name1, name2)
    }

    static func manyTyping(_ count: Int) -> String {
        String(format: String(localized: "chat.typing.many", defaultValue: "%d people are typing..."), locale: Locale.current, count)
    }
}
