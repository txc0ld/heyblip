import SwiftUI

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
        .alert("Block User", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) {
                onBlock?()
                isPresented = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocked users cannot send you messages or see your location. You can unblock from Settings.")
        }
        .alert("Report User", isPresented: $showReportConfirm) {
            Button("Report", role: .destructive) {
                onReport?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Report this user for inappropriate behavior. This will be reviewed by the festival safety team.")
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
                    .fill(.green)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(colorScheme == .dark ? .black : .white, lineWidth: 2)
                    )
                    .offset(x: 28, y: 28)
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
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blipAccentPurple)
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
                    badge(icon: "person.fill.checkmark", text: "Friend", color: .blipAccentPurple)
                }

                if isOnline {
                    badge(icon: "wifi", text: "Online", color: BlipColors.darkColors.statusGreen)
                }

                if mutualFriendsCount > 0 {
                    badge(icon: "person.2", text: "\(mutualFriendsCount) mutual", color: theme.colors.mutedText)
                }
            }
            .padding(.top, BlipSpacing.xs)
        }
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 10))
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
            // Primary: Message
            GlassButton("Message", icon: "message.fill") {
                onMessage?()
                isPresented = false
            }
            .fullWidth()

            // Secondary row
            HStack(spacing: BlipSpacing.md) {
                if !isFriend {
                    GlassButton("Add Friend", icon: "person.badge.plus", style: .secondary, size: .small) {
                        onAddFriend?()
                    }
                }

                GlassButton(isBlocked ? "Unblock" : "Block", icon: isBlocked ? "hand.raised.slash" : "hand.raised", style: .outline, size: .small) {
                    if isBlocked {
                        onBlock?()
                    } else {
                        showBlockConfirm = true
                    }
                }

                GlassButton("Report", icon: "exclamationmark.bubble", style: .outline, size: .small) {
                    showReportConfirm = true
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
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
        displayName: "Sarah Chen",
        username: "sarahc",
        bio: "Music and mountains. Always at the front row.",
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
        displayName: "Jake Morrison",
        username: "jakem",
        bio: "Festival photographer",
        isFriend: false,
        isOnline: false,
        mutualFriendsCount: 2
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}
