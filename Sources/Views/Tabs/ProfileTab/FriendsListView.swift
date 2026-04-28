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
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")

    static let removeConfirmTitle = String(localized: "friends.confirm.remove.title", defaultValue: "Remove friend?")
    static let blockConfirmTitle = String(localized: "friends.confirm.block.title", defaultValue: "Block this user?")
    static let cancelConfirmTitle = String(localized: "friends.confirm.cancel.title", defaultValue: "Cancel friend request?")
    static let declineConfirmTitle = String(localized: "friends.confirm.decline.title", defaultValue: "Decline friend request?")

    static func removeConfirmMessage(_ name: String) -> String {
        String(format: String(localized: "friends.confirm.remove.message", defaultValue: "%@ will no longer appear in your friends. You can add them again later."), locale: Locale.current, name)
    }

    static func blockConfirmMessage(_ name: String) -> String {
        String(format: String(localized: "friends.confirm.block.message", defaultValue: "%@ won't be able to message you. You can unblock them any time."), locale: Locale.current, name)
    }

    static func cancelConfirmMessage(_ name: String) -> String {
        String(format: String(localized: "friends.confirm.cancel.message", defaultValue: "Cancel your pending friend request to %@?"), locale: Locale.current, name)
    }

    static func declineConfirmMessage(_ name: String) -> String {
        String(format: String(localized: "friends.confirm.decline.message", defaultValue: "Decline %@'s friend request?"), locale: Locale.current, name)
    }
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

    static func accessibilityMore(_ name: String) -> String {
        String(format: String(localized: "friends.action.more.accessibility", defaultValue: "More options for %@"), locale: Locale.current, name)
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
    @State private var confirmingAction: PendingAction?

    /// Double-tap debounce for async friend actions. See
    /// `FriendActionGuard` for the full contract; the short version is
    /// "one claim per Friend row at a time".
    @State private var actionsGuard = FriendActionGuard()

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
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
                        .font(theme.typography.callout)
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
        .alert(
            confirmingAction?.title ?? "",
            isPresented: Binding(
                get: { confirmingAction != nil },
                set: { if !$0 { confirmingAction = nil } }
            ),
            presenting: confirmingAction
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                performConfirmedAction(action)
                confirmingAction = nil
            }
            Button(FriendsListL10n.cancel, role: .cancel) {
                confirmingAction = nil
            }
        } message: { action in
            Text(action.message)
        }
    }

    private func performConfirmedAction(_ action: PendingAction) {
        switch action {
        case .removeFriend(let friend):
            removeFriend(friend)
        case .blockFriend(let friend):
            blockFriend(friend)
        case .cancelRequest(let friend), .declineRequest(let friend):
            declineFriend(friend)
        }
    }

    /// Pending / blocked rows have no chat to push yet, so they still open
    /// the profile sheet. Accepted friends jump straight into the DM.
    private func handleRowTap(_ friend: FriendListItem) {
        guard friend.status == .accepted else {
            selectedFriend = friend
            return
        }
        let username = friend.username
        dismiss()
        Task { await coordinator.openDM(withUsername: username) }
    }

    // MARK: - Pending Action

    /// A destructive action awaiting user confirmation before it runs. Surfaced
    /// via the system alert so the user can't accidentally remove a friend or
    /// cancel a pending request with a single errant tap.
    enum PendingAction: Identifiable {
        case removeFriend(FriendListItem)
        case blockFriend(FriendListItem)
        case cancelRequest(FriendListItem)
        case declineRequest(FriendListItem)

        var id: String {
            switch self {
            case .removeFriend(let f): return "remove-\(f.id)"
            case .blockFriend(let f): return "block-\(f.id)"
            case .cancelRequest(let f): return "cancel-\(f.id)"
            case .declineRequest(let f): return "decline-\(f.id)"
            }
        }

        var title: String {
            switch self {
            case .removeFriend: return FriendsListL10n.removeConfirmTitle
            case .blockFriend: return FriendsListL10n.blockConfirmTitle
            case .cancelRequest: return FriendsListL10n.cancelConfirmTitle
            case .declineRequest: return FriendsListL10n.declineConfirmTitle
            }
        }

        var message: String {
            let displayName = friend.displayName
            switch self {
            case .removeFriend: return FriendsListL10n.removeConfirmMessage(displayName)
            case .blockFriend: return FriendsListL10n.blockConfirmMessage(displayName)
            case .cancelRequest: return FriendsListL10n.cancelConfirmMessage(displayName)
            case .declineRequest: return FriendsListL10n.declineConfirmMessage(displayName)
            }
        }

        var confirmTitle: String {
            switch self {
            case .removeFriend: return FriendsListL10n.remove
            case .blockFriend: return FriendsListL10n.block
            case .cancelRequest: return FriendsListL10n.cancelRequest
            case .declineRequest: return FriendsListL10n.decline
            }
        }

        private var friend: FriendListItem {
            switch self {
            case .removeFriend(let f),
                 .blockFriend(let f),
                 .cancelRequest(let f),
                 .declineRequest(let f):
                return f
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)

            TextField(FriendsListL10n.searchPlaceholder, text: $searchText)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(theme.typography.secondary)
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
                        .font(theme.typography.caption2)
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
                        FriendRow(
                            friend: friend,
                            onTap: { handleRowTap(friend) },
                            onAcceptIncoming: friend.status == .pending && friend.requestDirection == .incoming
                                ? { acceptFriendRequest(friend) }
                                : nil,
                            onCancelOutgoing: friend.status == .pending && friend.requestDirection == .outgoing
                                ? { confirmingAction = .cancelRequest(friend) }
                                : nil,
                            onRemove: friend.status == .accepted
                                ? { confirmingAction = .removeFriend(friend) }
                                : nil,
                            onBlock: friend.status == .accepted
                                ? { confirmingAction = .blockFriend(friend) }
                                : nil,
                            onUnblock: friend.status == .blocked
                                ? { unblockFriend(friend) }
                                : nil
                        )
                        .contextMenu {
                            contextMenuContent(for: friend)
                        }
                        .staggeredReveal(index: index)
                    }
                }
                .padding(.horizontal, BlipSpacing.md)
                .padding(.bottom, BlipSpacing.xxl)
            }
        }
    }

    @ViewBuilder
    private func contextMenuContent(for friend: FriendListItem) -> some View {
        if friend.status == .accepted {
            Button(role: .destructive) {
                confirmingAction = .removeFriend(friend)
            } label: {
                Label(FriendsListL10n.remove, systemImage: "person.badge.minus")
            }
            Button(role: .destructive) {
                confirmingAction = .blockFriend(friend)
            } label: {
                Label(FriendsListL10n.block, systemImage: "hand.raised")
            }
        } else if friend.status == .blocked {
            Button {
                unblockFriend(friend)
            } label: {
                Label(FriendsListL10n.unblock, systemImage: "hand.raised.slash")
            }
        } else if friend.status == .pending {
            Button(role: .destructive) {
                confirmingAction = friend.requestDirection == .outgoing
                    ? .cancelRequest(friend)
                    : .declineRequest(friend)
            } label: {
                if friend.requestDirection == .outgoing {
                    Label(FriendsListL10n.cancelRequest, systemImage: "xmark.circle")
                } else {
                    Label(FriendsListL10n.decline, systemImage: "xmark")
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let showAddFriendCTA = selectedSection == .all && searchText.isEmpty

        return VStack(spacing: BlipSpacing.sm) {
            EmptyStateView(
                icon: selectedSection.emptyIcon,
                title: selectedSection.emptyMessage,
                subtitle: "",
                ctaTitle: showAddFriendCTA ? FriendsListL10n.addFriend : nil,
                ctaAction: showAddFriendCTA ? { showAddFriend = true } : nil,
                style: .inline
            )
            .padding(.top, BlipSpacing.xxl)

            if selectedSection == .pending, coordinator.webSocketTransport?.state != .running {
                Text(FriendsListL10n.relayOffline)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.statusAmber)
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
        guard actionsGuard.claim(for: item.id) else { return }
        guard let messageService = coordinator.messageService else {
            actionsGuard.release(for: item.id)
            return
        }
        let context = ModelContext(modelContext.container)
        let itemID = item.id

        do {
            let friend = try resolveFriend(id: itemID, context: context)
            Task {
                defer { actionsGuard.release(for: itemID) }
                do {
                    try await messageService.acceptFriendRequest(from: friend)
                    loadFriends()
                } catch {
                    DebugLogger.shared.log("DM", "Failed to accept friend request for \(DebugLogger.redact(item.username)): \(error.localizedDescription)", isError: true)
                }
            }
        } catch {
            actionsGuard.release(for: itemID)
            DebugLogger.shared.log("DB", "Failed to resolve friend \(itemID) for accept: \(error.localizedDescription)", isError: true)
        }
    }

    private func removeFriend(_ item: FriendListItem) {
        guard actionsGuard.claim(for: item.id) else { return }
        defer { actionsGuard.release(for: item.id) }
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
        guard actionsGuard.claim(for: item.id) else { return }
        defer { actionsGuard.release(for: item.id) }
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
        guard actionsGuard.claim(for: item.id) else { return }
        defer { actionsGuard.release(for: item.id) }
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
        guard actionsGuard.claim(for: item.id) else { return }
        defer { actionsGuard.release(for: item.id) }
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

            // One-time cleanup: older builds persisted synthetic "peer_<8-hex>"
            // Users when a friend request arrived with no username. Delete the
            // Friend record so it no longer appears in the list. The underlying
            // User record is left intact in case it is referenced by other
            // relationships (e.g. Channel participants).
            let syntheticFriends = allFriends.filter { friend in
                guard let user = friend.user else { return false }
                return Self.isSyntheticPeerUsername(user.username)
            }
            if !syntheticFriends.isEmpty {
                for friend in syntheticFriends {
                    context.delete(friend)
                }
                do {
                    try context.save()
                    DebugLogger.shared.log("DB", "Removed \(syntheticFriends.count) Friend record(s) with synthetic peer_<hex> usernames")
                } catch {
                    DebugLogger.shared.log("DB", "Failed to delete synthetic Friend records: \(error.localizedDescription)", isError: true)
                }
            }
            let cleanFriends = allFriends.filter { !syntheticFriends.contains($0) }

            // Check which friends are online via PeerStore
            let connectedKeys = Set(coordinator.peerStore.connectedPeers().map(\.noisePublicKey))

            friends = cleanFriends.compactMap { friend -> FriendListItem? in
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

    /// Matches the exact synthetic format once produced by `resolveOrCreateUser`:
    /// `peer_` followed by 8 lowercase hex characters derived from `peerID.prefix(4)`.
    static func isSyntheticPeerUsername(_ username: String) -> Bool {
        guard username.count == 13, username.hasPrefix("peer_") else { return false }
        return username.dropFirst(5).allSatisfy { $0.isHexDigit }
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
    /// Tapping the inline "Accept" pill (incoming pending) runs this.
    let onAcceptIncoming: (() -> Void)?
    /// Tapping the inline "Cancel" pill (outgoing pending) runs this.
    let onCancelOutgoing: (() -> Void)?
    /// Tapping "Remove" in the row ellipsis menu (accepted friends).
    let onRemove: (() -> Void)?
    /// Tapping "Block" in the row ellipsis menu.
    let onBlock: (() -> Void)?
    /// Tapping "Unblock" on a blocked row.
    let onUnblock: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BlipSpacing.md) {
                avatar
                info
                Spacer()
                trailingControls
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.lg, borderOpacity: 0.1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient.blipAccent.opacity(0.7))
                .frame(width: BlipSizing.avatarSmall, height: BlipSizing.avatarSmall)
                .overlay(
                    Text(String(friend.displayName.prefix(1)).uppercased())
                        .font(theme.typography.callout)
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
    }

    private var info: some View {
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
    }

    /// Row-specific trailing controls. Every state surfaces an explicit
    /// tappable action — no long-press discovery required.
    @ViewBuilder
    private var trailingControls: some View {
        if friend.status == .accepted {
            acceptedMenu
        } else if friend.status == .pending, friend.requestDirection == .incoming {
            pendingPill(
                label: FriendsListL10n.accept,
                tint: theme.colors.statusAmber,
                action: onAcceptIncoming
            )
        } else if friend.status == .pending, friend.requestDirection == .outgoing {
            pendingPill(
                label: FriendsListL10n.cancelRequest,
                tint: theme.colors.mutedText,
                action: onCancelOutgoing
            )
        } else if friend.status == .blocked {
            blockedControl
        } else {
            Image(systemName: "chevron.right")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    @ViewBuilder
    private var acceptedMenu: some View {
        if onRemove != nil || onBlock != nil {
            Menu {
                if let onRemove {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label(FriendsListL10n.remove, systemImage: "person.badge.minus")
                    }
                }
                if let onBlock {
                    Button(role: .destructive) {
                        onBlock()
                    } label: {
                        Label(FriendsListL10n.block, systemImage: "hand.raised")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(FriendsListL10n.accessibilityMore(friend.displayName))
        } else {
            Image(systemName: "chevron.right")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    @ViewBuilder
    private var blockedControl: some View {
        if let onUnblock {
            Button {
                onUnblock()
            } label: {
                Text(FriendsListL10n.unblock)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.text)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xs)
                    .background(Capsule().fill(theme.colors.hover))
            }
            .buttonStyle(.plain)
            .frame(minHeight: BlipSizing.minTapTarget)
        } else {
            Text(FriendsListL10n.blocked)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.statusRed)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, BlipSpacing.xs)
                .background(Capsule().fill(theme.colors.statusRed.opacity(0.12)))
        }
    }

    /// Inline pill button (pending states). Because this sits inside the row
    /// Button we intercept taps with a TapGesture so the row-level onTap
    /// doesn't also fire and open the profile sheet.
    private func pendingPill(label: String, tint: Color, action: (() -> Void)?) -> some View {
        Text(label)
            .font(theme.typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, BlipSpacing.sm)
            .padding(.vertical, BlipSpacing.xs)
            .background(Capsule().fill(tint.opacity(0.12)))
            .contentShape(Capsule())
            .onTapGesture {
                if let action {
                    BlipHaptics.lightImpact()
                    action()
                }
            }
            .frame(minHeight: BlipSizing.minTapTarget)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }

    private var accessibilityLabel: String {
        let onlineLabel = friend.isOnline ? ", online" : ""
        let pendingLabel: String
        if friend.status == .pending {
            pendingLabel = friend.requestDirection == .outgoing ? ", request sent, tap to cancel" : ", incoming friend request, tap to accept"
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
