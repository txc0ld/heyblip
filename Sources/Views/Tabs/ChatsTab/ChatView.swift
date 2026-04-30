import SwiftUI
import SwiftData
import PhotosUI
import BlipProtocol

private enum ChatViewL10n {
    static let recording = String(localized: "chat.recording.label", defaultValue: "Recording...")
    static let unknown = String(localized: "common.unknown", defaultValue: "Unknown")
    static let recordingVoiceNote = String(localized: "chat.recording.voice_note", defaultValue: "Recording voice note")
    static let stopAndSend = String(localized: "chat.recording.stop_and_send", defaultValue: "Stop & Send")
    static let cancelRecording = String(localized: "chat.recording.cancel", defaultValue: "Cancel")
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

    static let meshAccessibility = String(localized: "chat.transport.ble.accessibility", defaultValue: "Messages via Bluetooth mesh")
    static let relayAccessibility = String(localized: "chat.transport.relay.accessibility", defaultValue: "Messages via internet relay")
    static let bothTransportsAccessibility = String(localized: "chat.transport.both.accessibility", defaultValue: "Messages via Bluetooth mesh and internet relay")
    static let offlineTransportAccessibility = String(localized: "chat.transport.offline.accessibility", defaultValue: "No transport available")
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
    @State private var justSentMessage = false
    @State private var lastTypingIndicatorSent = Date.distantPast
    @State private var showPTTUnavailableToast = false
    @State private var showGroupInfo = false
    @State private var isComposerFocused = false

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

            // Voice note recording overlay — visible to the user so they know
            // recording is active and can stop/cancel. Without this the record
            // state was invisible, leaving users stranded with no way to send.
            if isRecordingVoiceNote {
                voiceNoteRecordingOverlay
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // PTT waveform overlay
            if isPTTRecording {
                HStack(spacing: BlipSpacing.sm) {
                    Circle()
                        .fill(theme.colors.statusRed)
                        .frame(width: 8, height: 8)

                    WaveformView(
                        levels: pttWaveformLevels,
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ChatViewL10n.recordingVoiceNote)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Message input (pinned at bottom)
            MessageInput(
                text: Binding(
                    get: { chatViewModel?.composingText ?? messageText },
                    set: { newValue in
                        if chatViewModel != nil {
                            chatViewModel?.composingText = newValue
                            if Date().timeIntervalSince(lastTypingIndicatorSent) > 2.0 {
                                chatViewModel?.sendTypingIndicator()
                                lastTypingIndicatorSent = Date()
                            }
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
                    guard isRelayAvailable else {
                        showPTTUnavailableToast = true
                        return
                    }
                    if let pttVM = coordinator.pttViewModel,
                       let channel = chatViewModel?.activeChannel {
                        pttVM.configure(channel: channel, crowdScale: .gather)
                        pttVM.startRecording()
                    }
                    isPTTRecording = true
                    pttAudioLevels = []
                },
                onPTTEnd: {
                    coordinator.pttViewModel?.stopRecording()
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
                },
                isRelayAvailable: isRelayAvailable,
                onFocusChange: { focused in
                    isComposerFocused = focused
                    if focused {
                        withAnimation(SpringConstants.accessibleMessage) {
                            scrollProxy?.scrollTo("bottom", anchor: .bottom)
                        }
                        unseenMessageCount = 0
                    }
                }
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationTitleView
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showGroupInfo) {
            if let channel = chatViewModel?.activeChannel, channel.isGroup {
                GroupInfoView(channel: channel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
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
        .overlay(alignment: .bottom) {
            if showPTTUnavailableToast {
                Text("Voice notes need internet — you're on mesh only")
                    .font(theme.typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.vertical, BlipSpacing.sm)
                    .background(Capsule().fill(theme.colors.mutedText))
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            do {
                                try await Task.sleep(for: .seconds(2))
                            } catch {
                                return
                            }
                            withAnimation(SpringConstants.gentleAnimation) {
                                showPTTUnavailableToast = false
                            }
                        }
                    }
            }
        }
        .animation(SpringConstants.gentleAnimation, value: showPTTUnavailableToast)
        .animation(SpringConstants.gentleAnimation, value: isRecordingVoiceNote)
        .task {
            await loadConversation()
        }
        .onChange(of: coordinator.pttViewModel?.audioLevel) { _, newLevel in
            guard isPTTRecording, let level = newLevel else { return }
            pttAudioLevels.append(level)
            // Keep a rolling window of 16 samples for the waveform
            if pttAudioLevels.count > 16 {
                pttAudioLevels.removeFirst(pttAudioLevels.count - 16)
            }
        }
        .onDisappear {
            chatViewModel?.clearTransientConversationState()
        }
    }

    // MARK: - Relay Availability (PTT)

    /// Whether the WebSocket relay is connected. PTT voice notes are too large for BLE
    /// fragmentation, so they always route through the relay.
    private var isRelayAvailable: Bool {
        coordinator.meshViewModel?.isWebSocketConnected ?? false
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

    /// Computes transport availability for this specific conversation.
    /// Prefers direct peer reachability for DMs and falls back to recent message transport evidence.
    private var conversationTransportState: (mesh: Bool, relay: Bool) {
        let recentMessages = messages.suffix(20)
        let hasRecentMesh = recentMessages.contains { !$0.isRelayed }
        let hasRecentRelay = recentMessages.contains(where: { $0.isRelayed })

        guard
            let channel = chatViewModel?.activeChannel,
            channel.type == .dm
        else {
            return (hasRecentMesh, hasRecentRelay)
        }

        let localNoiseKey = coordinator.identity?.noisePublicKey.rawRepresentation
        let remoteUser = channel.memberships.compactMap(\.user).first { user in
            guard !user.noisePublicKey.isEmpty else { return false }
            if let localNoiseKey {
                return user.noisePublicKey != localNoiseKey
            }
            return true
        }

        guard let remoteUser else {
            return (hasRecentMesh, hasRecentRelay)
        }

        let peerIDBytes: Data
        if let peer = coordinator.peerStore.peer(byNoisePublicKey: remoteUser.noisePublicKey) {
            peerIDBytes = peer.peerID
        } else if remoteUser.noisePublicKey.count == PeerID.length {
            peerIDBytes = remoteUser.noisePublicKey
        } else {
            peerIDBytes = PeerID(noisePublicKey: remoteUser.noisePublicKey).bytes
        }

        let isNearbyViaMesh = coordinator.meshViewModel?.nearbyPeers.contains(where: {
            $0.isDirectPeer && $0.peerID == peerIDBytes
        }) ?? false

        let relayConnected = coordinator.messageService?.transportAvailabilitySnapshot()?.webSocket ?? hasRecentRelay
        let meshAvailable = isNearbyViaMesh || hasRecentMesh
        let relayAvailable = hasRecentRelay || (!isNearbyViaMesh && relayConnected)

        return (meshAvailable, relayAvailable)
    }

    // MARK: - Navigation Title

    private var navigationTitleView: some View {
        let isGroup = chatViewModel?.activeChannel?.isGroup ?? false
        return Button {
            guard isGroup else { return }
            showGroupInfo = true
        } label: {
            navigationTitleContent
        }
        .buttonStyle(.plain)
        .disabled(!isGroup)
        .accessibilityLabel(isGroup
            ? "\(conversation.displayName), tap to view members"
            : conversation.displayName)
    }

    private var navigationTitleContent: some View {
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
                            .font(theme.typography.caption2)
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
        let state = conversationTransportState
        let meshAvailable = state.mesh
        let relayAvailable = state.relay

        if meshAvailable || relayAvailable {
            HStack(spacing: 3) {
                Text("\u{00B7}")
                    .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                    .foregroundStyle(theme.colors.mutedText)

                if meshAvailable {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(theme.typography.micro)
                        .foregroundStyle(Color.blipAccentPurple)
                }

                if meshAvailable && relayAvailable {
                    Text("+")
                        .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                        .foregroundStyle(theme.colors.mutedText)
                }

                if relayAvailable {
                    Image(systemName: "cloud.fill")
                        .font(theme.typography.micro)
                        .foregroundStyle(Color.blipAccentPurple)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transportAccessibilityLabel)
            .transition(
                SpringConstants.isReduceMotionEnabled
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.9))
            )
            .animation(SpringConstants.gentleAnimation, value: meshAvailable)
            .animation(SpringConstants.gentleAnimation, value: relayAvailable)
        }
    }

    /// Accessibility label for the transport indicator.
    private var transportAccessibilityLabel: String {
        let state = conversationTransportState
        let meshAvailable = state.mesh
        let relayAvailable = state.relay

        switch (meshAvailable, relayAvailable) {
        case (true, true):
            return ChatViewL10n.bothTransportsAccessibility
        case (true, false):
            return ChatViewL10n.meshAccessibility
        case (false, true):
            return ChatViewL10n.relayAccessibility
        case (false, false):
            return ChatViewL10n.offlineTransportAccessibility
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: BlipSpacing.xs) {
                    // Date headers + messages with iMessage-style cluster
                    // separators (time chip between messages that are more
                    // than `timeClusterThreshold` apart within the same day).
                    ForEach(Array(groupedMessages.enumerated()), id: \.offset) { sectionIndex, section in
                        dateHeader(for: section.date)
                            .id("header-\(sectionIndex)")

                        ForEach(Array(section.messages.enumerated()), id: \.element.id) { messageIndex, message in
                            if messageIndex > 0,
                               Self.shouldInsertTimeSeparator(
                                   before: message,
                                   previous: section.messages[messageIndex - 1]
                               ) {
                                timeClusterSeparator(for: message.timestamp)
                            }
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
                // Pin to the latest message when the user is actively composing
                // — without this, opening the keyboard shifts the bottom anchor
                // off-screen and incoming messages stay hidden behind the
                // composer. The composer-focused user expects the latest line
                // to stay visible.
                if isNearBottom || justSentMessage || isComposerFocused {
                    withAnimation(SpringConstants.accessibleMessage) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    justSentMessage = false
                    if isComposerFocused {
                        unseenMessageCount = 0
                    }
                } else {
                    let newMessages = newCount - oldCount
                    if newMessages > 0 {
                        unseenMessageCount += newMessages
                    }
                }
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                withAnimation(SpringConstants.accessibleMessage) {
                    proxy.scrollTo("bottom", anchor: .bottom)
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
            if !SpringConstants.isReduceMotionEnabled {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
            withAnimation(SpringConstants.accessibleMessage) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
            unseenMessageCount = 0
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(theme.typography.caption)
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
                // Pull the full-resolution attachment from SwiftData on tap so the chat
                // scroll itself only ever holds thumbnails. Falls back to whatever the
                // bubble had (thumbnail) if the persisted message can't be located.
                selectedImageData = imageDataForViewer(messageID: messageID) ?? message.imageData
                showImageViewer = true
            },
            onEdit: { findOriginal(messageID) { chatViewModel?.startEditing($0) } },
            onDelete: { findOriginal(messageID) { showDeleteConfirmation = $0 } },
            onRetry: { findOriginal(messageID) { msg in Task { await chatViewModel?.retryMessage(msg) } } },
            onReact: { emoji in
                findOriginal(messageID) { msg in
                    chatViewModel?.setReaction(emoji, on: msg)
                }
            }
        )
        .id(message.id)
    }

    private func findOriginal(_ id: UUID, action: (Message) -> Void) {
        if let original = chatViewModel?.activeMessages.first(where: { $0.id == id }) {
            action(original)
        }
    }

    /// Return the highest-fidelity image bytes for a message, preferring `fullData`
    /// when present. Used by the viewer presentation path so we only materialise
    /// the full image when the user actually opens it.
    private func imageDataForViewer(messageID: UUID) -> Data? {
        guard let original = chatViewModel?.activeMessages.first(where: { $0.id == messageID }) else {
            return nil
        }
        let attachment = original.attachments.first(where: { $0.type == .image })
            ?? original.attachments.first
        return attachment?.fullData ?? attachment?.thumbnail
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

    // MARK: - Time Cluster Separator

    /// Threshold for inserting a time separator between two messages within
    /// the same day. WhatsApp uses roughly 15 minutes; feels right for an
    /// event app too where bursts of activity alternate with quiet gaps.
    private static let timeClusterThreshold: TimeInterval = 15 * 60

    /// Decide whether a time chip should be emitted above `message` given the
    /// previous message in the same date section.
    private static func shouldInsertTimeSeparator(
        before message: ChatMessage,
        previous: ChatMessage
    ) -> Bool {
        message.timestamp.timeIntervalSince(previous.timestamp) >= timeClusterThreshold
    }

    /// Small centered time label used between message clusters. Deliberately
    /// unobtrusive so it fades into the background on scan reading.
    private func timeClusterSeparator(for date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.custom(BlipFontName.regular, size: 11, relativeTo: .caption2))
            .foregroundStyle(theme.colors.mutedText.opacity(0.7))
            .padding(.top, BlipSpacing.sm)
            .padding(.bottom, BlipSpacing.xs)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true) // Inline bubble time covers this
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

    // MARK: - Voice Note Recording Overlay

    /// Visible recording indicator shown while a voice note is being recorded.
    /// Exposes "Stop & Send" and "Cancel" actions so the user knows recording
    /// is active and has a clear path to finish. Before this overlay existed the
    /// recording state was invisible — users had no idea the mic was live and no
    /// way to trigger the send, producing zero [AUDIO]/[TX] events in field logs.
    private var voiceNoteRecordingOverlay: some View {
        HStack(spacing: BlipSpacing.md) {
            // Pulsing red dot
            Circle()
                .fill(theme.colors.statusRed)
                .frame(width: 8, height: 8)

            Text(ChatViewL10n.recordingVoiceNote)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.text)

            Spacer()

            // Cancel — discard the recording
            Button {
                voiceNoteService.cancelRecording()
                isRecordingVoiceNote = false
                DebugLogger.shared.log("AUDIO", "Voice note recording cancelled by user")
            } label: {
                Text(ChatViewL10n.cancelRecording)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)

            // Stop & Send — commit the recording
            Button {
                Task { await stopAndSendVoiceNote() }
            } label: {
                Text(ChatViewL10n.stopAndSend)
                    .font(.custom(BlipFontName.semiBold, size: 13, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xs)
                    .background(
                        Capsule().fill(Color.blipAccentPurple)
                    )
            }
            .frame(minHeight: BlipSizing.minTapTarget)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ChatViewL10n.recordingVoiceNote)
    }

    // MARK: - PTT Waveform

    /// Builds a 16-sample waveform from accumulated audio levels,
    /// padding with a small baseline when fewer than 16 samples exist.
    private var pttWaveformLevels: [Float] {
        if pttAudioLevels.isEmpty {
            return Array(repeating: Float(0.05), count: 16)
        }
        if pttAudioLevels.count >= 16 {
            return Array(pttAudioLevels.suffix(16))
        }
        let padding = Array(repeating: Float(0.05), count: 16 - pttAudioLevels.count)
        return padding + pttAudioLevels
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
                // Render the lightweight thumbnail in the scroll. Loading every full-res
                // image (often 500KB+) into a long chat scroll inflates memory linearly
                // with history and OOMs on long sessions. The viewer fetches `fullData`
                // on tap via `imageDataForViewer(messageID:)`.
                imageData: message.attachments.first?.thumbnail ?? message.attachments.first?.fullData,
                voiceNoteDuration: message.attachments.first(where: { $0.isAudio })?.duration,
                waveformSamples: [],
                audioData: message.attachments.first(where: { $0.isAudio })?.fullData,
                isRelayed: message.isRelayed,
                reaction: message.reaction
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
        justSentMessage = true
        await vm.sendTextMessage(text: text)
        if let profileVM = coordinator.profileViewModel {
            await profileVM.loadProfile()
        }
    }

    // MARK: - Voice Note

    /// Kick off voice note recording. Shows the recording overlay so the user
    /// knows the mic is live. Stop & Send / Cancel are presented in the overlay
    /// — this function only handles the START path now.
    private func recordAndSendVoiceNote() async {
        guard !isRecordingVoiceNote else {
            // Already recording — the overlay's Stop & Send / Cancel buttons
            // handle the stop path. Nothing to do here.
            return
        }
        do {
            try voiceNoteService.startRecording(maxDuration: 60)
            isRecordingVoiceNote = true
            DebugLogger.shared.log("AUDIO", "Voice note recording started")
        } catch {
            DebugLogger.shared.log("AUDIO", "Failed to start recording: \(error)", isError: true)
        }
    }

    /// Stop the active recording, encode to Opus, and dispatch through ChatViewModel
    /// so the message is persisted, appended to activeMessages, and broadcast via mesh.
    /// Called by the "Stop & Send" button in voiceNoteRecordingOverlay.
    private func stopAndSendVoiceNote() async {
        do {
            let (data, duration) = try voiceNoteService.stopRecording()
            isRecordingVoiceNote = false
            DebugLogger.shared.log("AUDIO", "Voice note recording stopped: \(String(format: "%.1f", duration))s, \(data.count)B encoded")
            guard let vm = chatViewModel else {
                DebugLogger.shared.log("AUDIO", "Cannot send voice note: chatViewModel is nil", isError: true)
                return
            }
            DebugLogger.shared.log("AUDIO", "Sending voice note via chatViewModel")
            await vm.sendVoiceNote(audioData: data, duration: duration)
        } catch {
            DebugLogger.shared.log("AUDIO", "Failed to stop recording: \(error)", isError: true)
            isRecordingVoiceNote = false
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
