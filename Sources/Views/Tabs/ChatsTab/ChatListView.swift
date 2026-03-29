import SwiftUI
import SwiftData

// MARK: - ChatListView

/// Chat list with NavigationStack, search, sorted by lastActivityAt.
/// Pull-to-refresh, floating action button for new message.
struct ChatListView: View {

    @State private var searchText: String = ""
    @State private var isRefreshing = false
    @State private var showNewMessage = false
    @State private var selectedConversation: ConversationPreview? = nil
    @State private var chatViewModel: ChatViewModel?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Main content
                scrollContent

                // Floating Action Button - New Message
                newMessageFAB
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search conversations"
            )
            .sheet(isPresented: $showNewMessage) {
                newMessageSheet
            }
            .navigationDestination(item: $selectedConversation) { conversation in
                ChatView(conversation: conversation, chatViewModel: chatViewModel)
            }
        }
        .tint(Color.fcAccentPurple)
        .task {
            if chatViewModel == nil {
                let container = modelContext.container
                let messageService = MessageService(modelContainer: container)
                chatViewModel = ChatViewModel(
                    modelContainer: container,
                    messageService: messageService
                )
            }
            await chatViewModel?.loadChannels()
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: FCSpacing.sm) {
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
                            index: index
                        ) {
                            selectedConversation = conversation
                        }
                    }
                }
            }
            .padding(.horizontal, FCSpacing.md)
            .padding(.top, FCSpacing.sm)
            .padding(.bottom, 100) // Space for FAB and tab bar
        }
        .refreshable {
            await performRefresh()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: FCSpacing.lg) {
            Spacer()
                .frame(height: FCSpacing.xxl * 2)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))

            if searchText.isEmpty {
                Text("No conversations yet")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text("Start chatting with people nearby\nor add friends to get started.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)

                GlassButton("New Message", icon: "plus.bubble.fill") {
                    showNewMessage = true
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
                        .fill(LinearGradient.fcAccent)
                )
                .shadow(color: Color.fcAccentPurple.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, FCSpacing.lg)
        .padding(.bottom, FCSpacing.sm)
        .accessibilityLabel("New message")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - New Message Sheet

    private var newMessageSheet: some View {
        NavigationStack {
            ZStack {
                GradientBackground()
                    .ignoresSafeArea()

                VStack(spacing: FCSpacing.lg) {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.fcAccentPurple)

                    Text("New Message")
                        .font(theme.typography.headline)
                        .foregroundStyle(theme.colors.text)

                    Text("Select a friend or nearby person to start chatting.")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.center)
                }
                .padding(FCSpacing.xl)
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showNewMessage = false
                    }
                    .foregroundStyle(Color.fcAccentPurple)
                }
            }
        }
    }

    // MARK: - Error State

    private func errorState(_ message: String) -> some View {
        VStack(spacing: FCSpacing.lg) {
            Spacer()
                .frame(height: FCSpacing.xxl * 2)

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
        VStack(spacing: FCSpacing.sm) {
            ForEach(0..<4, id: \.self) { _ in
                GlassCard(thickness: .regular, cornerRadius: FCCornerRadius.xl, padding: .fcContent) {
                    HStack(spacing: FCSpacing.md) {
                        ShimmerCircle(size: FCSizing.avatarSmall)
                        VStack(alignment: .leading, spacing: FCSpacing.sm) {
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
                displayName: channel.name ?? "Chat",
                avatarData: nil,
                lastMessagePreview: lastMessage.flatMap {
                    String(data: $0.encryptedPayload, encoding: .utf8)
                } ?? "",
                timestamp: channel.lastActivityAt,
                unreadCount: unread,
                isOnline: false,
                isPinned: false,
                isMuted: channel.isMuted,
                isFromMe: lastMessage?.sender == nil,
                deliveryStatus: lastMessage.map { Self.mapDeliveryStatus($0.status) } ?? .sent,
                ringStyle: channel.isGroup ? .none : .friend,
                messageType: lastMessage.map { $0.type } ?? .text
            )
        }
    }

    private var filteredConversations: [ConversationPreview] {
        if searchText.isEmpty {
            return conversations.sorted { $0.timestamp > $1.timestamp }
        }
        let query = searchText.lowercased()
        return conversations
            .filter {
                $0.displayName.lowercased().contains(query) ||
                $0.lastMessagePreview.lowercased().contains(query)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private static func mapDeliveryStatus(_ status: MessageStatus) -> StatusBadge.DeliveryStatus {
        switch status {
        case .composing: return .composing
        case .queued: return .queued
        case .sent: return .sent
        case .delivered: return .delivered
        case .read: return .read
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        await chatViewModel?.loadChannels()
        isRefreshing = false
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
                    VStack(spacing: FCSpacing.lg) {
                        Spacer().frame(height: FCSpacing.xxl * 2)
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
