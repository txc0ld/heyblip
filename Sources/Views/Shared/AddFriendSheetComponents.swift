import SwiftUI

private enum AddFriendSheetComponentsL10n {
    static let keysAvailable = String(localized: "friends.add_friend.result.keys_available", defaultValue: "Keys available")
    static let noEncryptionKeys = String(localized: "friends.add_friend.result.no_encryption_keys", defaultValue: "No encryption keys")
    static let sendFriendRequest = String(localized: "friends.add_friend.result.send_request", defaultValue: "Send Friend Request")

    static func sendRequestAccessibility(_ username: String) -> String {
        String(
            format: String(localized: "friends.add_friend.result.send_request.accessibility", defaultValue: "Send friend request to %@"),
            locale: Locale.current,
            username
        )
    }
}

// MARK: - Add Friend Sheet Components

/// Extracted card components for AddFriendByUsernameSheet.
/// Keeps the main sheet file under 200 lines.
@MainActor
enum AddFriendSheetComponents {

    // MARK: - Error Card

    static func errorCard(message: String, theme: Theme) -> some View {
        GlassCard(thickness: .ultraThin) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colors.statusAmber)
                Text(message)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
            }
        }
    }

    // MARK: - Success Card

    static func successCard(message: String, theme: Theme) -> some View {
        GlassCard(thickness: .ultraThin) {
            HStack(spacing: BlipSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(theme.typography.secondary)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Result Card

    static func resultCard(
        for result: UserSyncService.RemoteLookupResult,
        isSending: Bool,
        theme: Theme,
        onSendRequest: @escaping () -> Void
    ) -> some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                HStack(spacing: BlipSpacing.sm) {
                    AvatarView(
                        imageData: nil,
                        avatarURL: result.avatarURL,
                        name: result.username,
                        size: BlipSizing.avatarMedium,
                        ringStyle: result.isVerified ? .subscriber : .none,
                        showOnlineIndicator: false
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: BlipSpacing.xs) {
                            Text(result.username)
                                .font(.custom(BlipFontName.semiBold, size: 16, relativeTo: .body))
                                .foregroundStyle(theme.colors.text)

                            if result.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.blipAccentPurple)
                            }
                        }

                        Text(result.noisePublicKey != nil ? AddFriendSheetComponentsL10n.keysAvailable : AddFriendSheetComponentsL10n.noEncryptionKeys)
                            .font(theme.typography.caption)
                            .foregroundStyle(result.noisePublicKey != nil ? .green : theme.colors.mutedText)
                    }

                    Spacer()
                }

                Button {
                    onSendRequest()
                } label: {
                    HStack {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "person.badge.plus")
                            Text(AddFriendSheetComponentsL10n.sendFriendRequest)
                        }
                    }
                    .font(.custom(BlipFontName.semiBold, size: 15, relativeTo: .body))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BlipSpacing.sm + 2)
                    .background(
                        LinearGradient.blipAccent,
                        in: RoundedRectangle(cornerRadius: BlipCornerRadius.lg)
                    )
                    .opacity(result.noisePublicKey == nil ? 0.5 : 1.0)
                }
                .disabled(isSending || result.noisePublicKey == nil)
                .accessibilityLabel(AddFriendSheetComponentsL10n.sendRequestAccessibility(result.username))
            }
        }
    }
}
