import SwiftUI
import SwiftData

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

                    Text("Recording...")
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
                    Task { await sendMessage(text: trimmedText) }
                },
                onAttachment: {
                    // Attachment handling
                },
                onPTTStart: {
                    isPTTRecording = true
                    pttAudioLevels = []
                },
                onPTTEnd: {
                    isPTTRecording = false
                    pttAudioLevels = []
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
        .fullScreenCover(isPresented: $showImageViewer) {
            ImageViewer(imageData: selectedImageData, isPresented: $showImageViewer)
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
                Text(conversation.displayName)
                    .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                    .foregroundStyle(theme.colors.text)

                Text(conversation.isOnline ? "Online" : "Last seen recently")
                    .font(.custom(BlipFontName.regular, size: 12, relativeTo: .caption2))
                    .foregroundStyle(
                        conversation.isOnline
                            ? theme.colors.statusGreen
                            : theme.colors.mutedText
                    )
            }
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
                            MessageBubble(
                                message: message,
                                index: messageIndex,
                                onReply: {
                                    // Reply handling
                                },
                                onImageTap: {
                                    selectedImageData = message.imageData
                                    showImageViewer = true
                                }
                            )
                            .id(message.id)
                        }
                    }

                    // Anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, BlipSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(SpringConstants.accessibleMessage) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
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
                senderName: message.sender?.resolvedDisplayName ?? "Unknown",
                senderAvatarData: message.sender?.avatarThumbnail,
                isFromMe: message.sender == nil,
                showSenderName: conversation.ringStyle == .none,
                text: String(data: message.encryptedPayload, encoding: .utf8) ?? "",
                contentType: message.type,
                deliveryStatus: Self.mapDeliveryStatus(message.status),
                timestamp: message.createdAt,
                isEdited: false,
                replyPreview: message.replyTo.flatMap {
                    String(data: $0.encryptedPayload, encoding: .utf8)
                },
                imageData: message.attachments.first?.fullData ?? message.attachments.first?.thumbnail,
                voiceNoteDuration: nil,
                waveformSamples: []
            )
        }
    }

    private static func mapDeliveryStatus(_ status: MessageStatus) -> StatusBadge.DeliveryStatus {
        switch status {
        case .composing: return .composing
        case .queued: return .queued
        case .encrypting: return .encrypting
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

    // MARK: - Formatting

    private func formattedDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = .current
            return formatter.string(from: date)
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
