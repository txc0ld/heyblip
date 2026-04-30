import SwiftUI
import SwiftData

private enum GroupInfoL10n {
    static let title = String(localized: "chat.group_info.title", defaultValue: "Group Info")
    static let members = String(localized: "chat.group_info.members", defaultValue: "Members")
    static let roleCreator = String(localized: "chat.group_info.role.creator", defaultValue: "Creator")
    static let roleAdmin = String(localized: "chat.group_info.role.admin", defaultValue: "Admin")
    static let online = String(localized: "chat.group_info.online", defaultValue: "Online")
    static let you = String(localized: "chat.group_info.you", defaultValue: "You")
    static let emptyMembers = String(localized: "chat.group_info.empty", defaultValue: "No members yet")
    static let unknownMember = String(localized: "chat.group_info.unknown_member", defaultValue: "Unknown")

    static func memberCount(_ count: Int) -> String {
        String(format: String(localized: "chat.group_info.members.count", defaultValue: "%d members"), locale: Locale.current, count)
    }
}

// MARK: - GroupInfoView

/// Sheet that lists the members of a group chat with their role and presence.
struct GroupInfoView: View {

    let channel: Channel

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Sort creator first, admins next, then members alphabetically by display name.
    private var sortedMemberships: [GroupMembership] {
        channel.memberships.sorted { lhs, rhs in
            if lhs.role != rhs.role {
                return roleRank(lhs.role) < roleRank(rhs.role)
            }
            let lhsName = lhs.user?.resolvedDisplayName ?? ""
            let rhsName = rhs.user?.resolvedDisplayName ?? ""
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }

    private var connectedNoiseKeys: Set<Data> {
        Set(coordinator.peerStore.connectedPeers().map(\.noisePublicKey))
    }

    private var localNoiseKey: Data? {
        coordinator.identity?.noisePublicKey.rawRepresentation
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                        header
                        membersList
                    }
                    .padding(BlipSpacing.md)
                }
            }
            .navigationTitle(GroupInfoL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.text)
                    }
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            Text(channel.name ?? GroupInfoL10n.title)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(GroupInfoL10n.memberCount(channel.memberships.count))
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Members List

    @ViewBuilder
    private var membersList: some View {
        if sortedMemberships.isEmpty {
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "person.3")
                    .font(theme.typography.largeTitle)
                    .foregroundStyle(theme.colors.mutedText)
                Text(GroupInfoL10n.emptyMembers)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.xl)
        } else {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(GroupInfoL10n.members)
                    .font(theme.typography.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.leading, BlipSpacing.xs)

                LazyVStack(spacing: BlipSpacing.xs) {
                    ForEach(sortedMemberships, id: \.id) { membership in
                        memberRow(membership)
                    }
                }
            }
        }
    }

    private func memberRow(_ membership: GroupMembership) -> some View {
        let user = membership.user
        let displayName = user?.resolvedDisplayName ?? GroupInfoL10n.unknownMember
        let username = user?.username ?? ""
        let isLocal = user.map { localNoiseKey != nil && $0.noisePublicKey == localNoiseKey } ?? false
        let isOnline = !isLocal && user.map { connectedNoiseKeys.contains($0.noisePublicKey) } ?? false

        return HStack(spacing: BlipSpacing.md) {
            AvatarView(
                imageData: user?.avatarThumbnail,
                avatarURL: user?.avatarURL,
                name: displayName,
                size: BlipSizing.avatarSmall,
                ringStyle: isLocal ? .subscriber : .none,
                showOnlineIndicator: isOnline
            )

            VStack(alignment: .leading, spacing: BlipSpacing.xxs) {
                HStack(spacing: BlipSpacing.xs) {
                    Text(displayName)
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    if isLocal {
                        Text("(\(GroupInfoL10n.you))")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                }

                if !username.isEmpty {
                    Text("@\(username)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
            }

            Spacer()

            if let roleLabel = roleLabel(for: membership.role) {
                Text(roleLabel)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.accentPurple)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xxs)
                    .background(Capsule().fill(theme.colors.accentPurple.opacity(0.12)))
            }
        }
        .padding(BlipSpacing.md)
        .glassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.lg, borderOpacity: 0.1)
    }

    // MARK: - Helpers

    private func roleRank(_ role: GroupRole) -> Int {
        switch role {
        case .creator: return 0
        case .admin: return 1
        case .member: return 2
        }
    }

    private func roleLabel(for role: GroupRole) -> String? {
        switch role {
        case .creator: return GroupInfoL10n.roleCreator
        case .admin: return GroupInfoL10n.roleAdmin
        case .member: return nil
        }
    }
}
