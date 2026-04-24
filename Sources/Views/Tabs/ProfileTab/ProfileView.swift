import SwiftUI
import SwiftData

private enum ProfileViewL10n {
    static let title = String(localized: "profile.title", defaultValue: "Profile")
    static let settings = String(localized: "common.settings", defaultValue: "Settings")
    static let friends = String(localized: "common.friends", defaultValue: "Friends")
    static let noProfile = String(localized: "profile.empty.title", defaultValue: "No profile found")
    static let noProfileSubtitle = String(localized: "profile.empty.subtitle", defaultValue: "Complete setup to create your profile")
    static let editPicture = String(localized: "profile.edit_picture", defaultValue: "Edit profile picture")
    static let editProfile = String(localized: "profile.edit.cta", defaultValue: "Edit Profile")
    static let preferences = String(localized: "profile.quick_actions.preferences", defaultValue: "Preferences")
    static let myQRCode = String(localized: "profile.quick_actions.qr_code.title", defaultValue: "My QR Code")
    static let shareProfile = String(localized: "profile.quick_actions.qr_code.subtitle", defaultValue: "Share profile")
    static let verificationSoon = String(localized: "profile.verification_soon", defaultValue: "Verification coming soon")
    static let verificationUnavailable = String(localized: "profile.verification_unavailable", defaultValue: "Verification unavailable in this build")
}

// MARK: - ProfileView

/// Main profile tab showing user avatar, name, username, bio,
/// verified badge, SOS, message pack balance, and quick action cards.
/// Wired to SwiftData for real user data.
struct ProfileView: View {

    var profileViewModel: ProfileViewModel? = nil
    var storeViewModel: StoreViewModel? = nil
    var onSignOut: (() -> Bool)? = nil

    @Query private var users: [User]

    @State private var showEditProfile = false
    @State private var showFriends = false
    @State private var showSettings = false
    @State private var showQRCode = false
    @State private var showNotifications = false

    /// Sheets with `.presentationBackground(.ultraThinMaterial)` create their own
    /// presentation scene that doesn't always inherit the root window's
    /// `preferredColorScheme` — so we re-apply it on the sheet content below to
    /// keep the translucent material on the user's chosen theme.
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The local user (first User in SwiftData).
    private var user: User? { profileViewModel?.currentUser ?? users.first }
    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                if let user {
                    userContent(user)
                } else {
                    emptyState
                }
            }
            .navigationTitle(ProfileViewL10n.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(theme.typography.callout)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel(ProfileViewL10n.settings)
                }
            }
            .sheet(isPresented: $showEditProfile) {
                if let user {
                    EditProfileView(
                        isPresented: $showEditProfile,
                        displayName: user.resolvedDisplayName,
                        username: user.username,
                        bio: user.bio ?? ""
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
                    .preferredColorScheme(appTheme.colorScheme)
                }
            }
            .sheet(isPresented: $showFriends) {
                NavigationStack {
                    FriendsListView()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(appTheme.colorScheme)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView(
                        profileViewModel: profileViewModel,
                        onSignOut: onSignOut
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(appTheme.colorScheme)
            }
            .sheet(isPresented: $showQRCode) {
                if let user {
                    QRCodeSheet(user: user)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                        .preferredColorScheme(appTheme.colorScheme)
                }
            }
            .sheet(isPresented: $showNotifications) {
                NavigationStack {
                    NotificationsSettingsView()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(appTheme.colorScheme)
            }
            .task {
                await profileViewModel?.loadProfile()
            }
            .onChange(of: showSettings) { _, isPresented in
                guard !isPresented else { return }
                Task {
                    await profileViewModel?.loadProfile()
                }
            }
        }
    }

    // MARK: - User Content

    private func userContent(_ user: User) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: BlipSpacing.lg) {
                avatarSection(user)
                    .staggeredReveal(index: 0)

                SOSButton.ProfileCard()
                    .padding(.horizontal, BlipSpacing.md)
                    .staggeredReveal(index: 1)

                quickActions(user)
                    .staggeredReveal(index: 2)

                Spacer().frame(height: BlipSpacing.xxl)
            }
            .padding(.top, BlipSpacing.md)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "person.circle")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)

            Text(ProfileViewL10n.noProfile)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text(ProfileViewL10n.noProfileSubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Avatar Section

    private func avatarSection(_ user: User) -> some View {
        GlassCard(elevation: .floating) {
            VStack(spacing: BlipSpacing.md) {
                // Large avatar with verified badge and glass ring
                ZStack {
                    if let thumbData = user.avatarThumbnail,
                       let uiImage = UIImage(data: thumbData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 2
                                    )
                            )
                    } else {
                        Circle()
                            .fill(LinearGradient.blipAccent)
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .overlay(
                                Text(String(user.resolvedDisplayName.prefix(1)).uppercased())
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 2
                                    )
                            )
                    }

                    // Verified ring
                    if user.isVerified {
                        Circle()
                            .stroke(Color.blipAccentPurple, lineWidth: 3)
                            .frame(width: BlipSizing.avatarLarge + 8, height: BlipSizing.avatarLarge + 8)

                        // Verified badge (Meta/Instagram style — blue seal, white tick)
                        VerifiedBadge(size: 22)
                            .background(
                                Circle()
                                    .fill(colorScheme == .dark ? .black : .white)
                                    .frame(width: 20, height: 20)
                            )
                            .offset(x: 30, y: -30)
                    }

                    // Edit button
                    Button(action: { showEditProfile = true }) {
                        Image(systemName: "pencil.circle.fill")
                            .font(theme.typography.title2)
                            .foregroundStyle(.blipAccentPurple)
                            .background(Circle().fill(colorScheme == .dark ? .black : .white).frame(width: 22, height: 22))
                    }
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .offset(x: 28, y: 28)
                    .accessibilityLabel(ProfileViewL10n.editPicture)
                }

                // Name and username
                VStack(spacing: BlipSpacing.xs) {
                    HStack(spacing: BlipSpacing.xs) {
                        Text(user.resolvedDisplayName)
                            .font(theme.typography.headline)
                            .foregroundStyle(theme.colors.text)

                        if user.isVerified {
                            VerifiedBadge(size: 14)
                        }
                    }

                    Text("@\(user.username)")
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                }

                // Bio
                if let bio = user.bio, !bio.isEmpty {
                    Text(bio)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.mutedText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                // Working action — Edit Profile stands alone to read as
                // the primary, shipped action for this section.
                GlassButton(ProfileViewL10n.editProfile, icon: "pencil", style: .secondary, size: .small) {
                    showEditProfile = true
                }

                // Verification is not yet available — kept as a small muted
                // note below the working action so it doesn't compete for
                // visual weight.
                if !user.isVerified {
                    verificationUnavailableNote
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    // MARK: - Quick Actions

    private func quickActions(_ user: User) -> some View {
        VStack(spacing: BlipSpacing.md) {
            HStack(spacing: BlipSpacing.md) {
                quickActionCard(icon: "person.2.fill", title: ProfileViewL10n.friends, subtitle: "\(user.friends.count) friends") {
                    showFriends = true
                }

                quickActionCard(icon: "gearshape.fill", title: ProfileViewL10n.settings, subtitle: ProfileViewL10n.preferences) {
                    showSettings = true
                }
            }

            HStack(spacing: BlipSpacing.md) {
                quickActionCard(icon: "qrcode", title: ProfileViewL10n.myQRCode, subtitle: ProfileViewL10n.shareProfile) {
                    showQRCode = true
                }

                quickActionCard(
                    icon: "bell.fill",
                    title: String(localized: "profile.quick_actions.notifications.title", defaultValue: "Notifications"),
                    subtitle: String(localized: "profile.quick_actions.notifications.subtitle", defaultValue: "Mutes & quiet hours")
                ) {
                    showNotifications = true
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    private func quickActionCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassCard(elevation: .raised, cornerRadius: BlipCornerRadius.xl) {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    Image(systemName: icon)
                        .font(theme.typography.headline)
                        .foregroundStyle(.blipAccentPurple)

                    Text(title)
                        .font(theme.typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.text)

                    Text(subtitle)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(title): \(subtitle)")
    }

    private var verificationUnavailableNote: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "clock")
                .font(theme.typography.caption2)
            Text(ProfileViewL10n.verificationSoon)
                .font(theme.typography.caption)
        }
        .foregroundStyle(theme.colors.mutedText.opacity(0.7))
        .accessibilityLabel(ProfileViewL10n.verificationUnavailable)
    }
}

// MARK: - Preview

#Preview("Profile Tab") {
    ProfileView()
        .preferredColorScheme(.dark)
        .blipTheme()
}

#Preview("Profile Tab - Light") {
    ProfileView()
        .preferredColorScheme(.light)
        .blipTheme()
}
