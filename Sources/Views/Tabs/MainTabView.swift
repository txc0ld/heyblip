import SwiftUI

private enum MainTabViewL10n {
    static let nearbyTitle = String(localized: "main_tab.placeholder.nearby.title", defaultValue: "Nearby")
    static let nearbySubtitle = String(localized: "main_tab.placeholder.nearby.subtitle", defaultValue: "Discover people and channels nearby.")
    static let eventTitle = String(localized: "main_tab.placeholder.event.title", defaultValue: "Event")
    static let eventSubtitle = String(localized: "main_tab.placeholder.event.subtitle", defaultValue: "Stage map, schedule, and announcements.")
    static let profileTitle = String(localized: "main_tab.placeholder.profile.title", defaultValue: "Profile")
    static let profileSubtitle = String(localized: "main_tab.placeholder.profile.subtitle", defaultValue: "Your profile, friends, and settings.")
    static let chatsTab = String(localized: "main_tab.tab.chats", defaultValue: "Chats")
    static let nearbyTab = String(localized: "main_tab.tab.nearby", defaultValue: "Nearby")
    static let eventTab = String(localized: "main_tab.tab.event", defaultValue: "Event")
    static let profileTab = String(localized: "main_tab.tab.profile", defaultValue: "Profile")
}

// MARK: - MainTabView

/// Root tab navigation with a custom floating glass tab bar.
/// Tabs: Chats, Nearby, Event, Profile.
/// Keeps each tab mounted so navigation state and injected feature models are preserved.
struct MainTabView: View {

    @State private var selectedTab: Tab = .chats
    @State private var showConnectionBanner = false
    @State private var connectedPeerCount = 0
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let coordinator: AppCoordinator

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
        .overlay(alignment: .top) {
            if coordinator.registrationSyncPending {
                RegistrationBanner(coordinator: coordinator)
                    .padding(.horizontal, BlipSpacing.md)
                    .padding(.top, BlipSpacing.sm)
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: coordinator.registrationSyncPending)
    }

    // MARK: - Tab Content

    private var tabContent: some View {
        ZStack {
            tabLayer(.chats) {
                ChatListView(chatViewModel: coordinator.chatViewModel)
            }
            tabLayer(.nearby) {
                NearbyView(
                    meshViewModel: coordinator.meshViewModel,
                    locationViewModel: coordinator.locationViewModel
                )
            }
            tabLayer(.event) {
                EventsView(eventsViewModel: coordinator.eventsViewModel)
            }
            tabLayer(.profile) {
                ProfileView(
                    profileViewModel: coordinator.profileViewModel,
                    storeViewModel: coordinator.storeViewModel,
                    onSignOut: { coordinator.signOut() }
                )
            }
        }
        .animation(SpringConstants.accessiblePageEntrance, value: selectedTab)
    }

    private func tabLayer<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .zIndex(selectedTab == tab ? 1 : 0)
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
                    // Accent gradient glow behind active tab
                    if selectedTab == tab {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.40, green: 0.0, blue: 1.0).opacity(0.25),
                                        Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.15)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                            .blur(radius: 8)
                    }

                    Image(systemName: tab.icon)
                        .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(
                            selectedTab == tab
                                ? Color.blipAccentPurple
                                : theme.colors.tertiaryText
                        )
                        .scaleEffect(selectedTab == tab ? 1.08 : 1.0)
                        .animation(SpringConstants.bouncyAnimation, value: selectedTab)
                        .frame(width: BlipSizing.minTapTarget, height: 32)
                }

                Text(tab.title)
                    .font(.custom(BlipFontName.medium, size: 10, relativeTo: .caption2))
                    .foregroundStyle(
                        selectedTab == tab
                            ? Color.blipAccentPurple
                            : theme.colors.tertiaryText
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
        [.chats, .nearby, .event, .profile]
    }

    private let tabBarHeight: CGFloat = 70

    // MARK: - Placeholder Views

    private var nearbyPlaceholder: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)
            Text(MainTabViewL10n.nearbyTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text(MainTabViewL10n.nearbySubtitle)
                .font(theme.typography.secondary)
                .foregroundStyle(theme.colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventPlaceholder: some View {
        VStack(spacing: BlipSpacing.lg) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.mutedText)
            Text(MainTabViewL10n.eventTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text(MainTabViewL10n.eventSubtitle)
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
            Text(MainTabViewL10n.profileTitle)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)
            Text(MainTabViewL10n.profileSubtitle)
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
        case event
        case profile

        var title: String {
            switch self {
            case .chats: return MainTabViewL10n.chatsTab
            case .nearby: return MainTabViewL10n.nearbyTab
            case .event: return MainTabViewL10n.eventTab
            case .profile: return MainTabViewL10n.profileTab
            }
        }

        var icon: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right.fill"
            case .nearby: return "antenna.radiowaves.left.and.right"
            case .event: return "music.note.house.fill"
            case .profile: return "person.circle.fill"
            }
        }
    }
}

// MARK: - Preview

#Preview("Main Tab View") {
    MainTabView(coordinator: AppCoordinator())
        .environment(\.theme, Theme.shared)
}

#Preview("Main Tab View - With Event") {
    MainTabView(coordinator: AppCoordinator())
        .environment(\.theme, Theme.shared)
}

#Preview("Main Tab View - Light") {
    MainTabView(coordinator: AppCoordinator())
        .environment(\.theme, Theme.resolved(for: .light))
        .preferredColorScheme(.light)
}
