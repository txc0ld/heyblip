import SwiftUI

private enum EventDiscoveryL10n {
    static let title = String(localized: "events.discovery.title", defaultValue: "Events")
    static let notFound = String(localized: "events.discovery.not_found", defaultValue: "Event not found")
    static let searchPlaceholder = String(localized: "events.discovery.search.placeholder", defaultValue: "Search events...")
    static let searchAccessibility = String(localized: "events.discovery.search.accessibility", defaultValue: "Search events")
    static let loading = String(localized: "events.discovery.loading", defaultValue: "Loading events...")
    static let retry = String(localized: "common.retry", defaultValue: "Retry")
    static let emptyTitle = String(localized: "events.discovery.empty.title", defaultValue: "No events found")
    static let emptySubtitle = String(localized: "events.discovery.empty.subtitle", defaultValue: "Check back later for upcoming events\nin your area.")
    static let createChannel = String(localized: "events.discovery.create_channel.label", defaultValue: "Create channel")

    static func filterBy(_ category: String) -> String {
        String(
            format: String(localized: "events.discovery.filter.accessibility", defaultValue: "Filter by %@"),
            locale: Locale.current,
            category
        )
    }
}

// MARK: - EventDiscoveryView

/// Browse and join events. Shows search, category filters, and event cards.
struct EventDiscoveryView: View {

    var eventsViewModel: EventsViewModel?

    @State private var searchText = ""
    @State private var selectedCategory: EventsViewModel.EventCategory = .all
    @State private var selectedEventID: String?
    @State private var showCreateChannelSheet = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            categoryChips
            contentArea
        }
        .navigationTitle(EventDiscoveryL10n.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateChannelSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(theme.typography.title3)
                        .foregroundStyle(Color.blipAccentPurple)
                }
                .accessibilityLabel(EventDiscoveryL10n.createChannel)
            }
        }
        .sheet(isPresented: $showCreateChannelSheet) {
            CreateChannelSheet(eventsViewModel: eventsViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $selectedEventID) { eventID in
            if let eventsViewModel {
                EventDetailView(eventsViewModel: eventsViewModel, eventID: eventID)
            } else {
                ContentUnavailableView(EventDiscoveryL10n.notFound, systemImage: "calendar.badge.exclamationmark")
            }
        }
        .task {
            await eventsViewModel?.fetchDiscoveryEvents()
        }
        .refreshable {
            await eventsViewModel?.fetchDiscoveryEvents()
        }
        .onChange(of: searchText) { _, newValue in
            eventsViewModel?.discoverySearchText = newValue
        }
        .onChange(of: selectedCategory) { _, newValue in
            eventsViewModel?.selectedCategory = newValue
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(theme.typography.footnote)
                .foregroundStyle(theme.colors.mutedText)
            TextField(EventDiscoveryL10n.searchPlaceholder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.custom(BlipFontName.regular, size: 16, relativeTo: .body))
        }
        .padding(.horizontal, BlipSpacing.md)
        .padding(.vertical, BlipSpacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, BlipSpacing.md)
        .padding(.top, BlipSpacing.sm)
        .accessibilityLabel(EventDiscoveryL10n.searchAccessibility)
    }

    // MARK: - Category Chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlipSpacing.xs) {
                ForEach(EventsViewModel.EventCategory.allCases, id: \.self) { category in
                    Button {
                        withAnimation(SpringConstants.accessibleSnappy) {
                            selectedCategory = category
                        }
                    } label: {
                        Text(category.rawValue)
                            .font(.custom(BlipFontName.medium, size: 13, relativeTo: .footnote))
                            .foregroundStyle(selectedCategory == category ? .white : theme.colors.text)
                            .padding(.horizontal, BlipSpacing.md)
                            .padding(.vertical, BlipSpacing.sm)
                            .background(
                                selectedCategory == category
                                    ? AnyShapeStyle(.blipAccentPurple)
                                    : AnyShapeStyle(.ultraThinMaterial)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(EventDiscoveryL10n.filterBy(category.rawValue))
                    .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        let events = eventsViewModel?.filteredDiscoveryEvents ?? []
        let state = eventsViewModel?.discoveryState ?? .idle

        if state == .fetching {
            loadingState
        } else if case .failed(let message) = state {
            errorState(message)
        } else if events.isEmpty {
            emptyState
        } else {
            eventList(events)
        }
    }

    private func eventList(_ events: [EventsViewModel.DiscoverableEvent]) -> some View {
        ScrollView {
            LazyVStack(spacing: BlipSpacing.sm) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    EventCard(
                        event: event,
                        onJoinToggle: { toggleJoin(event) },
                        onTap: { selectedEventID = event.id }
                    )
                    .staggeredReveal(index: index)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.bottom, 100)
        }
    }

    private var loadingState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            ProgressView().controlSize(.large).tint(.blipAccentPurple)
            Text(EventDiscoveryL10n.loading).font(theme.typography.secondary).foregroundStyle(theme.colors.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(theme.colors.mutedText.opacity(0.5))
            Text(message).font(theme.typography.secondary).foregroundStyle(theme.colors.mutedText).multilineTextAlignment(.center)
            GlassButton(EventDiscoveryL10n.retry, icon: "arrow.clockwise") { Task { await eventsViewModel?.fetchDiscoveryEvents() } }
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(.horizontal, BlipSpacing.md)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "calendar.badge.plus",
            title: EventDiscoveryL10n.emptyTitle,
            subtitle: EventDiscoveryL10n.emptySubtitle
        )
        .staggeredReveal(index: 0)
    }

    // MARK: - Actions

    private func toggleJoin(_ event: EventsViewModel.DiscoverableEvent) {
        if event.isJoined {
            eventsViewModel?.leaveEvent(event.id)
        } else {
            eventsViewModel?.joinEvent(event.id)
        }
    }
}

// MARK: - Preview

#Preview("Event Discovery") {
    NavigationStack {
        EventDiscoveryView()
    }
    .blipTheme()
}
