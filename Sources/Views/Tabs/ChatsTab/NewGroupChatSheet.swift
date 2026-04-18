import SwiftUI
import SwiftData

private enum NewGroupChatL10n {
    static let title = String(localized: "chat.new_group.title", defaultValue: "New Group Chat")
    static let namePlaceholder = String(localized: "chat.new_group.name.placeholder", defaultValue: "Group name")
    static let nameLabel = String(localized: "chat.new_group.name.label", defaultValue: "Name this group")
    static let selectMembersHeader = String(localized: "chat.new_group.members.header", defaultValue: "Add members")
    static let selectionCounterSingle = String(localized: "chat.new_group.members.counter.single", defaultValue: "1 selected")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let create = String(localized: "chat.new_group.action.create", defaultValue: "Create")
    static let noFriendsTitle = String(localized: "chat.new_group.empty.title", defaultValue: "Add friends first")
    static let noFriendsSubtitle = String(localized: "chat.new_group.empty.subtitle", defaultValue: "Groups need at least one other member. Add a friend to get started.")
    static let fallbackFriendName = String(localized: "chat.list.friend.fallback_name", defaultValue: "Friend")
    static let fallbackUnknownUsername = String(localized: "chat.list.friend.fallback_username", defaultValue: "unknown")

    static func selectionCounter(_ count: Int) -> String {
        count == 1
            ? selectionCounterSingle
            : String(
                format: String(localized: "chat.new_group.members.counter.plural", defaultValue: "%d selected"),
                locale: Locale.current,
                count
            )
    }
}

// MARK: - NewGroupChatSheet

/// Multi-select friend picker + name field that creates a new group channel.
///
/// Fronts `ChatViewModel.createGroupChannel(name:members:)`. The caller receives
/// the created `Channel` via `onCreated` and is expected to navigate to it.
struct NewGroupChatSheet: View {

    let chatViewModel: ChatViewModel?
    let onCreated: (Channel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Query private var friends: [Friend]

    @State private var groupName: String = ""
    @State private var selectedFriendIDs: Set<UUID> = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var availableFriends: [Friend] {
        friends
            .filter { $0.status == .accepted && $0.user != nil }
            .sorted { a, b in
                let aName = a.user?.resolvedDisplayName ?? a.user?.username ?? ""
                let bName = b.user?.resolvedDisplayName ?? b.user?.username ?? ""
                return aName.localizedCaseInsensitiveCompare(bName) == .orderedAscending
            }
    }

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedFriendIDs.isEmpty
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()
                    .ignoresSafeArea()

                if availableFriends.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle(NewGroupChatL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NewGroupChatL10n.cancel) {
                        dismiss()
                    }
                    .foregroundStyle(Color.blipAccentPurple)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NewGroupChatL10n.create) {
                        Task { await createGroup() }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(canCreate ? Color.blipAccentPurple : theme.colors.mutedText)
                    .disabled(!canCreate)
                }
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                nameField
                membersSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.statusRed)
                        .padding(.horizontal, BlipSpacing.md)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, BlipSpacing.md)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            Text(NewGroupChatL10n.nameLabel)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .padding(.horizontal, BlipSpacing.md)

            TextField(NewGroupChatL10n.namePlaceholder, text: $groupName)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.text)
                .padding(BlipSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: BlipSizing.hairline)
                )
                .padding(.horizontal, BlipSpacing.md)
                .submitLabel(.done)
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(NewGroupChatL10n.selectMembersHeader)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)

                Spacer()

                if !selectedFriendIDs.isEmpty {
                    Text(NewGroupChatL10n.selectionCounter(selectedFriendIDs.count))
                        .font(theme.typography.caption)
                        .foregroundStyle(Color.blipAccentPurple)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, BlipSpacing.md)

            LazyVStack(spacing: BlipSpacing.xs) {
                ForEach(availableFriends, id: \.id) { friend in
                    row(for: friend)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
        }
    }

    private func row(for friend: Friend) -> some View {
        let isSelected = selectedFriendIDs.contains(friend.id)
        let displayName = friend.user?.resolvedDisplayName
            ?? friend.user?.username
            ?? NewGroupChatL10n.fallbackFriendName
        let username = friend.user?.username ?? NewGroupChatL10n.fallbackUnknownUsername
        return Button {
            toggle(friend)
        } label: {
            HStack(spacing: BlipSpacing.md) {
                AvatarView(
                    imageData: friend.user?.avatarThumbnail,
                    name: displayName,
                    size: BlipSizing.avatarSmall,
                    ringStyle: isSelected ? .friend : .none,
                    showOnlineIndicator: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.text)
                    Text("@\(username)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(theme.typography.headline)
                    .foregroundStyle(
                        isSelected
                            ? Color.blipAccentPurple
                            : theme.colors.mutedText.opacity(0.5)
                    )
                    .symbolEffect(.bounce, value: isSelected)
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .fill(isSelected ? Color.blipAccentPurple.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.blipAccentPurple.opacity(0.3)
                            : Color.white.opacity(0.05),
                        lineWidth: BlipSizing.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)

            Text(NewGroupChatL10n.noFriendsTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(NewGroupChatL10n.noFriendsSubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BlipSpacing.xl)
        }
        .padding(BlipSpacing.xl)
    }

    // MARK: - Actions

    private func toggle(_ friend: Friend) {
        BlipHaptics.selection()
        withAnimation(SpringConstants.gentleAnimation) {
            if selectedFriendIDs.contains(friend.id) {
                selectedFriendIDs.remove(friend.id)
            } else {
                selectedFriendIDs.insert(friend.id)
            }
        }
    }

    private func createGroup() async {
        guard let chatViewModel else { return }
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedUsers = availableFriends
            .filter { selectedFriendIDs.contains($0.id) }
            .compactMap(\.user)

        guard !trimmedName.isEmpty, !selectedUsers.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }

        if let channel = await chatViewModel.createGroupChannel(
            name: trimmedName,
            members: selectedUsers
        ) {
            BlipHaptics.success()
            onCreated(channel)
        } else {
            errorMessage = chatViewModel.errorMessage ?? "Failed to create group"
            BlipHaptics.error()
        }
    }
}

// MARK: - Preview

#Preview("New Group Chat") {
    NewGroupChatSheet(chatViewModel: nil, onCreated: { _ in })
        .environment(\.theme, Theme.shared)
}
