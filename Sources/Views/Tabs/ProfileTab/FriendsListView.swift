import SwiftUI
import SwiftData

private enum FriendsListL10n {
    static let title = String(localized: "friends.title", defaultValue: "Friends")
    static let addFriend = String(localized: "common.add_friend", defaultValue: "Add Friend")
    static let searchPlaceholder = String(localized: "friends.search.placeholder", defaultValue: "Search friends...")
    static let searchAccessibilityLabel = String(localized: "friends.search.accessibility_label", defaultValue: "Search friends")
    static let remove = String(localized: "friends.action.remove", defaultValue: "Remove")
    static let block = String(localized: "friends.action.block", defaultValue: "Block")
    static let unblock = String(localized: "friends.action.unblock", defaultValue: "Unblock")
    static let cancelRequest = String(localized: "friends.action.cancel_request", defaultValue: "Cancel Request")
    static let decline = String(localized: "friends.action.decline", defaultValue: "Decline")
    static let notFound = String(localized: "friends.error.not_found", defaultValue: "Friend not found")
    static let blocked = String(localized: "friends.status.blocked", defaultValue: "Blocked")
    static let requested = String(localized: "friends.status.requested", defaultValue: "Requested")
    static let accept = String(localized: "friends.status.accept", defaultValue: "Accept")
    static let online = String(localized: "friends.section.online", defaultValue: "Online")
    static let all = String(localized: "friends.section.all", defaultValue: "All")
    static let pending = String(localized: "friends.section.pending", defaultValue: "Pending")
    static let blockedSection = String(localized: "friends.section.blocked", defaultValue: "Blocked")
    static let emptyOnline = String(localized: "friends.empty.online", defaultValue: "No friends online right now")
    static let emptyAll = String(localized: "friends.empty.all", defaultValue: "No friends yet. Add someone!")
    static let emptyPending = String(localized: "friends.empty.pending", defaultValue: "No pending requests")
    static let relayOffline = String(localized: "friends.empty.pending.relay_offline", defaultValue: "Relay offline — friend requests may be delayed")
    static let emptyBlocked = String(localized: "friends.empty.blocked", defaultValue: "No blocked users")
    static let previewSarahChen = "Sarah Chen"
    static let previewJakeMorrison = "Jake Morrison"
    static let previewPriyaPatel = "Priya Patel"
    static let previewTomWilson = "Tom Wilson"
    static let previewBlockedUser = "Blocked User"
    static let previewMusicAndMountains = "Music and mountains"
    static let previewAlwaysAtFront = "Always at the front"
    static let previewEventPhotographer = "Event photographer"

    static func sectionAccessibility(_ name: String, count: Int) -> String {
        String(format: String(localized: "friends.section.accessibility", defaultValue: "%1$@, %2$d friends"), locale: Locale.current, name, count)
    }
}

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
        .navigationTitle(FriendsListL10n.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddFriend = true }) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(.blipAccentPurple)
                }
                .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                .accessibilityLabel(FriendsListL10n.addFriend)
            }
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendByUsernameSheet()
        }
        .onChange(of: showAddFriend) { _, isPresented in
            if !isPresented {
                loadFriends()
            }
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
                onAddFriend: (friend.status == .pending && friend.requestDirection == .incoming) ? {
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

            TextField(FriendsListL10n.searchPlaceholder, text: $searchText)
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
        .accessibilityLabel(FriendsListL10n.searchAccessibilityLabel)
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
        .accessibilityLabel(FriendsListL10n.sectionAccessibility(section.displayName, count: count))
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
                                        Label(FriendsListL10n.remove, systemImage: "person.badge.minus")
                                    }
                                    Button {
                                        blockFriend(friend)
                                    } label: {
                                        Label(FriendsListL10n.block, systemImage: "hand.raised")
                                    }
                                    .tint(.orange)
                                } else if friend.status == .blocked {
                                    Button {
                                        unblockFriend(friend)
                                    } label: {
                                        Label(FriendsListL10n.unblock, systemImage: "hand.raised.slash")
                                    }
                                    .tint(.green)
                                } else if friend.status == .pending {
                                    Button(role: .destructive) {
                                        declineFriend(friend)
                                    } label: {
                                        if friend.requestDirection == .outgoing {
                                            Label(FriendsListL10n.cancelRequest, systemImage: "xmark.circle")
                                        } else {
                                            Label(FriendsListL10n.decline, systemImage: "xmark")
                                        }
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

            if selectedSection == .pending, coordinator.webSocketTransport?.state != .running {
                Text(FriendsListL10n.relayOffline)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.statusAmber)
                    .padding(.top, BlipSpacing.xs)
            }

            if selectedSection == .all && searchText.isEmpty {
                GlassButton(FriendsListL10n.addFriend, icon: "person.badge.plus", style: .secondary, size: .small) {
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

    private func acceptFriendRequest(_ item: FriendListItem) {
        guard let messageService = coordinator.messageService else { return }
        let context = ModelContext(modelContext.container)
        let itemID = item.id

        do {
            let friend = try resolveFriend(id: itemID, context: context)
            Task {
                do {
                    try await messageService.acceptFriendRequest(from: friend)
                    loadFriends()
                } catch {
                    DebugLogger.shared.log("DM", "Failed to accept friend request for \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
                }
            }
        } catch {
            DebugLogger.shared.log("DB", "Failed to resolve friend \(itemID) for accept: \(error.localizedDescription)", isError: true)
        }
    }

    private func removeFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        do {
            let friend = try resolveFriend(id: item.id, context: context)
            context.delete(friend)
            try context.save()
            loadFriends()
            NotificationCenter.default.post(name: .friendListDidChange, object: nil)
        } catch {
            DebugLogger.shared.log("DB", "Failed to remove friend \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
        }
    }

    private func blockFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        do {
            let friend = try resolveFriend(id: item.id, context: context)
            friend.statusRaw = FriendStatus.blocked.rawValue
            try context.save()
            loadFriends()
            NotificationCenter.default.post(name: .friendListDidChange, object: nil)
        } catch {
            DebugLogger.shared.log("DB", "Failed to block friend \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
        }
    }

    private func unblockFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        do {
            let friend = try resolveFriend(id: item.id, context: context)
            friend.statusRaw = FriendStatus.accepted.rawValue
            try context.save()
            loadFriends()
            NotificationCenter.default.post(name: .friendListDidChange, object: nil)
        } catch {
            DebugLogger.shared.log("DB", "Failed to unblock friend \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
        }
    }

    private func declineFriend(_ item: FriendListItem) {
        let context = ModelContext(modelContext.container)
        do {
            let friend = try resolveFriend(id: item.id, context: context)
            context.delete(friend)
            try context.save()
            loadFriends()
            NotificationCenter.default.post(name: .friendListDidChange, object: nil)
        } catch {
            DebugLogger.shared.log("DB", "Failed to decline/cancel friend request for \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
        }
    }

    private func loadFriends() {
        let context = ModelContext(modelContext.container)
        do {
            let allFriends = try context.fetch(FetchDescriptor<Friend>())
                .sorted(by: { $0.addedAt > $1.addedAt })

            // Check which friends are online via PeerStore
            let connectedKeys = Set(coordinator.peerStore.connectedPeers().map(\.noisePublicKey))

            friends = allFriends.compactMap { friend -> FriendListItem? in
                guard let user = friend.user else {
                    DebugLogger.shared.log("DB", "Friend \(friend.id) has nil User — excluded from list")
                    return nil
                }
                let isOnline = connectedKeys.contains(user.noisePublicKey)
                return FriendListItem(
                    id: friend.id,
                    displayName: user.resolvedDisplayName,
                    username: user.username,
                    bio: user.bio ?? "",
                    isOnline: isOnline,
                    isVerified: user.isVerified,
                    status: friend.status,
                    requestDirection: friend.requestDirection
                )
            }
        } catch {
            DebugLogger.shared.log("DB", "Failed to load friends: \(error.localizedDescription)", isError: true)
        }
    }

    private func resolveFriend(id: UUID, context: ModelContext) throws -> Friend {
        let friendID = id
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try context.fetch(descriptor).first else {
            throw NSError(domain: "FriendsListView", code: 404, userInfo: [NSLocalizedDescriptionKey: FriendsListL10n.notFound])
        }
        return friend
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
                            .fill(Color.blipElectricCyan)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(theme.colors.background, lineWidth: 1.5))
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

                        if friend.isVerified {
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
                    pendingStatusBadge
                } else if friend.status == .blocked {
                    Text(FriendsListL10n.blocked)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xs)
                        .background(Capsule().fill(theme.colors.statusRed.opacity(0.12)))
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
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var pendingStatusBadge: some View {
        if friend.requestDirection == .outgoing {
            Text(FriendsListL10n.requested)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, BlipSpacing.xs)
                .background(Capsule().fill(theme.colors.hover))
        } else {
            Text(FriendsListL10n.accept)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.statusAmber)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, BlipSpacing.xs)
                .background(Capsule().fill(theme.colors.statusAmber.opacity(0.12)))
        }
    }

    private var accessibilityLabel: String {
        let onlineLabel = friend.isOnline ? ", online" : ""
        let pendingLabel: String
        if friend.status == .pending {
            pendingLabel = friend.requestDirection == .outgoing ? ", requested" : ", incoming friend request"
        } else if friend.status == .blocked {
            pendingLabel = ", blocked"
        } else {
            pendingLabel = ""
        }
        return "\(friend.displayName), @\(friend.username)\(onlineLabel)\(pendingLabel)"
    }
}

// MARK: - Supporting Types

enum FriendSection: CaseIterable {
    case online, all, pending, blocked

    var displayName: String {
        switch self {
        case .online: return FriendsListL10n.online
        case .all: return FriendsListL10n.all
        case .pending: return FriendsListL10n.pending
        case .blocked: return FriendsListL10n.blockedSection
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
        case .online: return FriendsListL10n.emptyOnline
        case .all: return FriendsListL10n.emptyAll
        case .pending: return FriendsListL10n.emptyPending
        case .blocked: return FriendsListL10n.emptyBlocked
        }
    }
}

struct FriendListItem: Identifiable {
    let id: UUID
    let displayName: String
    let username: String
    let bio: String
    let isOnline: Bool
    let isVerified: Bool
    let status: FriendStatus
    let requestDirection: FriendRequestDirection?
}

// MARK: - Sample Data

extension FriendsListView {
    static let sampleFriends: [FriendListItem] = [
        FriendListItem(id: UUID(), displayName: FriendsListL10n.previewSarahChen, username: "sarahc", bio: FriendsListL10n.previewMusicAndMountains, isOnline: true, isVerified: true, status: .accepted, requestDirection: nil),
        FriendListItem(id: UUID(), displayName: FriendsListL10n.previewJakeMorrison, username: "jakem", bio: FriendsListL10n.previewAlwaysAtFront, isOnline: true, isVerified: false, status: .accepted, requestDirection: nil),
        FriendListItem(id: UUID(), displayName: FriendsListL10n.previewPriyaPatel, username: "priyap", bio: FriendsListL10n.previewEventPhotographer, isOnline: false, isVerified: true, status: .accepted, requestDirection: nil),
        FriendListItem(id: UUID(), displayName: FriendsListL10n.previewTomWilson, username: "tomw", bio: "", isOnline: false, isVerified: false, status: .pending, requestDirection: .incoming),
        FriendListItem(id: UUID(), displayName: FriendsListL10n.previewBlockedUser, username: "spam123", bio: "", isOnline: false, isVerified: false, status: .blocked, requestDirection: nil),
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
