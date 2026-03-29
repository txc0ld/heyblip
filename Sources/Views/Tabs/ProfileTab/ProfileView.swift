import SwiftUI
import SwiftData

// MARK: - ProfileView

/// Main profile tab showing user avatar, name, username, bio,
/// verified badge, SOS, message pack balance, and quick action cards.
/// Wired to SwiftData for real user data.
struct ProfileView: View {

    @Query private var users: [User]
    @AppStorage("messageBalance") private var messageBalance: Int = 0

    @State private var showEditProfile = false
    @State private var showFriends = false
    @State private var showSettings = false
    @State private var showMessageStore = false
    @State private var showVerifiedSheet = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The local user (first User in SwiftData).
    private var user: User? { users.first }

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
                    .frame(minWidth: FCSizing.minTapTarget, minHeight: FCSizing.minTapTarget)
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
                    SettingsView()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showMessageStore) {
                NavigationStack {
                    MessagePackStore()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showVerifiedSheet) {
                VerifiedProfileSheet(isPresented: $showVerifiedSheet)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    // MARK: - User Content

    private func userContent(_ user: User) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: FCSpacing.lg) {
                avatarSection(user)
                    .staggeredReveal(index: 0)

                SOSButton.ProfileCard()
                    .padding(.horizontal, FCSpacing.md)
                    .staggeredReveal(index: 1)

                balanceCard
                    .staggeredReveal(index: 2)

                quickActions(user)
                    .staggeredReveal(index: 3)

                Spacer().frame(height: FCSpacing.xxl)
            }
            .padding(.top, FCSpacing.md)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: FCSpacing.lg) {
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
            VStack(spacing: FCSpacing.md) {
                // Large avatar with verified badge
                ZStack {
                    if let thumbData = user.avatarThumbnail,
                       let uiImage = UIImage(data: thumbData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: FCSizing.avatarLarge, height: FCSizing.avatarLarge)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(LinearGradient.fcAccent)
                            .frame(width: FCSizing.avatarLarge, height: FCSizing.avatarLarge)
                            .overlay(
                                Text(String(user.resolvedDisplayName.prefix(1)).uppercased())
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                    }

                    // Verified ring
                    if user.isVerified {
                        Circle()
                            .stroke(LinearGradient.fcAccent, lineWidth: 3)
                            .frame(width: FCSizing.avatarLarge + 8, height: FCSizing.avatarLarge + 8)

                        // Verified badge
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.fcAccentPurple)
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
                            .foregroundStyle(.fcAccentPurple)
                            .background(Circle().fill(colorScheme == .dark ? .black : .white).frame(width: 22, height: 22))
                    }
                    .frame(minWidth: FCSizing.minTapTarget, minHeight: FCSizing.minTapTarget)
                    .offset(x: 28, y: 28)
                    .accessibilityLabel("Edit profile picture")
                }

                // Name and username
                VStack(spacing: FCSpacing.xs) {
                    HStack(spacing: FCSpacing.xs) {
                        Text(user.resolvedDisplayName)
                            .font(theme.typography.headline)
                            .foregroundStyle(theme.colors.text)

                        if user.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.fcAccentPurple)
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
                HStack(spacing: FCSpacing.md) {
                    GlassButton("Edit Profile", icon: "pencil", style: .secondary, size: .small) {
                        showEditProfile = true
                    }

                    if !user.isVerified {
                        GlassButton("Get Verified", icon: "checkmark.seal", style: .outline, size: .small) {
                            showVerifiedSheet = true
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, FCSpacing.md)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        Button(action: { showMessageStore = true }) {
            GlassCard(thickness: .regular) {
                HStack(spacing: FCSpacing.md) {
                    VStack(alignment: .leading, spacing: FCSpacing.xs) {
                        Text("Message Balance")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)

                        HStack(alignment: .firstTextBaseline, spacing: FCSpacing.xs) {
                            Text("\(messageBalance)")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.fcAccentPurple)
                                .contentTransition(.numericText())

                            Text("messages left")
                                .font(theme.typography.secondary)
                                .foregroundStyle(theme.colors.mutedText)
                        }
                    }

                    Spacer()

                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.fcAccentPurple)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, FCSpacing.md)
        .accessibilityLabel("Message balance: \(messageBalance) messages left. Tap to buy more.")
    }

    // MARK: - Quick Actions

    private func quickActions(_ user: User) -> some View {
        VStack(spacing: FCSpacing.md) {
            HStack(spacing: FCSpacing.md) {
                quickActionCard(icon: "person.2.fill", title: "Friends", subtitle: "\(user.friends.count) friends") {
                    showFriends = true
                }

                quickActionCard(icon: "gearshape.fill", title: "Settings", subtitle: "Preferences") {
                    showSettings = true
                }
            }

            HStack(spacing: FCSpacing.md) {
                quickActionCard(icon: "bag.fill", title: "Message Packs", subtitle: "\(messageBalance) left") {
                    showMessageStore = true
                }

                quickActionCard(icon: "qrcode", title: "My QR Code", subtitle: "Share profile") {
                    // Share QR code
                }
            }
        }
        .padding(.horizontal, FCSpacing.md)
    }

    private func quickActionCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassCard(thickness: .regular, cornerRadius: FCCornerRadius.xl) {
                VStack(alignment: .leading, spacing: FCSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(.fcAccentPurple)

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
        .frame(minHeight: FCSizing.minTapTarget)
        .accessibilityLabel("\(title): \(subtitle)")
    }
}

// MARK: - Preview

#Preview("Profile Tab") {
    ProfileView()
        .preferredColorScheme(.dark)
        .festiChatTheme()
}

#Preview("Profile Tab - Light") {
    ProfileView()
        .preferredColorScheme(.light)
        .festiChatTheme()
}
