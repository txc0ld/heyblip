import SwiftUI
import SwiftData

// MARK: - FriendsListView

/// Friends management view with Online/All/Pending/Blocked sections,
/// search, and add-by-username functionality.
///
/// Loads real friend data from SwiftData. Falls back to sample data in previews.
struct FriendsListView: View {

    @State private var friends: [FriendListItem] = []
    @State private var searchText: String = ""
    @State private var selectedSection: FriendSection = .all
    @State private var showAddFriend = false
    @State private var addUsername: String = ""
    @State private var selectedFriend: FriendListItem?
    @State private var isLoaded = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            GradientBackground()

            VStack(spacing: 0) {
                searchBar
                sectionPicker
                friendsList
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddFriend = true }) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(.blipAccentPurple)
                }
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel("Add friend")
            }
        }
        .alert("Add Friend", isPresented: $showAddFriend) {
            TextField("Username", text: $addUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Send Request") {
                sendFriendRequest()
            }
            Button("Cancel", role: .cancel) {
                addUsername = ""
            }
        } message: {
            Text("Enter their username to send a friend request.")
        }
        .sheet(item: $selectedFriend) { friend in
            ProfileSheet(
                isPresented: Binding(
                    get: { selectedFriend != nil },
                    set: { if !$0 { selectedFriend = nil } }
                ),
                displayName: friend.displayName,
                username: friend.username,
                bio: friend.bio,
                isFriend: friend.status == .accepted,
                isOnline: friend.isOnline,
                onAddFriend: friend.status == .pending ? {
                    acceptFriendRequest(friend)
                    selectedFriend = nil
                } : nil
            )
            .presentationDetents([.medium])
        }
        .task {
            loadFriends()
        }
        .onReceive(NotificationCenter.default.publisher(for: .friendListDidChange)) { _ in
            loadFriends()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(theme.colors.mutedText)

            TextField("Search friends...", text: $searchText)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous))
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .accessibilityLabel("Search friends")
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlipSpacing.sm) {
                ForEach(FriendSection.allCases, id: \.self) { section in
                    sectionChip(section)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.bottom, BlipSpacing.sm)
        }
    }

    private func sectionChip(_ section: FriendSection) -> some View {
        let count = friendsForSection(section).count
        return Button(action: {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                selectedSection = section
            }
        }) {
            HStack(spacing: BlipSpacing.xs) {
                Text(section.displayName)
                    .font(theme.typography.caption)
                    .fontWeight(selectedSection == section ? .semibold : .regular)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(selectedSection == section ? .white : theme.colors.mutedText)
                }
            }
            .foregroundStyle(selectedSection == section ? .white : theme.colors.text)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                Capsule()
                    .fill(selectedSection == section
                          ? AnyShapeStyle(LinearGradient.blipAccent)
                          : AnyShapeStyle(theme.colors.hover))
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(section.displayName), \(count) friends")
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    // MARK: - Friends List

    private var friendsList: some View {
        ScrollView {
            let filteredFriends = friendsForSection(selectedSection)
                .filter { friend in
                    searchText.isEmpty ||
                    friend.displayName.localizedCaseInsensitiveContains(searchText) ||
                    friend.username.localizedCaseInsensitiveContains(searchText)
                }

            if filteredFriends.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: BlipSpacing.sm) {
                    ForEach(Array(filteredFriends.enumerated()), id: \.element.id) { index, friend in
                        FriendRow(friend: friend, onTap: { selectedFriend = friend })
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if friend.status == .accepted {
                                    Button(role: .destructive) {
                                        removeFriend(friend)
                                    } label: {
                                        Label("Remove", systemImage: "person.badge.minus")
                                    }
                                    Button {
                                        blockFriend(friend)
                                    } label: {
                                        Label("Block", systemImage: "hand.raised")
                                    }
                                    .tint(.orange)
                                } else if friend.status == .blocked {
                                    Button {
                                        unblockFriend(friend)
                                    } label: {
                                        Label("Unblock", systemImage: "hand.raised.slash")
                                    }
                                    .tint(.green)
                                } else if friend.status == .pending {
                                    Button(role: .destructive) {
                                        declineFriend(friend)
                                    } label: {
                                        Label("Decline", systemImage: "xmark")
                                    }
                                }
                            }
                            .staggeredReveal(index: index)
                    }
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.bottom, BlipSpacing.xxl)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.md) {
            Spacer().frame(height: BlipSpacing.xxl)

            Image(systemName: selectedSection.emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(theme.colors.mutedText)

            Text(selectedSection.emptyMessage)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)

            if selectedSection == .all && searchText.isEmpty {
                GlassButton("Add Friend", icon: "person.badge.plus", style: .secondary, size: .small) {
                    showAddFriend = true
                }
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func friendsForSection(_ section: FriendSection) -> [FriendListItem] {
        switch section {
        case .online: return friends.filter { $0.isOnline && $0.status == .accepted }
        case .all: return friends.filter { $0.status == .accepted }
        case .pending: return friends.filter { $0.status == .pending }
        case .blocked: return friends.filter { $0.status == .blocked }
        }
    }

    private func sendFriendRequest() {
        guard !addUsername.isEmpty else { return }
        // Look up the peer by username in PeerStore and send a request
        let username = addUsername
        addUsername = ""

        guard let peer = coordinator.peerStore.peer(byUsername: username),
              let messageService = coordinator.messageService else {
            return
        }
        Task {
            try? await messageService.sendFriendRequest(toPeerData: peer.peerID)
            loadFriends()
        }
    }

    private func acceptFriendRequest(_ item: FriendListItem) {
        guard let messageService = coordinator.messageService else { return }
        let context = ModelContext(modelContext.container)
        let friendID = item.id
        let desc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(desc).first else { return }
        Task {
            try? await messageService.acceptFriendRequest(from: friend)
            loadFriends()
        }
    }

    private func removeFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        let friendID = item.id
        let desc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(desc).first else { return }
        context.delete(friend)
        try? context.save()
        loadFriends()
        NotificationCenter.default.post(name: .friendListDidChange, object: nil)
    }

    private func blockFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        let friendID = item.id
        let desc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(desc).first else { return }
        friend.statusRaw = FriendStatus.blocked.rawValue
        try? context.save()
        loadFriends()
        NotificationCenter.default.post(name: .friendListDidChange, object: nil)
    }

    private func unblockFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        let friendID = item.id
        let desc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(desc).first else { return }
        friend.statusRaw = FriendStatus.accepted.rawValue
        try? context.save()
        loadFriends()
        NotificationCenter.default.post(name: .friendListDidChange, object: nil)
    }

    private func declineFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        let friendID = item.id
        let desc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(desc).first else { return }
        context.delete(friend)
        try? context.save()
        loadFriends()
        NotificationCenter.default.post(name: .friendListDidChange, object: nil)
    }

    private func loadFriends() {
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<Friend>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        guard let allFriends = try? context.fetch(descriptor) else { return }

        // Check which friends are online via PeerStore
        let connectedKeys = Set(coordinator.peerStore.connectedPeers().map(\.noisePublicKey))

        friends = allFriends.compactMap { friend -> FriendListItem? in
            guard let user = friend.user else { return nil }
            let isOnline = connectedKeys.contains(user.noisePublicKey)
            return FriendListItem(
                id: friend.id,
                displayName: user.resolvedDisplayName,
                username: user.username,
                bio: user.bio ?? "",
                isOnline: isOnline,
                isPhoneVerified: user.isVerified,
                status: friend.status
            )
        }
    }
}

// MARK: - FriendRow

private struct FriendRow: View {

    let friend: FriendListItem
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BlipSpacing.md) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(LinearGradient.blipAccent.opacity(0.7))
                        .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                        .overlay(
                            Text(String(friend.displayName.prefix(1)).uppercased())
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        )

                    if friend.isOnline {
                        Circle()
                            .fill(.green)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.black, lineWidth: 1.5))
                            .offset(x: 14, y: 14)
                    }
                }

                // Info
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    HStack {
                        Text(friend.displayName)
                            .font(theme.typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.colors.text)

                        if friend.isPhoneVerified {
                            VerifiedBadge(size: 12)
                        }
                    }

                    Text("@\(friend.username)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                // Status indicator
                if friend.status == .pending {
                    Text("Pending")
                        .font(theme.typography.caption)
                        .foregroundStyle(BlipColors.darkColors.statusAmber)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(BlipColors.darkColors.statusAmber.opacity(0.12)))
                } else if friend.status == .blocked {
                    Text("Blocked")
                        .font(theme.typography.caption)
                        .foregroundStyle(BlipColors.darkColors.statusRed)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(BlipColors.darkColors.statusRed.opacity(0.12)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.lg, borderOpacity: 0.1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(friend.displayName), @\(friend.username)\(friend.isOnline ? ", online" : "")\(friend.status == .pending ? ", pending" : "")")
    }
}

// MARK: - Supporting Types

enum FriendSection: CaseIterable {
    case online, all, pending, blocked

    var displayName: String {
        switch self {
        case .online: return "Online"
        case .all: return "All"
        case .pending: return "Pending"
        case .blocked: return "Blocked"
        }
    }

    var emptyIcon: String {
        switch self {
        case .online: return "wifi.slash"
        case .all: return "person.2"
        case .pending: return "clock"
        case .blocked: return "hand.raised"
        }
    }

    var emptyMessage: String {
        switch self {
        case .online: return "No friends online right now"
        case .all: return "No friends yet. Add someone!"
        case .pending: return "No pending requests"
        case .blocked: return "No blocked users"
        }
    }
}

struct FriendListItem: Identifiable {
    let id: UUID
    let displayName: String
    let username: String
    let bio: String
    let isOnline: Bool
    let isPhoneVerified: Bool
    let status: FriendStatus
}

// MARK: - Sample Data

extension FriendsListView {
    static let sampleFriends: [FriendListItem] = [
        FriendListItem(id: UUID(), displayName: "Sarah Chen", username: "sarahc", bio: "Music and mountains", isOnline: true, isPhoneVerified: true, status: .accepted),
        FriendListItem(id: UUID(), displayName: "Jake Morrison", username: "jakem", bio: "Always at the front", isOnline: true, isPhoneVerified: false, status: .accepted),
        FriendListItem(id: UUID(), displayName: "Priya Patel", username: "priyap", bio: "Festival photographer", isOnline: false, isPhoneVerified: true, status: .accepted),
        FriendListItem(id: UUID(), displayName: "Tom Wilson", username: "tomw", bio: "", isOnline: false, isPhoneVerified: false, status: .pending),
        FriendListItem(id: UUID(), displayName: "Blocked User", username: "spam123", bio: "", isOnline: false, isPhoneVerified: false, status: .blocked),
    ]
}

// MARK: - Preview

#Preview("Friends List") {
    NavigationStack {
        FriendsListView()
    }
    .preferredColorScheme(.dark)
    .blipTheme()
    .environment(AppCoordinator())
}
