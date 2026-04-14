import SwiftUI
import SwiftData
import PhotosUI

private enum ChatViewL10n {
    static let recording = String(localized: "chat.recording.label", defaultValue: "Recording...")
    static let unknown = String(localized: "common.unknown", defaultValue: "Unknown")
    static let recordingVoiceNote = String(localized: "chat.recording.voice_note", defaultValue: "Recording voice note")
    static let deleteTitle = String(localized: "chat.delete_message.title", defaultValue: "Delete message?")
    static let delete = String(localized: "common.delete", defaultValue: "Delete")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let deleteMessage = String(localized: "chat.delete_message.body", defaultValue: "This can't be undone.")
    static let encrypted = String(localized: "chat.encryption.enabled", defaultValue: "Encrypted")
    static let endToEndEncrypted = String(localized: "chat.encryption.accessibility", defaultValue: "End-to-end encrypted")
    static let online = String(localized: "chat.presence.online", defaultValue: "Online")
    static let lastSeenRecently = String(localized: "chat.presence.last_seen_recently", defaultValue: "Last seen recently")
    static let messageDeleted = String(localized: "chat.message.deleted", defaultValue: "Message deleted")
    static let today = String(localized: "common.today", defaultValue: "Today")
    static let yesterday = String(localized: "common.yesterday", defaultValue: "Yesterday")

    static func jumpToLatest(count: Int) -> String {
        String(
            format: String(localized: "chat.jump_to_latest.accessibility.with_count", defaultValue: "%d new messages. Jump to latest."),
            locale: Locale.current,
            count
        )
    }

    static let jumpToLatestSingle = String(localized: "chat.jump_to_latest.accessibility.single", defaultValue: "Jump to latest message")

    // Transport indicator
    static let transportBLE = String(localized: "chat.transport.ble", defaultValue: "Mesh")
    static let transportRelay = String(localized: "chat.transport.relay", defaultValue: "Relay")
    static let transportBLEAccessibility = String(localized: "chat.transport.ble.accessibility", defaultValue: "Messages via Bluetooth mesh")
    static let transportRelayAccessibility = String(localized: "chat.transport.relay.accessibility", defaultValue: "Messages via internet relay")
    static let transportBothAccessibility = String(localized: "chat.transport.both.accessibility", defaultValue: "Messages via Bluetooth mesh and internet relay")
    static let transportOfflineAccessibility = String(localized: "chat.transport.offline.accessibility", defaultValue: "No transport available")
}

// MARK: - ChatView

/// Full chat conversation view.
/// ScrollViewReader + LazyVStack, auto-scroll on new message, date headers,
/// typing indicator, and pinned message input.
struct ChatView: View {

    let conversation: ConversationPreview
    var chatViewModel: ChatViewModel?

    @State private var messageText: String = ""
    @State private var showImageViewer = false
    @State private var selectedImageData: Data? = nil
    @State private var scrollToBottomID: UUID? = nil
    @State private var isPTTRecording = false
    @State private var pttAudioLevels: [Float] = []
    @State private var isRecordingVoiceNote = false
    @State private var showCameraPicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var voiceNoteService = AudioService()
    @State private var showDeleteConfirmation: Message?
    @State private var isNearBottom = true
    @State private var unseenMessageCount = 0
    @State private var scrollProxy: ScrollViewProxy?

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            messagesScrollView

            // Typing indicator
            if let typingText = chatViewModel?.typingText(for: conversation.id) {
                HStack {
                    TypingIndicator()
                    Text(typingText)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                    Spacer()
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.xs)
                .transition(.opacity)
            }

            // PTT waveform overlay
            if isPTTRecording {
                HStack(spacing: BlipSpacing.sm) {
                    Circle()
                        .fill(theme.colors.statusRed)
                        .frame(width: 8, height: 8)

                    WaveformView(
                        levels: pttAudioLevels.isEmpty
                            ? Array(repeating: Float.random(in: 0.1...0.6), count: 16)
                            : pttAudioLevels,
                        color: .blipAccentPurple,
                        isActive: true
                    )
                    .frame(height: 32)

                    Text(ChatViewL10n.recording)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.xs)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Message input (pinned at bottom)
            MessageInput(
                text: Binding(
                    get: { chatViewModel?.composingText ?? messageText },
                    set: { newValue in
                        if chatViewModel != nil {
                            chatViewModel?.composingText = newValue
                            chatViewModel?.sendTypingIndicator()
                        } else {
                            messageText = newValue
                        }
                    }
                ),
                onSend: { trimmedText in
                    if chatViewModel?.editingMessage != nil {
                        Task { await chatViewModel?.applyEdit(newText: trimmedText) }
                    } else {
                        Task { await sendMessage(text: trimmedText) }
                    }
                },
                onAttachment: {
                    Task { await recordAndSendVoiceNote() }
                },
                onCamera: {
                    if SystemImagePicker.isAvailable(.camera) {
                        showCameraPicker = true
                    } else {
                        showPhotoPicker = true
                    }
                },
                onPhotoLibrary: {
                    showPhotoPicker = true
                },
                onPTTStart: {
                    isPTTRecording = true
                    pttAudioLevels = []
                },
                onPTTEnd: {
                    isPTTRecording = false
                    pttAudioLevels = []
                },
                replyContext: chatViewModel?.replyTarget.map { msg in
                    (
                        senderName: msg.sender?.resolvedDisplayName ?? ChatViewL10n.unknown,
                        preview: String(data: msg.rawPayload, encoding: .utf8) ?? ""
                    )
                },
                onClearReply: {
                    chatViewModel?.clearReplyTarget()
                },
                isEditing: chatViewModel?.editingMessage != nil,
                onCancelEdit: {
                    chatViewModel?.cancelEditing()
                }
            )
            .accessibilityValue(isRecordingVoiceNote ? ChatViewL10n.recordingVoiceNote : "")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationTitleView
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert(
            ChatViewL10n.deleteTitle,
            isPresented: Binding(
                get: { showDeleteConfirmation != nil },
                set: { if !$0 { showDeleteConfirmation = nil } }
            )
        ) {
            Button(ChatViewL10n.delete, role: .destructive) {
                if let message = showDeleteConfirmation {
                    Task { await chatViewModel?.deleteMessage(message) }
                }
            }
            Button(ChatViewL10n.cancel, role: .cancel) {}
        } message: {
            Text(ChatViewL10n.deleteMessage)
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            ImageViewer(imageData: selectedImageData, isPresented: $showImageViewer)
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            SystemImagePicker(isPresented: $showCameraPicker, sourceType: .camera) { image in
                guard let vm = chatViewModel else { return }
                guard let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData() else {
                    DebugLogger.shared.log("UI", "Failed to encode captured camera image", isError: true)
                    return
                }

                Task {
                    await vm.sendImage(imageData: data)
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, newItem in
            guard let vm = chatViewModel else { return }

            Task {
                do {
                    if let data = try await newItem?.loadTransferable(type: Data.self) {
                        await vm.sendImage(imageData: data)
                    }
                } catch {
                    DebugLogger.shared.log("UI", "Failed to load selected photo: \(error)", isError: true)
                }
                selectedPhoto = nil
            }
        }
        .overlay(alignment: .top) {
            if let error = chatViewModel?.errorMessage {
                Text(error)
                    .font(theme.typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.vertical, BlipSpacing.sm)
                    .background(Capsule().fill(theme.colors.statusRed))
                    .padding(.top, BlipSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            await loadConversation()
        }
        .onDisappear {
            chatViewModel?.closeConversation()
        }
    }

    // MARK: - Encryption State

    /// Whether this conversation has an active Noise encryption session.
    /// True for DM conversations where a connected peer holds a non-empty noise public key.
    private var isEncrypted: Bool {
        // Groups don't use Noise DM sessions
        guard conversation.ringStyle != .none else { return false }

        let peers = coordinator.peerStore.connectedPeers()
        return peers.contains { !$0.noisePublicKey.isEmpty }
    }

    // MARK: - Transport State

    /// Whether BLE mesh transport is active.
    private var isBLEActive: Bool {
        coordinator.meshViewModel?.isBLEActive ?? false
    }

    /// Whether WebSocket relay transport is connected.
    private var isWebSocketConnected: Bool {
        coordinator.meshViewModel?.isWebSocketConnected ?? false
    }

    // MARK: - Navigation Title

    private var navigationTitleView: some View {
        HStack(spacing: BlipSpacing.sm) {
            AvatarView(
                imageData: conversation.avatarData,
                name: conversation.displayName,
                size: 32,
                ringStyle: conversation.ringStyle,
                showOnlineIndicator: conversation.isOnline
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: BlipSpacing.xs) {
                    Text(conversation.displayName)
                        .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                        .foregroundStyle(theme.colors.text)

                    if isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.blipMint)
                            .accessibilityLabel(ChatViewL10n.endToEndEncrypted)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                HStack(spacing: BlipSpacing.xs) {
                        Text(conversation.isOnline ? ChatViewL10n.online : ChatViewL10n.lastSeenRecently)
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(
                            conversation.isOnline
                                ? theme.colors.statusGreen
                                : theme.colors.mutedText
                        )

                    if isEncrypted {
                        Text("\u{00B7} \(ChatViewL10n.encrypted)")
                            .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                            .foregroundStyle(Color.blipMint.opacity(0.8))
                    }

                    transportIndicator
                }
            }
        }
    }

    // MARK: - Transport Indicator

    /// Small inline indicator showing whether messages route via BLE mesh or WebSocket relay.
    @ViewBuilder
    private var transportIndicator: some View {
        let bleActive = isBLEActive
        let wsActive = isWebSocketConnected

        if bleActive || wsActive {
            HStack(spacing: 3) {
                Text("\u{00B7}")
                    .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.mutedText)

                if bleActive {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.blipAccentPurple)

                    Text(ChatViewL10n.transportBLE)
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                }

                if bleActive && wsActive {
                    Text("+")
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                }

                if wsActive {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.blipAccentPurple)

                    Text(ChatViewL10n.transportRelay)
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transportAccessibilityLabel)
            .transition(
                SpringConstants.isReduceMotionEnabled
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.9))
            )
            .animation(SpringConstants.gentleAnimation, value: bleActive)
            .animation(SpringConstants.gentleAnimation, value: wsActive)
        }
    }

    /// Accessibility label for the transport indicator.
    private var transportAccessibilityLabel: String {
        let bleActive = isBLEActive
        let wsActive = isWebSocketConnected

        switch (bleActive, wsActive) {
        case (true, true):
            return ChatViewL10n.transportBothAccessibility
        case (true, false):
            return ChatViewL10n.transportBLEAccessibility
        case (false, true):
            return ChatViewL10n.transportRelayAccessibility
        case (false, false):
            return ChatViewL10n.transportOfflineAccessibility
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: BlipSpacing.sm) {
                    // Date headers + messages
                    ForEach(Array(groupedMessages.enumerated()), id: \.offset) { sectionIndex, section in
                        // Date header
                        dateHeader(for: section.date)
                            .id("header-\(sectionIndex)")

                        // Messages in this date group
                        ForEach(Array(section.messages.enumerated()), id: \.element.id) { messageIndex, message in
                            messageBubble(for: message, at: messageIndex)
                        }
                    }

                    // Anchor for auto-scroll + bottom detection
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { isNearBottom = true; unseenMessageCount = 0 }
                        .onDisappear { isNearBottom = false }
                }
                .padding(.vertical, BlipSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { oldCount, newCount in
                if isNearBottom {
                    withAnimation(SpringConstants.accessibleMessage) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                } else {
                    let newMessages = newCount - oldCount
                    if newMessages > 0 {
                        unseenMessageCount += newMessages
                    }
                }
            }
            .onAppear {
                scrollProxy = proxy
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !isNearBottom {
                jumpToLatestButton
                    .padding(.bottom, BlipSpacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(SpringConstants.gentleAnimation, value: isNearBottom)
            }
        }
    }

    private var jumpToLatestButton: some View {
        Button {
            withAnimation(SpringConstants.accessibleMessage) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
            unseenMessageCount = 0
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                if unseenMessageCount > 0 {
                    Text("\(unseenMessageCount) new")
                        .font(.custom(BlipFontName.semiBold, size: 12, relativeTo: .caption2))
                }
            }
            .foregroundStyle(Color.blipAccentPurple)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.blipAccentPurple.opacity(0.3), lineWidth: 0.5)
            )
        }
        .accessibilityLabel(unseenMessageCount > 0
            ? ChatViewL10n.jumpToLatest(count: unseenMessageCount)
            : ChatViewL10n.jumpToLatestSingle)
    }

    // MARK: - Message Bubble

    private func messageBubble(for message: ChatMessage, at index: Int) -> some View {
        let messageID = message.id
        return MessageBubble(
            message: message,
            index: index,
            onReply: { findOriginal(messageID) { chatViewModel?.setReplyTarget($0) } },
            onImageTap: {
                selectedImageData = message.imageData
                showImageViewer = true
            },
            onEdit: { findOriginal(messageID) { chatViewModel?.startEditing($0) } },
            onDelete: { findOriginal(messageID) { showDeleteConfirmation = $0 } },
            onRetry: { findOriginal(messageID) { msg in Task { await chatViewModel?.retryMessage(msg) } } }
        )
        .id(message.id)
    }

    private func findOriginal(_ id: UUID, action: (Message) -> Void) {
        if let original = chatViewModel?.activeMessages.first(where: { $0.id == id }) {
            action(original)
        }
    }

    // MARK: - Date Header

    private func dateHeader(for date: Date) -> some View {
        Text(formattedDateHeader(date))
            .font(.custom(BlipFontName.medium, size: 12, relativeTo: .caption2))
            .foregroundStyle(theme.colors.mutedText)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.xs + 2)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.sm)
    }

    // MARK: - Grouped Messages

    private struct MessageSection {
        let date: Date
        let messages: [ChatMessage]
    }

    private var groupedMessages: [MessageSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { message in
            calendar.startOfDay(for: message.timestamp)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { MessageSection(date: $0.key, messages: $0.value.sorted { $0.timestamp < $1.timestamp }) }
    }

    // MARK: - Data

    /// Map ViewModel's active messages to UI model, falling back to sample data in preview.
    private var messages: [ChatMessage] {
        guard let vm = chatViewModel else {
            DebugLogger.emit("UI", "ChatView: chatViewModel is nil — showing empty state", isError: true)
            return []
        }
        return vm.activeMessages.map { message in
            ChatMessage(
                id: message.id,
                senderName: message.sender?.resolvedDisplayName ?? ChatViewL10n.unknown,
                senderAvatarData: message.sender?.avatarThumbnail,
                isFromMe: message.sender == nil,
                showSenderName: conversation.ringStyle == .none,
                text: message.isDeleted
                    ? ChatViewL10n.messageDeleted
                    : (String(data: message.rawPayload, encoding: .utf8) ?? ""),
                contentType: message.type,
                deliveryStatus: Self.mapDeliveryStatus(message.status),
                timestamp: message.createdAt,
                isEdited: message.isEdited,
                replyPreview: message.replyTo.flatMap {
                    String(data: $0.rawPayload, encoding: .utf8)
                },
                imageData: message.attachments.first?.fullData ?? message.attachments.first?.thumbnail,
                voiceNoteDuration: message.attachments.first(where: { $0.isAudio })?.duration,
                waveformSamples: [],
                audioData: message.attachments.first(where: { $0.isAudio })?.fullData
            )
        }
    }

    private static func mapDeliveryStatus(_ status: MessageStatus) -> StatusBadge.DeliveryStatus {
        switch status {
        case .composing: return .composing
        case .queued: return .queued
        case .encrypting: return .encrypting
        case .failed: return .failed
        case .sent: return .sent
        case .delivered: return .delivered
        case .read: return .read
        }
    }

    // MARK: - Actions

    private func loadConversation() async {
        guard let vm = chatViewModel else { return }
        // Find the channel matching this conversation's ID.
        guard let channel = vm.channels.first(where: { $0.id == conversation.id }) else { return }
        await vm.openConversation(channel)
    }

    private func sendMessage(text: String) async {
        guard let vm = chatViewModel else { return }
        await vm.sendTextMessage(text: text)
        if let profileVM = coordinator.profileViewModel {
            await profileVM.loadProfile()
        }
    }

    // MARK: - Voice Note

    private func recordAndSendVoiceNote() async {
        let audioService = voiceNoteService
        guard !isRecordingVoiceNote else {
            // Stop ongoing recording and send
            do {
                let (data, duration) = try audioService.stopRecording()
                isRecordingVoiceNote = false
                guard let channel = chatViewModel?.activeChannel else {
                    DebugLogger.shared.log("AUDIO", "Cannot send voice note: no active channel", isError: true)
                    return
                }
                do {
                    try await coordinator.messageService?.sendVoiceNote(
                        audioData: data,
                        duration: duration,
                        to: channel
                    )
                } catch {
                    DebugLogger.shared.log("AUDIO", "Failed to send voice note: \(error)", isError: true)
                }
            } catch {
                DebugLogger.shared.log("AUDIO", "Failed to stop recording: \(error)", isError: true)
                isRecordingVoiceNote = false
            }
            return
        }
        // Start recording
        do {
            try audioService.startRecording(maxDuration: 60)
            isRecordingVoiceNote = true
        } catch {
            DebugLogger.shared.log("AUDIO", "Failed to start recording: \(error)", isError: true)
        }
    }

    // MARK: - Formatting

    private func formattedDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return ChatViewL10n.today
        } else if calendar.isDateInYesterday(date) {
            return ChatViewL10n.yesterday
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

// MARK: - Preview

#Preview("Chat View") {
    NavigationStack {
        ChatView(
            conversation: ConversationPreview.sampleConversations[0]
        )
    }
    .background(GradientBackground())
    .environment(AppCoordinator())
    .environment(\.theme, Theme.shared)
}

#Preview("Chat View - Light") {
    NavigationStack {
        ChatView(
            conversation: ConversationPreview.sampleConversations[0]
        )
    }
    .background(Color.white)
    .environment(AppCoordinator())
    .environment(\.theme, Theme.resolved(for: .light))
    .preferredColorScheme(.light)
}
