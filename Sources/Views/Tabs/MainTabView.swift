import SwiftUI

// MARK: - MainTabView

/// Root tab navigation with a custom floating glass tab bar.
/// Tabs: Chats, Nearby, Festival (conditional), Profile.
/// SOSButton overlay in the top-right of every tab.
struct MainTabView: View {

    @State private var selectedTab: Tab = .chats
    @State private var showConnectionBanner = false
    @State private var connectedPeerCount = 0
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// Whether the user is currently at a festival (controls Festival tab visibility).
    var isAtFestival: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            GradientBackground()
                .ignoresSafeArea()

            // Tab content
            tabContent
                .padding(.bottom, tabBarHeight + BlipSpacing.sm)

            // Custom glass tab bar
            floatingTabBar
        }
        .connectionBanner(peerCount: connectedPeerCount, isVisible: $showConnectionBanner)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .chats:
            ChatListView()
                .transition(.opacity)
        case .nearby:
            NearbyView()
                .transition(.opacity)
        case .festival:
            FestivalView()
                .transition(.opacity)
        case .profile:
            ProfileView()
                .transition(.opacity)
        }
    }

    // MARK: - Floating Glass Tab Bar

    private var floatingTabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                tabBarItem(for: tab)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm)
        .background(tabBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.xxl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xxl, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.08),
                    lineWidth: BlipSizing.hairline
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .padding(.horizontal, BlipSpacing.lg)
        .padding(.bottom, BlipSpacing.sm)
    }

    private func tabBarItem(for tab: Tab) -> some View {
        Button {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                selectedTab = tab
            }
            BlipHaptics.lightImpact()
        } label: {
            VStack(spacing: BlipSpacing.xs) {
                ZStack {
                    // Accent glow behind active tab
                    if selectedTab == tab {
                        Circle()
                            .fill(Color.blipAccentPurple.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .blur(radius: 8)
                    }

                    Image(systemName: tab.icon)
                        .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(
                            selectedTab == tab
                                ? Color.blipAccentPurple
                                : theme.colors.mutedText
                        )
                        .scaleEffect(selectedTab == tab ? 1.1 : 1.0)
                        .animation(SpringConstants.bouncyAnimation, value: selectedTab)
                        .frame(width: BlipSizing.minTapTarget, height: 32)
                }

                Text(tab.title)
                    .font(.custom(BlipFontName.medium, size: 10, relativeTo: .caption2))
                    .foregroundStyle(
                        selectedTab == tab
                            ? Color.blipAccentPurple
                            : theme.colors.mutedText
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BlipSizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var tabBarBackground: some View {
        RoundedRectangle(cornerRadius: BlipCornerRadius.xxl, style: .continuous)
            .fill(.thickMaterial)
    }

    // MARK: - Tab Configuration

    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.chats, .nearby]
        if isAtFestival {
            tabs.append(.festival)
        }
        tabs.append(.profile)
        return tabs
    }

    private let tabBarHeight: CGFloat = 70

    // MARK: - Placeholder Views

    private var nearbyPlaceholder: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)
            Text("Nearby")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text("Discover people and channels nearby.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var festivalPlaceholder: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)
            Text("Festival")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text("Stage map, schedule, and announcements.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profilePlaceholder: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)
            Text("Profile")
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text("Your profile, friends, and settings.")
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab enum

extension MainTabView {

    enum Tab: String, CaseIterable, Hashable {
        case chats
        case nearby
        case festival
        case profile

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .nearby: return "Nearby"
            case .festival: return "Festival"
            case .profile: return "Profile"
            }
        }

        var icon: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right.fill"
            case .nearby: return "antenna.radiowaves.left.and.right"
            case .festival: return "music.note.house.fill"
            case .profile: return "person.circle.fill"
            }
        }
    }
}

// MARK: - Preview

#Preview("Main Tab View") {
    MainTabView()
        .environment(\.theme, Theme.shared)
}

#Preview("Main Tab View - With Festival") {
    MainTabView(isAtFestival: true)
        .environment(\.theme, Theme.shared)
}

#Preview("Main Tab View - Light") {
    MainTabView()
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}
