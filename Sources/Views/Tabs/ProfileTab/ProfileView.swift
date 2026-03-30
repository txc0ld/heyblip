import SwiftUI
import SwiftData

// MARK: - ProfileView

/// Main profile tab showing user avatar, name, username, bio,
/// verified badge, SOS, message pack balance, and quick action cards.
/// Wired to SwiftData for real user data.
struct ProfileView: View {

    var profileViewModel: ProfileViewModel? = nil
    var onSignOut: (() -> Void)? = nil

    @Query private var users: [User]

    @State private var showEditProfile = false
    @State private var showFriends = false
    @State private var showSettings = false
    @State private var showMessageStore = false
    @State private var showQRCode = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The local user (first User in SwiftData).
    private var user: User? { profileViewModel?.currentUser ?? users.first }
    private var resolvedMessageBalance: Int { profileViewModel?.messageBalance ?? 0 }

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
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .accessibilityLabel("Settings")
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
                }
            }
            .sheet(isPresented: $showFriends) {
                NavigationStack {
                    FriendsListView()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
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
            }
            .sheet(isPresented: $showMessageStore, onDismiss: {
                Task {
                    await profileViewModel?.loadProfile()
                }
            }) {
                NavigationStack {
                    MessagePackStore()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showQRCode) {
                if let user {
                    QRCodeSheet(user: user)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                }
            }
            .task {
                await profileViewModel?.loadProfile()
            }
            .onChange(of: showMessageStore) { _, isPresented in
                guard !isPresented else { return }
                Task {
                    await profileViewModel?.loadProfile()
                }
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

                balanceCard
                    .staggeredReveal(index: 2)

                quickActions(user)
                    .staggeredReveal(index: 3)

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

            Text("No profile found")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Text("Complete setup to create your profile")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Avatar Section

    private func avatarSection(_ user: User) -> some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.md) {
                // Large avatar with verified badge
                ZStack {
                    if let thumbData = user.avatarThumbnail,
                       let uiImage = UIImage(data: thumbData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(LinearGradient.blipAccent)
                            .frame(width: BlipSizing.avatarLarge, height: BlipSizing.avatarLarge)
                            .overlay(
                                Text(String(user.resolvedDisplayName.prefix(1)).uppercased())
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                    }

                    // Verified ring
                    if user.isVerified {
                        Circle()
                            .stroke(Color.blue, lineWidth: 3)
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
                            .font(.system(size: 24))
                            .foregroundStyle(.blipAccentPurple)
                            .background(Circle().fill(colorScheme == .dark ? .black : .white).frame(width: 22, height: 22))
                    }
                    .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
                    .offset(x: 28, y: 28)
                    .accessibilityLabel("Edit profile picture")
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

                // Action buttons
                HStack(spacing: BlipSpacing.md) {
                    GlassButton("Edit Profile", icon: "pencil", style: .secondary, size: .small) {
                        showEditProfile = true
                    }

                    if !user.isVerified {
                        verificationUnavailableBadge
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        Button(action: { showMessageStore = true }) {
            GlassCard(thickness: .regular) {
                HStack(spacing: BlipSpacing.md) {
                    VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                        Text("Message Balance")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)

                        HStack(alignment: .firstTextBaseline, spacing: BlipSpacing.xs) {
                            Text("\(resolvedMessageBalance)")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.blipAccentPurple)
                                .contentTransition(.numericText())

                            Text("messages left")
                                .font(theme.typography.secondary)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                    }

                    Spacer()

                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blipAccentPurple)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, BlipSpacing.md)
        .accessibilityLabel("Message balance: \(resolvedMessageBalance) messages left. Tap to buy more.")
    }

    // MARK: - Quick Actions

    private func quickActions(_ user: User) -> some View {
        VStack(spacing: BlipSpacing.md) {
            HStack(spacing: BlipSpacing.md) {
                quickActionCard(icon: "person.2.fill", title: "Friends", subtitle: "\(user.friends.count) friends") {
                    showFriends = true
                }

                quickActionCard(icon: "gearshape.fill", title: "Settings", subtitle: "Preferences") {
                    showSettings = true
                }
            }

            HStack(spacing: BlipSpacing.md) {
                quickActionCard(icon: "bag.fill", title: "Message Packs", subtitle: "\(resolvedMessageBalance) left") {
                    showMessageStore = true
                }

                quickActionCard(icon: "qrcode", title: "My QR Code", subtitle: "Share profile") {
                    showQRCode = true
                }
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    private func quickActionCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassCard(thickness: .regular, cornerRadius: BlipCornerRadius.xl) {
                VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
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

    private var verificationUnavailableBadge: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "lock.slash")
                .font(.system(size: 12, weight: .medium))
            Text("Verification unavailable")
                .font(theme.typography.caption)
        }
        .foregroundStyle(theme.colors.mutedText)
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(
            Capsule()
                .fill(theme.colors.hover)
        )
        .accessibilityLabel("Verification unavailable in this build")
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
