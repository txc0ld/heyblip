import SwiftUI
import SwiftData

// MARK: - ChatListView

/// Chat list with NavigationStack, search, sorted by lastActivityAt.
/// Pull-to-refresh, floating action button for new message.
/// Toggle between Chats (existing conversations) and Friends (all accepted friends).
struct ChatListView: View {

    enum ChatListMode: String, CaseIterable {
        case chats = "Chats"
        case friends = "Friends"
    }

    var chatViewModel: ChatViewModel? = nil

    @Query private var friends: [Friend]
    @State private var searchText: String = ""
    @State private var isRefreshing = false
    @State private var showNewMessage = false
    @State private var showAddFriend = false
    @State private var showMessageSearch = false
    @State private var selectedConversation: ConversationPreview? = nil
    @State private var listMode: ChatListMode = .chats
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
                    modeToggle
                    if listMode == .chats {
                        scrollContent
                    } else {
                        ScrollView {
                            ChatFriendsListView(
                                chatViewModel: chatViewModel,
                                onStartConversation: { friend in
                                    startConversation(with: friend)
                                }
                            )
                        }
                        .refreshable {
                            await performRefresh()
                        }
                    }
                }

                // Floating Action Button - New Message (hidden when inbox is empty or in Friends mode)
                if listMode == .chats && !filteredConversations.isEmpty {
                    newMessageFAB
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search conversations"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMessageSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .accessibilityLabel("Search messages")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFriend = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.blipAccentPurple)
                    }
                    .accessibilityLabel("Add friend")
                }
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendByUsernameSheet()
            }
            .sheet(isPresented: $showMessageSearch) {
                MessageSearchView()
            }
            .sheet(isPresented: $showNewMessage) {
                newMessageSheet
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
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: BlipSpacing.xs) {
            ForEach(ChatListMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(SpringConstants.accessiblePageEntrance) {
                        listMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(theme.typography.body)
                        .fontWeight(listMode == mode ? .semibold : .regular)
                        .foregroundStyle(listMode == mode ? .white : theme.colors.text)
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(
                            listMode == mode
                                ? AnyShapeStyle(.blipAccentPurple)
                                : AnyShapeStyle(.ultraThinMaterial)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(listMode == mode ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
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

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
                .frame(height: BlipSpacing.xxl * 2)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))

            if searchText.isEmpty {
                Text("No conversations yet")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text("Add a friend to start chatting.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)

                GlassButton("Add Friend", icon: "person.badge.plus") {
                    showAddFriend = true
                }
            } else {
                Text("No results for \"\(searchText)\"")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text("Try a different search term.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
        .frame(maxWidth: .infinity)
        .staggeredReveal(index: 0)
    }

    // MARK: - New Message FAB

    private var newMessageFAB: some View {
        Button {
            showNewMessage = true
        } label: {
            Image(systemName: "plus.bubble.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(LinearGradient.blipAccent)
                )
                .shadow(color: Color.blipAccentPurple.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, BlipSpacing.lg)
        .padding(.bottom, BlipSpacing.sm)
        .accessibilityLabel("New message")
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

                        Text("No friends ready to message")
                            .font(theme.typography.headline)
                            .foregroundStyle(theme.colors.text)

                        Text("Accept a friend request first, then start the chat from here.")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                            .multilineTextAlignment(.center)

                        NavigationLink {
                            FriendsListView()
                        } label: {
                            HStack(spacing: BlipSpacing.sm) {
                                Image(systemName: "person.2.fill")
                                Text("Manage Friends")
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
                                            name: friend.user?.resolvedDisplayName ?? friend.user?.username ?? "Friend",
                                            size: BlipSizing.avatarSmall,
                                            ringStyle: .friend,
                                            showOnlineIndicator: friend.lastSeenAt?.timeIntervalSinceNow ?? -.infinity > -300
                                        )

                                        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                                            Text(friend.user?.resolvedDisplayName ?? friend.user?.username ?? "Friend")
                                                .font(theme.typography.body)
                                                .foregroundStyle(theme.colors.text)

                                            Text("@\(friend.user?.username ?? "unknown")")
                                                .font(theme.typography.caption)
                                                .foregroundStyle(theme.colors.mutedText)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
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
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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

            Text("Something went wrong")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(message)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            GlassButton("Retry", icon: "arrow.clockwise") {
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
        return vm.channels.map { channel in
            let lastMessage = channel.messages
                .sorted(by: { $0.createdAt < $1.createdAt })
                .last
            let unread = vm.unreadCounts[channel.id] ?? 0

            return ConversationPreview(
                id: channel.id,
                displayName: Self.resolveDisplayName(for: channel),
                avatarData: nil,
                lastMessagePreview: lastMessage.flatMap {
                    String(data: $0.encryptedPayload, encoding: .utf8)
                } ?? "",
                timestamp: channel.lastActivityAt,
                unreadCount: unread,
                isOnline: false,
                isPinned: channel.isPinned,
                isMuted: channel.isMuted,
                isFromMe: lastMessage?.sender == nil,
                deliveryStatus: lastMessage.map { Self.mapDeliveryStatus($0.status) } ?? .sent,
                ringStyle: channel.isGroup ? .none : .friend,
                messageType: lastMessage.map { $0.type } ?? .text
            )
        }
    }

    /// Resolve a display name for the channel, falling back to the first member's name for DMs.
    private static func resolveDisplayName(for channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty {
            return name
        }
        if channel.type == .dm, let member = channel.memberships.first?.user {
            return member.resolvedDisplayName
        }
        return "Chat"
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
                listMode = .chats
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
        guard let channel = chatViewModel?.channels.first(where: { $0.id == conversation.id }) else {
            return
        }

        chatViewModel?.toggleMute(for: channel)

        Task {
            await chatViewModel?.loadChannels()
        }
    }

    private func togglePin(for conversation: ConversationPreview) {
        guard let channel = chatViewModel?.channels.first(where: { $0.id == conversation.id }) else {
            return
        }

        chatViewModel?.togglePin(for: channel)

        Task {
            await chatViewModel?.loadChannels()
        }
    }

    private func archiveConversation(_ conversation: ConversationPreview) {
        guard let channel = chatViewModel?.channels.first(where: { $0.id == conversation.id }) else {
            return
        }

        Task {
            await chatViewModel?.deleteChannel(channel)
            await chatViewModel?.loadChannels()
        }
    }

    private func makeConversationPreview(for channel: Channel) -> ConversationPreview {
        let lastMessage = channel.messages.sorted(by: { $0.createdAt < $1.createdAt }).last
        let unread = chatViewModel?.unreadCounts[channel.id] ?? 0

        return ConversationPreview(
            id: channel.id,
            displayName: Self.resolveDisplayName(for: channel),
            avatarData: nil,
            lastMessagePreview: lastMessage.flatMap {
                String(data: $0.encryptedPayload, encoding: .utf8)
            } ?? "",
            timestamp: channel.lastActivityAt,
            unreadCount: unread,
            isOnline: false,
            isPinned: channel.isPinned,
            isMuted: channel.isMuted,
            isFromMe: lastMessage?.sender == nil,
            deliveryStatus: lastMessage.map { Self.mapDeliveryStatus($0.status) } ?? .sent,
            ringStyle: channel.isGroup ? .none : .friend,
            messageType: lastMessage.map { $0.type } ?? .text
        )
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
                        Text("No conversations yet")
                            .font(Theme.shared.typography.headline)
                            .foregroundStyle(.white)
                    }
                }
                .navigationTitle("Chats")
            }
        }
    }
    return EmptyPreview()
}
