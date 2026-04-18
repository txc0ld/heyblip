import SwiftUI
import SwiftData

private enum LostAndFoundL10n {
    static let postErrorTitle = String(localized: "events.lost_found.post_error.title", defaultValue: "Couldn't post update")
    static let ok = String(localized: "common.ok", defaultValue: "OK")
    static let title = String(localized: "events.lost_found.title", defaultValue: "Lost & Found")
    static let publicChannel = String(localized: "events.lost_found.status.public_channel", defaultValue: "Public channel")
    static let connecting = String(localized: "events.lost_found.status.connecting", defaultValue: "Connecting...")
    static let inputPlaceholder = String(localized: "events.lost_found.input.placeholder", defaultValue: "Describe lost or found item...")
    static let inputAccessibilityLabel = String(localized: "events.lost_found.input.accessibility_label", defaultValue: "Message input for lost and found")
    static let postButton = String(localized: "events.lost_found.post_button", defaultValue: "Post")
    static let postButtonAccessibilityLabel = String(localized: "events.lost_found.post_button.accessibility_label", defaultValue: "Post lost and found update")
    static let emptyTitle = String(localized: "events.lost_found.empty.title", defaultValue: "No lost & found posts yet")
    static let joiningTitle = String(localized: "events.lost_found.empty.joining_title", defaultValue: "Joining Lost & Found")
    static let emptySubtitle = String(localized: "events.lost_found.empty.subtitle", defaultValue: "Posts from event staff and attendees will appear here.")
    static let joiningSubtitle = String(localized: "events.lost_found.empty.joining_subtitle", defaultValue: "This event channel is being prepared. Try again in a moment.")
    static let messageServiceUnavailable = String(localized: "events.lost_found.error.message_service_unavailable", defaultValue: "Message service is unavailable.")
    static let channelUnavailable = String(localized: "events.lost_found.error.channel_unavailable", defaultValue: "Lost & Found isn't ready for this event yet.")
    static let you = String(localized: "common.you", defaultValue: "You")
    static let attendee = String(localized: "events.lost_found.sender.attendee", defaultValue: "Attendee")
    static let initialsFallback = String(localized: "events.lost_found.sender.initials_fallback", defaultValue: "LF")
    static let previewEvent = "Sonic Fields"
    static let previewChannel = "Lost & Found"
    static let previewAlex = "Alex K"
    static let previewFoundWallet = "Found a blue wallet near Stage B. Dropping it at the info tent."
    static let previewLostPhoneCase = "Lost a purple phone case by the food trucks."
    static let previewUnavailable = "Preview unavailable"

    static func signedPublicPosts(_ eventName: String) -> String {
        String(
            format: String(localized: "events.lost_found.header.subtitle", defaultValue: "Signed public posts for %@."),
            locale: Locale.current,
            eventName
        )
    }
}

// MARK: - LostAndFoundView

/// Live event chat view for the Lost & Found public channel.
struct LostAndFoundView: View {

    let eventID: UUID
    let eventName: String

    @Query private var channels: [Channel]
    @Query private var channelPosts: [Message]

    @State private var inputText = ""
    @State private var isSending = false
    @State private var sendErrorMessage: String?

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isInputFocused: Bool

    init(eventID: UUID, eventName: String) {
        self.eventID = eventID
        self.eventName = eventName

        let channelID = eventID
        _channels = Query(
            filter: #Predicate<Channel> { $0.id == channelID },
            sort: [SortDescriptor(\Channel.lastActivityAt, order: .reverse)]
        )
        _channelPosts = Query(
            filter: #Predicate<Message> { $0.channel?.id == channelID },
            sort: [SortDescriptor(\Message.createdAt, order: .forward)]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBanner
            messageList
            inputBar
        }
        .background(
            colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.3)
        )
        .alert(LostAndFoundL10n.postErrorTitle, isPresented: Binding(
            get: { sendErrorMessage != nil },
            set: { if !$0 { sendErrorMessage = nil } }
        )) {
            Button(LostAndFoundL10n.ok, role: .cancel) {}
        } message: {
            Text(sendErrorMessage ?? "")
        }
    }

    // MARK: - Derived State

    private var channel: Channel? {
        channels.first(where: { $0.type == .lostAndFound }) ?? channels.first
    }

    private var posts: [Message] {
        channelPosts.filter { !$0.isDeleted }
    }

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPostingAvailable: Bool {
        channel != nil && coordinator.messageService != nil
    }

    // MARK: - Header

    private var headerBanner: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)

                Text(LostAndFoundL10n.title)
                    .font(theme.typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text(isPostingAvailable ? LostAndFoundL10n.publicChannel : LostAndFoundL10n.connecting)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xs)
                    .background(Capsule().fill(theme.colors.hover))
            }

            Text(LostAndFoundL10n.signedPublicPosts(eventName))
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: BlipSpacing.sm) {
                    if posts.isEmpty {
                        emptyState
                    } else {
                        ForEach(posts) { post in
                            LostFoundMessageBubble(
                                message: post,
                                senderName: senderName(for: post),
                                senderInitials: senderInitials(for: post),
                                isOwn: isOwn(post)
                            )
                            .id(post.id)
                        }
                    }
                }
                .padding(BlipSpacing.md)
            }
            .onChange(of: posts.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: BlipSpacing.sm) {
            TextField(LostAndFoundL10n.inputPlaceholder, text: $inputText, axis: .vertical)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(BlipSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .stroke(
                            colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08),
                            lineWidth: BlipSizing.hairline
                        )
                )
                .submitLabel(.send)
                .onSubmit { sendMessage() }
                .accessibilityLabel(LostAndFoundL10n.inputAccessibilityLabel)
                .disabled(!isPostingAvailable || isSending)

            GlassButton(LostAndFoundL10n.postButton, icon: "paperplane.fill", size: .small, isLoading: isSending) {
                sendMessage()
            }
            .disabled(!isPostingAvailable || trimmedInput.isEmpty || isSending)
            .accessibilityLabel(LostAndFoundL10n.postButtonAccessibilityLabel)
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: isPostingAvailable ? "tray" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.colors.mutedText)

                Text(isPostingAvailable ? LostAndFoundL10n.emptyTitle : LostAndFoundL10n.joiningTitle)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)

                Text(
                    isPostingAvailable
                        ? LostAndFoundL10n.emptySubtitle
                        : LostAndFoundL10n.joiningSubtitle
                )
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.lg)
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !trimmedInput.isEmpty else { return }
        guard let messageService = coordinator.messageService else {
            sendErrorMessage = LostAndFoundL10n.messageServiceUnavailable
            return
        }
        guard let channel else {
            sendErrorMessage = LostAndFoundL10n.channelUnavailable
            return
        }

        let postText = trimmedInput
        isSending = true

        Task { @MainActor in
            do {
                _ = try await messageService.sendPublicChannelTextMessage(content: postText, to: channel)
                inputText = ""
            } catch {
                DebugLogger.shared.log("EVENT", "Failed to post Lost & Found update: \(error)", isError: true)
                sendErrorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func isOwn(_ message: Message) -> Bool {
        guard let identity = coordinator.identity else {
            return message.sender == nil && message.status != .delivered
        }

        guard let sender = message.sender else {
            return message.status != .delivered
        }

        return sender.noisePublicKey == identity.noisePublicKey.rawRepresentation
    }

    private func senderName(for message: Message) -> String {
        isOwn(message) ? LostAndFoundL10n.you : (message.sender?.resolvedDisplayName ?? LostAndFoundL10n.attendee)
    }

    private func senderInitials(for message: Message) -> String {
        let components = senderName(for: message)
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)

        let initials = String(components).uppercased()
        return initials.isEmpty ? LostAndFoundL10n.initialsFallback : initials
    }
}

// MARK: - LostFoundMessageBubble

private struct LostFoundMessageBubble: View {

    let message: Message
    let senderName: String
    let senderInitials: String
    let isOwn: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: BlipSpacing.sm) {
            if !isOwn {
                Circle()
                    .fill(LinearGradient.blipAccent.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(senderInitials)
                            .font(theme.typography.captionSmall)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    )
            }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: BlipSpacing.xs) {
                if !isOwn {
                    Text(senderName)
                        .font(theme.typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.blipAccentPurple)
                }

                Text(messageText)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .padding(BlipSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                            .fill(
                                isOwn
                                    ? .blipAccentPurple.opacity(0.15)
                                    : (colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                            .stroke(
                                colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06),
                                lineWidth: BlipSizing.hairline
                            )
                    )

                Text(message.createdAt, style: .time)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.6))
            }

            if isOwn {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(senderName): \(messageText)")
    }

    private var messageText: String {
        String(data: message.rawPayload, encoding: .utf8) ?? String(localized: "lost_and_found.unreadable_message", defaultValue: "[Unable to display message]")
    }
}

// MARK: - Preview

@MainActor
private func makeLostAndFoundPreview() -> (container: ModelContainer, eventID: UUID)? {
    do {
        let container = try BlipSchema.createPreviewContainer()
        let context = ModelContext(container)
        let eventID = UUID()
        let event = Event(
            id: eventID,
            name: LostAndFoundL10n.previewEvent,
            coordinates: GeoPoint(latitude: -31.9523, longitude: 115.8613),
            radiusMeters: 3_000,
            startDate: .now.addingTimeInterval(-3_600),
            endDate: .now.addingTimeInterval(28_800),
            organizerSigningKey: Data(repeating: 1, count: 32)
        )
        let channel = Channel(
            id: eventID,
            type: .lostAndFound,
            name: LostAndFoundL10n.previewChannel,
            event: event,
            maxRetention: 28_800,
            isAutoJoined: true
        )
        let remoteUser = User(
            username: "alexk",
            displayName: LostAndFoundL10n.previewAlex,
            emailHash: "",
            noisePublicKey: Data(repeating: 2, count: 32),
            signingPublicKey: Data(repeating: 3, count: 32)
        )
        let localUser = User(
            username: "you",
            displayName: "You",
            emailHash: "",
            noisePublicKey: Data(repeating: 4, count: 32),
            signingPublicKey: Data(repeating: 5, count: 32)
        )
        let foundMessage = Message(
            sender: remoteUser,
            channel: channel,
            type: .text,
            rawPayload: Data(LostAndFoundL10n.previewFoundWallet.utf8),
            status: .delivered,
            createdAt: .now.addingTimeInterval(-1_200)
        )
        let lostMessage = Message(
            sender: localUser,
            channel: channel,
            type: .text,
            rawPayload: Data(LostAndFoundL10n.previewLostPhoneCase.utf8),
            status: .sent,
            createdAt: .now.addingTimeInterval(-300)
        )

        context.insert(event)
        context.insert(channel)
        context.insert(remoteUser)
        context.insert(localUser)
        context.insert(foundMessage)
        context.insert(lostMessage)
        try context.save()
        return (container, eventID)
    } catch {
        DebugLogger.shared.log("EVENT", "Lost & Found preview unavailable: \(error)", isError: true)
        return nil
    }
}

#Preview("Lost & Found") {
    if let preview = makeLostAndFoundPreview() {
        ZStack {
            GradientBackground()
            LostAndFoundView(eventID: preview.eventID, eventName: LostAndFoundL10n.previewEvent)
        }
        .frame(height: 500)
        .preferredColorScheme(.dark)
        .blipTheme()
        .modelContainer(preview.container)
        .environment(AppCoordinator())
    } else {
        Text(LostAndFoundL10n.previewUnavailable)
            .blipTheme()
    }
}
