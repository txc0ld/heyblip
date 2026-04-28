import SwiftUI
import SwiftData

private enum ChatListL10n {
    static let searchPrompt = String(localized: "chat.list.search.prompt", defaultValue: "Search conversations")
    static let searchMessages = String(localized: "chat.list.search_messages", defaultValue: "Search messages")
    static let addFriend = String(localized: "common.add_friend", defaultValue: "Add Friend")
    static let emptyTitle = String(localized: "chat.list.empty.title", defaultValue: "No conversations yet")
    static let emptySubtitle = String(localized: "chat.list.empty.subtitle", defaultValue: "Add a friend to start chatting.")
    static let searchEmptySubtitle = String(localized: "chat.list.empty.search_subtitle", defaultValue: "Try a different search term.")
    static let newMessage = String(localized: "chat.list.new_message", defaultValue: "New message")
    static let newMessageHint = String(localized: "chat.list.new_message.hint", defaultValue: "Start a direct message or group chat")
    static let menuNewDM = String(localized: "chat.list.new_message.menu.dm", defaultValue: "New Direct Message")
    static let menuNewGroup = String(localized: "chat.list.new_message.menu.group", defaultValue: "New Group Chat")
    static let newMessageTitle = String(localized: "chat.list.new_message.title", defaultValue: "New Message")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let noFriendsTitle = String(localized: "chat.list.new_message.empty.title", defaultValue: "No friends ready to message")
    static let noFriendsSubtitle = String(localized: "chat.list.new_message.empty.subtitle", defaultValue: "Accept a friend request first, then start the chat from here.")
    static let manageFriends = String(localized: "chat.list.new_message.manage_friends", defaultValue: "Manage Friends")
    static let errorTitle = String(localized: "common.error.title", defaultValue: "Something went wrong")
    static let retry = String(localized: "common.retry", defaultValue: "Retry")
    static let fallbackFriendName = String(localized: "chat.list.friend.fallback_name", defaultValue: "Friend")
    static let fallbackUnknownUsername = String(localized: "chat.list.friend.fallback_username", defaultValue: "unknown")
    static let fallbackConversationName = String(localized: "chat.list.conversation.fallback_name", defaultValue: "Chat")
    static let title = String(localized: "chat.list.title", defaultValue: "Chats")

    static func noResults(_ query: String) -> String {
        String(format: String(localized: "chat.list.empty.search_title", defaultValue: "No results for \"%@\""), locale: Locale.current, query)
    }
}

// MARK: - ChatListView

/// Chat list with NavigationStack, search, sorted by lastActivityAt.
/// Pull-to-refresh, floating action button for new message.
struct ChatListView: View {

    var chatViewModel: ChatViewModel? = nil

    @Query private var friends: [Friend]
    @State private var searchText: String = ""
    @State private var isRefreshing = false
    @State private var showNewMessage = false
    @State private var showNewGroup = false
    @State private var showAddFriend = false
    @State private var showMessageSearch = false
    @State private var selectedConversation: ConversationPreview? = nil
    @Environment(\.theme) private var theme
    @Environment(AppCoordinator.self) private var coordinator

    private var isBluetoothDenied: Bool {
        coordinator.bleService?.isBluetoothDenied ?? false
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Main content
                VStack(spacing: 0) {
                    if isBluetoothDenied {
                        BluetoothPermissionBanner()
                            .padding(.horizontal, BlipSpacing.md)
                            .padding(.top, BlipSpacing.sm)
                    }
                    scrollContent
                }

                // Floating Action Button - New Message (hidden when inbox is empty)
                if !filteredConversations.isEmpty {
                    newMessageFAB
                }
            }
            .navigationTitle(ChatListL10n.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: ChatListL10n.searchPrompt
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMessageSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(theme.typography.footnote)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .accessibilityLabel(ChatListL10n.searchMessages)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFriend = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(theme.typography.footnote)
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .accessibilityLabel(ChatListL10n.addFriend)
                }
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendByUsernameSheet()
            }
            .sheet(isPresented: $showMessageSearch) {
                MessageSearchView(onResultTap: { channelID in
                    if let channel = chatViewModel?.channels.first(where: { $0.id == channelID }) {
                        selectedConversation = makeConversationPreview(for: channel)
                    }
                })
            }
            .sheet(isPresented: $showNewMessage) {
                newMessageSheet
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupChatSheet(
                    chatViewModel: chatViewModel,
                    onCreated: { channel in
                        showNewGroup = false
                        Task { @MainActor in
                            await chatViewModel?.loadChannels()
                            selectedConversation = makeConversationPreview(for: channel)
                        }
                    }
                )
            }
            .navigationDestination(item: $selectedConversation) { conversation in
                ChatView(conversation: conversation, chatViewModel: chatViewModel)
            }
        }
        .tint(Color.blipAccentPurple)
        .task {
            await chatViewModel?.loadChannels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptFriendRequest)) { notification in
            navigateToFriendDM(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveFriendAccept)) { notification in
            navigateToFriendDM(from: notification)
        }
        .onChange(of: coordinator.pendingNotificationNavigation) { _, destination in
            guard case .conversation(let channelID) = destination else { return }
            if let match = conversations.first(where: { $0.id == channelID }) {
                selectedConversation = match
            }
            coordinator.pendingNotificationNavigation = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .channelListDidChange)) { _ in
            Task {
                await chatViewModel?.loadChannels()
            }
        }
        .onChange(of: selectedConversation) { _, newValue in
            coordinator.isInImmersiveView = newValue != nil
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: BlipSpacing.sm) {
                if chatViewModel?.isLoading == true && conversations.isEmpty {
                    chatListShimmer
                } else if let error = chatViewModel?.errorMessage {
                    errorState(error)
                } else if filteredConversations.isEmpty {
                    emptyState
                } else {
                    ForEach(
                        Array(filteredConversations.enumerated()),
                        id: \.element.id
                    ) { index, conversation in
                        ChatListCell(
                            conversation: conversation,
                            index: index,
                            onTap: {
                                selectedConversation = conversation
                            },
                            onToggleMute: {
                                toggleMute(for: conversation)
                            },
                            onTogglePin: {
                                togglePin(for: conversation)
                            },
                            onArchive: {
                                archiveConversation(conversation)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.top, BlipSpacing.sm)
            .padding(.bottom, 100) // Space for FAB and tab bar
        }
        .refreshable {
            await performRefresh()
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            EmptyStateView(
                icon: "bubble.left.and.bubble.right",
                title: ChatListL10n.emptyTitle,
                subtitle: ChatListL10n.emptySubtitle,
                ctaTitle: ChatListL10n.addFriend,
                ctaAction: { showAddFriend = true }
            )
            .staggeredReveal(index: 0)
        } else {
            EmptyStateView(
                icon: "magnifyingglass",
                title: ChatListL10n.noResults(searchText),
                subtitle: ChatListL10n.searchEmptySubtitle
            )
            .staggeredReveal(index: 0)
        }
    }

    // MARK: - New Message FAB

    /// Floating compose button. Tapping opens a Menu that lets the user pick
    /// between a new Direct Message and a new Group Chat — mirrors how any
    /// major chat app (WhatsApp, iMessage, Signal) surfaces the +-menu.
    private var newMessageFAB: some View {
        Menu {
            Button {
                BlipHaptics.lightImpact()
                showNewMessage = true
            } label: {
                Label(ChatListL10n.menuNewDM, systemImage: "person.fill")
            }

            Button {
                BlipHaptics.lightImpact()
                showNewGroup = true
            } label: {
                Label(ChatListL10n.menuNewGroup, systemImage: "person.3.fill")
            }
        } label: {
            Image(systemName: "plus.bubble.fill")
                .font(theme.typography.headline)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(LinearGradient.blipAccent)
                )
                .shadow(color: Color.blipAccentPurple.opacity(0.4), radius: 12, y: 4)
        }
        .padding(.trailing, BlipSpacing.lg)
        .padding(.bottom, BlipSpacing.sm)
        .accessibilityLabel(ChatListL10n.newMessage)
        .accessibilityHint(ChatListL10n.newMessageHint)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - New Message Sheet

    private var newMessageSheet: some View {
        NavigationStack {
            ZStack {
                GradientBackground()
                    .ignoresSafeArea()

                if availableFriends.isEmpty {
                    VStack(spacing: BlipSpacing.lg) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(theme.colors.mutedText)

                        Text(ChatListL10n.noFriendsTitle)
                            .font(theme.typography.headline)
                            .foregroundStyle(theme.colors.text)

                        Text(ChatListL10n.noFriendsSubtitle)
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        NavigationLink {
                            FriendsListView()
                        } label: {
                            HStack(spacing: BlipSpacing.sm) {
                                Image(systemName: "person.2.fill")
                                Text(ChatListL10n.manageFriends)
                            }
                            .font(theme.typography.secondary)
                            .foregroundStyle(.white)
                            .padding(.horizontal, BlipSpacing.md)
                            .padding(.vertical, BlipSpacing.sm)
                            .background(Capsule().fill(LinearGradient.blipAccent))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(BlipSpacing.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: BlipSpacing.sm) {
                            ForEach(availableFriends, id: \.id) { friend in
                                Button {
                                    startConversation(with: friend)
                                } label: {
                                    HStack(spacing: BlipSpacing.md) {
                                        AvatarView(
                                            imageData: friend.user?.avatarThumbnail,
                                            name: friend.user?.resolvedDisplayName ?? friend.user?.username ?? ChatListL10n.fallbackFriendName,
                                            size: BlipSizing.avatarSmall,
                                            ringStyle: .friend,
                                            showOnlineIndicator: friend.lastSeenAt?.timeIntervalSinceNow ?? -.infinity > -300
                                        )

                                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                                            Text(friend.user?.resolvedDisplayName ?? friend.user?.username ?? ChatListL10n.fallbackFriendName)
                                                .font(theme.typography.body)
                                                .foregroundStyle(theme.colors.text)

                                            Text("@\(friend.user?.username ?? ChatListL10n.fallbackUnknownUsername)")
                                                .font(theme.typography.caption)
                                                .foregroundStyle(theme.colors.mutedText)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(theme.typography.caption)
                                            .foregroundStyle(theme.colors.mutedText)
                                    }
                                    .padding(BlipSpacing.md)
                                    .background(
                                        RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(BlipSpacing.md)
                    }
                }
            }
            .navigationTitle(ChatListL10n.newMessageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatListL10n.cancel) {
                        showNewMessage = false
                    }
                    .foregroundStyle(Color.blipAccentPurple)
                }
            }
        }
    }

    // MARK: - Error State

    private func errorState(_ message: String) -> some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
                .frame(height: BlipSpacing.xxl * 2)

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))

            Text(ChatListL10n.errorTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(message)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            GlassButton(ChatListL10n.retry, icon: "arrow.clockwise") {
                Task { await chatViewModel?.loadChannels() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shimmer Loading

    private var chatListShimmer: some View {
        VStack(spacing: BlipSpacing.sm) {
            ForEach(0..<4, id: \.self) { _ in
                GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl, padding: .blipContent) {
                    HStack(spacing: BlipSpacing.md) {
                        ShimmerCircle(size: BlipSizing.avatarSmall)
                        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                            ShimmerRect(width: 120, height: 14)
                            ShimmerRect(width: 200, height: 10)
                        }
                        Spacer()
                        ShimmerRect(width: 40, height: 10)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Map ViewModel channels to ConversationPreview for display.
    private var conversations: [ConversationPreview] {
        guard let vm = chatViewModel else { return [] }
        let groupedChannels = Dictionary(grouping: vm.channels) { channel in
            Self.conversationGroupingKey(for: channel)
        }

        return groupedChannels.values.map { channels in
            makeConversationPreview(for: channels)
        }
    }

    private static func conversationGroupingKey(for channel: Channel) -> String {
        if let dmConversationKey = channel.dmConversationKey {
            return dmConversationKey
        }
        return "channel:\(channel.id.uuidString)"
    }

    private static func preferredConversationChannel(from channels: [Channel]) -> Channel {
        var preferredChannel = channels[0]

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

    /// Resolve the row title and avatar from the current channel state.
    private struct ConversationIdentity {
        let displayName: String
        let avatarData: Data?
    }

    private static func resolveConversationIdentity(for channel: Channel) -> ConversationIdentity {
        if channel.type == .dm, let member = channel.memberships.first?.user {
            let displayName: String
            if let name = channel.name, !name.isEmpty {
                displayName = name
            } else {
                displayName = member.resolvedDisplayName
            }
            return ConversationIdentity(
                displayName: displayName,
                avatarData: member.avatarThumbnail
            )
        }

        if let name = channel.name, !name.isEmpty {
            return ConversationIdentity(displayName: name, avatarData: nil)
        }

        return ConversationIdentity(displayName: ChatListL10n.fallbackConversationName, avatarData: nil)
    }

    private var filteredConversations: [ConversationPreview] {
        let base: [ConversationPreview]
        if searchText.isEmpty {
            base = conversations
        } else {
            let query = searchText.lowercased()
            base = conversations.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.lastMessagePreview.lowercased().contains(query)
            }
        }
        return base.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
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

    private func navigateToFriendDM(from notification: Notification) {
        guard let username = notification.userInfo?["username"] as? String else { return }
        // Find the friend's User and their DM channel
        guard let friend = friends.first(where: { $0.user?.username == username }),
              let user = friend.user else { return }
        Task {
            guard let channel = await chatViewModel?.createDMChannel(with: user) else { return }
            await chatViewModel?.loadChannels()
            await MainActor.run {
                selectedConversation = makeConversationPreview(for: channel)
            }
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        await chatViewModel?.loadChannels()
        isRefreshing = false
    }

    private var availableFriends: [Friend] {
        friends.filter { $0.status == .accepted && $0.user != nil }
    }

    private func startConversation(with friend: Friend) {
        guard let user = friend.user else { return }
        Task {
            guard let channel = await chatViewModel?.createDMChannel(with: user) else { return }
            await chatViewModel?.loadChannels()
            await MainActor.run {
                selectedConversation = makeConversationPreview(for: channel)
                showNewMessage = false
            }
        }
    }

    private func toggleMute(for conversation: ConversationPreview) {
        guard let channels = representedChannels(for: conversation), !channels.isEmpty else {
            return
        }

        for channel in channels {
            if channel.isMuted == conversation.isMuted {
                chatViewModel?.toggleMute(for: channel)
            }
        }

        Task {
            await chatViewModel?.loadChannels()
        }
    }

    private func togglePin(for conversation: ConversationPreview) {
        guard let channels = representedChannels(for: conversation), !channels.isEmpty else {
            return
        }

        for channel in channels {
            if channel.isPinned == conversation.isPinned {
                chatViewModel?.togglePin(for: channel)
            }
        }

        Task {
            await chatViewModel?.loadChannels()
        }
    }

    private func archiveConversation(_ conversation: ConversationPreview) {
        guard let channels = representedChannels(for: conversation), !channels.isEmpty else {
            return
        }

        Task {
            for channel in channels {
                await chatViewModel?.deleteChannel(channel)
            }
            await chatViewModel?.loadChannels()
        }
    }

    private func makeConversationPreview(for channel: Channel) -> ConversationPreview {
        makeConversationPreview(for: [channel])
    }

    private func makeConversationPreview(for channels: [Channel]) -> ConversationPreview {
        let channel = Self.preferredConversationChannel(from: channels)
        let lastMessage = channels
            .flatMap(\.messages)
            .max(by: { $0.createdAt < $1.createdAt })
        let unread = channels.reduce(0) { partialResult, conversationChannel in
            partialResult + (chatViewModel?.unreadCounts[conversationChannel.id] ?? conversationChannel.unreadCount)
        }
        let isPinned = channels.contains(where: \.isPinned)
        let isMuted = channels.contains(where: \.isMuted)
        let timestamp = channels.map(\.lastActivityAt).max() ?? channel.lastActivityAt

        let identity = Self.resolveConversationIdentity(for: channel)

        return ConversationPreview(
            id: channel.id,
            relatedChannelIDs: channels.map(\.id),
            displayName: identity.displayName,
            avatarData: identity.avatarData,
            lastMessagePreview: lastMessage.flatMap {
                String(data: $0.rawPayload, encoding: .utf8)
            } ?? "",
            timestamp: timestamp,
            unreadCount: unread,
            isOnline: false,
            isPinned: isPinned,
            isMuted: isMuted,
            isFromMe: lastMessage?.sender == nil,
            deliveryStatus: lastMessage.map { Self.mapDeliveryStatus($0.status) } ?? .sent,
            ringStyle: channel.isGroup ? .none : .friend,
            messageType: lastMessage.map { $0.type } ?? .text
        )
    }

    private func representedChannels(for conversation: ConversationPreview) -> [Channel]? {
        guard let channels = chatViewModel?.channels else { return nil }
        return channels.filter { conversation.relatedChannelIDs.contains($0.id) }
    }
}

// MARK: - Hashable conformance for navigation

extension ConversationPreview: Hashable {
    static func == (lhs: ConversationPreview, rhs: ConversationPreview) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Preview

#Preview("Chat List") {
    ChatListView()
        .environment(\.theme, Theme.shared)
}

#Preview("Chat List - Light") {
    ChatListView()
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}

#Preview("Chat List - Empty") {
    struct EmptyPreview: View {
        var body: some View {
            NavigationStack {
                ZStack {
                    GradientBackground().ignoresSafeArea()
                    VStack(spacing: BlipSpacing.lg) {
                        Spacer().frame(height: BlipSpacing.xxl * 2)
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text(ChatListL10n.emptyTitle)
                            .font(Theme.shared.typography.headline)
                            .foregroundStyle(.white)
                    }
                }
                .navigationTitle(ChatListL10n.title)
            }
        }
    }
    return EmptyPreview()
}
