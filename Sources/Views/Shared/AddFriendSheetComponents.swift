import SwiftUI

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

                        Text(result.noisePublicKey != nil ? "Keys available" : "No encryption keys")
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
                            Text("Send Friend Request")
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
                .accessibilityLabel("Send friend request to \(result.username)")
            }
        }
    }
}
