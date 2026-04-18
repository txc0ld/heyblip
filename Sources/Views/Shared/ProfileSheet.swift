import SwiftUI

private enum ProfileSheetL10n {
    static let blockUser = String(localized: "profile.sheet.block.title", defaultValue: "Block User")
    static let block = String(localized: "common.block", defaultValue: "Block")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let blockMessage = String(localized: "profile.sheet.block.message", defaultValue: "Blocked users cannot send you messages or see your location. You can unblock from Settings.")
    static let reportUser = String(localized: "profile.sheet.report.title", defaultValue: "Report User")
    static let report = String(localized: "common.report", defaultValue: "Report")
    static let reportMessage = String(localized: "profile.sheet.report.message", defaultValue: "Report this user for inappropriate behavior. This will be reviewed by the event safety team.")
    static let online = String(localized: "common.online", defaultValue: "Online")
    static let friend = String(localized: "common.friend", defaultValue: "Friend")
    static let message = String(localized: "common.message", defaultValue: "Message")
    static let addFriend = String(localized: "common.add_friend", defaultValue: "Add Friend")
    static let unblock = String(localized: "common.unblock", defaultValue: "Unblock")
    static let previewSarahChen = "Sarah Chen"
    static let previewSarahBio = "Music and mountains. Always at the front row."
    static let previewJakeMorrison = "Jake Morrison"
    static let previewJakeBio = "Event photographer"

    static func mutualFriends(_ count: Int) -> String {
        String(
            format: String(localized: "profile.sheet.mutual_friends", defaultValue: "%d mutual"),
            locale: Locale.current,
            count
        )
    }
}

// MARK: - ProfileSheet

/// Tap-any-avatar popup showing full profile with action buttons.
///
/// Displays: full avatar, display name, username, bio, mutual friends count.
/// Actions: message, add friend, block, report.
struct ProfileSheet: View {

    @Binding var isPresented: Bool

    let displayName: String
    let username: String
    let bio: String
    let isFriend: Bool
    let isOnline: Bool

    var avatarData: Data? = nil
    var mutualFriendsCount: Int = 0
    var isPhoneVerified: Bool = false
    var isBlocked: Bool = false

    var onMessage: (() -> Void)?
    var onAddFriend: (() -> Void)?
    var onBlock: (() -> Void)?
    var onReport: (() -> Void)?

    @State private var showBlockConfirm = false
    @State private var showReportConfirm = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Dimmed background
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: BlipSpacing.lg) {
                // Drag handle
                Capsule()
                    .fill(theme.colors.mutedText.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, BlipSpacing.sm)

                // Avatar
                avatarSection

                // Info
                infoSection

                // Actions
                actionButtons

                Spacer()
            }
            .padding(.horizontal, BlipSpacing.md)
        }
        .background(.ultraThinMaterial)
        .alert(ProfileSheetL10n.blockUser, isPresented: $showBlockConfirm) {
            Button(ProfileSheetL10n.block, role: .destructive) {
                onBlock?()
                isPresented = false
            }
            Button(ProfileSheetL10n.cancel, role: .cancel) {}
        } message: {
            Text(ProfileSheetL10n.blockMessage)
        }
        .alert(ProfileSheetL10n.reportUser, isPresented: $showReportConfirm) {
            Button(ProfileSheetL10n.report, role: .destructive) {
                onReport?()
            }
            Button(ProfileSheetL10n.cancel, role: .cancel) {}
        } message: {
            Text(ProfileSheetL10n.reportMessage)
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        ZStack {
            if let avatarData, let uiImage = uiImageFromData(avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient.blipAccent)
                    .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                    .overlay(
                        Text(String(displayName.prefix(1)).uppercased())
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }

            // Online indicator
            if isOnline {
                Circle()
                    .fill(Color.blipElectricCyan)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(colorScheme == .dark ? .black : .white, lineWidth: 2)
                    )
                    .offset(x: 28, y: 28)
                    .accessibilityLabel(ProfileSheetL10n.online)
            }
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(spacing: BlipSpacing.sm) {
            HStack(spacing: BlipSpacing.xs) {
                Text(displayName)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                if isPhoneVerified {
                    VerifiedBadge(size: 16)
                }
            }

            Text("@\(username)")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)

            if !bio.isEmpty {
                Text(bio)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.top, BlipSpacing.xs)
            }

            // Badges
            HStack(spacing: BlipSpacing.md) {
                if isFriend {
                    badge(icon: "person.fill.checkmark", text: ProfileSheetL10n.friend, color: .blipAccentPurple)
                }

                if isOnline {
                    badge(icon: "wifi", text: ProfileSheetL10n.online, color: theme.colors.statusGreen)
                }

                if mutualFriendsCount > 0 {
                    badge(icon: "person.2", text: ProfileSheetL10n.mutualFriends(mutualFriendsCount), color: theme.colors.mutedText)
                }
            }
            .padding(.top, BlipSpacing.xs)
        }
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: icon)
                .font(theme.typography.caption2)
                .foregroundStyle(color)

            Text(text)
                .font(theme.typography.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, BlipSpacing.sm)
        .padding(.vertical, BlipSpacing.xs)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: BlipSpacing.md) {
            if let onMessage {
                GlassButton(ProfileSheetL10n.message, icon: "message.fill") {
                    onMessage()
                    isPresented = false
                }
                .fullWidth()
            }

            let secondaryActions = availableSecondaryActions
            if !secondaryActions.isEmpty {
                HStack(spacing: BlipSpacing.md) {
                    ForEach(secondaryActions) { action in
                        GlassButton(action.title, icon: action.icon, style: action.style, size: .small) {
                            action.handler()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    private struct SheetAction: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let style: GlassButton.Style
        let handler: () -> Void
    }

    private var availableSecondaryActions: [SheetAction] {
        var actions: [SheetAction] = []

        if !isFriend, let onAddFriend {
            actions.append(
                SheetAction(
                    title: ProfileSheetL10n.addFriend,
                    icon: "person.badge.plus",
                    style: .secondary,
                    handler: onAddFriend
                )
            )
        }

        if let onBlock {
            actions.append(
                SheetAction(
                    title: isBlocked ? ProfileSheetL10n.unblock : ProfileSheetL10n.block,
                    icon: isBlocked ? "hand.raised.slash" : "hand.raised",
                    style: .outline,
                    handler: {
                        if isBlocked {
                            onBlock()
                            isPresented = false
                        } else {
                            showBlockConfirm = true
                        }
                    }
                )
            )
        }

        if onReport != nil {
            actions.append(
                SheetAction(
                    title: ProfileSheetL10n.report,
                    icon: "exclamationmark.bubble",
                    style: .outline,
                    handler: { showReportConfirm = true }
                )
            )
        }

        return actions
    }

    // MARK: - Helpers

    private func uiImageFromData(_ data: Data) -> UIImage? {
        #if canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}

// MARK: - Preview

#Preview("Profile Sheet - Friend") {
    ProfileSheet(
        isPresented: .constant(true),
        displayName: ProfileSheetL10n.previewSarahChen,
        username: "sarahc",
        bio: ProfileSheetL10n.previewSarahBio,
        isFriend: true,
        isOnline: true,
        mutualFriendsCount: 5,
        isPhoneVerified: true
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}

#Preview("Profile Sheet - Not Friend") {
    ProfileSheet(
        isPresented: .constant(true),
        displayName: ProfileSheetL10n.previewJakeMorrison,
        username: "jakem",
        bio: ProfileSheetL10n.previewJakeBio,
        isFriend: false,
        isOnline: false,
        mutualFriendsCount: 2
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}
