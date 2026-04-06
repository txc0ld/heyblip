import SwiftUI
import SwiftData

// MARK: - ChatFriendsListView

/// Friends list embedded in the Chats tab. Shows accepted friends with
/// glassmorphism cards and a "Message" button that navigates directly to
/// the DM conversation.
struct ChatFriendsListView: View {

    var chatViewModel: ChatViewModel?

    @State private var searchText: String = ""
    @State private var showAddFriend = false

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

    /// Set by the parent to navigate to a DM conversation.
    var onStartConversation: ((Friend) -> Void)?

    var body: some View {
        if filteredFriends.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: BlipSpacing.sm) {
                ForEach(Array(filteredFriends.enumerated()), id: \.element.id) { index, friend in
                    friendRow(friend)
                        .staggeredReveal(index: index)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.top, BlipSpacing.sm)
            .padding(.bottom, 100)
        }
    }

    // MARK: - Friend Row

    private func friendRow(_ friend: Friend) -> some View {
        Button {
            onStartConversation?(friend)
        } label: {
            HStack(spacing: BlipSpacing.md) {
                AvatarView(
                    imageData: friend.user?.avatarThumbnail,
                    name: friend.user?.resolvedDisplayName ?? "?",
                    size: BlipSizing.avatarSmall,
                    ringStyle: .friend,
                    showOnlineIndicator: isOnline(friend)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.user?.resolvedDisplayName ?? "Unknown")
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    Text("@\(friend.user?.username ?? "")")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blipAccentPurple)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                            .stroke(theme.colors.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message \(friend.user?.resolvedDisplayName ?? "friend")")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
                .frame(height: BlipSpacing.xxl * 2)

            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText.opacity(0.5))

            Text("No friends yet")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("Add friends to start messaging.\nThey'll appear here once they accept.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            GlassButton("Add Friend", icon: "person.badge.plus") {
                showAddFriend = true
            }
        }
        .frame(maxWidth: .infinity)
        .staggeredReveal(index: 0)
        .sheet(isPresented: $showAddFriend) {
            AddFriendByUsernameSheet()
        }
    }

    // MARK: - Helpers

    private var filteredFriends: [Friend] {
        let acceptedFriends = fetchAcceptedFriends()
        guard !searchText.isEmpty else { return Array(acceptedFriends) }
        let query = searchText.lowercased()
        return acceptedFriends.filter {
            ($0.user?.resolvedDisplayName.lowercased().contains(query) ?? false) ||
            ($0.user?.username.lowercased().contains(query) ?? false)
        }
    }

    private func fetchAcceptedFriends() -> [Friend] {
        let friends = (try? modelContext.fetch(FetchDescriptor<Friend>())) ?? []
        return friends
            .filter { $0.statusRaw == "accepted" }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private func isOnline(_ friend: Friend) -> Bool {
        guard let noiseKey = friend.user?.noisePublicKey, !noiseKey.isEmpty else { return false }
        let connected = coordinator.peerStore.connectedPeers()
        return connected.contains { $0.noisePublicKey == noiseKey }
    }
}

// MARK: - Preview

#Preview("Friends List") {
    NavigationStack {
        ScrollView {
            ChatFriendsListView()
        }
    }
    .blipTheme()
}
