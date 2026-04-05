import SwiftUI

// MARK: - EventDiscoveryView

/// Browse and join events. Shows search, category filters, and event cards.
struct EventDiscoveryView: View {

    var eventsViewModel: EventsViewModel?

    @State private var searchText = ""
    @State private var selectedCategory: EventsViewModel.EventCategory = .all
    @State private var selectedEventID: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            categoryChips
            contentArea
        }
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedEventID) { eventID in
            if let eventsViewModel {
                EventDetailView(eventsViewModel: eventsViewModel, eventID: eventID)
            } else {
                ContentUnavailableView("Event not found", systemImage: "calendar.badge.exclamationmark")
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.colors.mutedText)
            TextField("Search events...", text: $searchText)
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
        .accessibilityLabel("Search events")
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
                    .accessibilityLabel("Filter by \(category.rawValue)")
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
            Text("Loading events...").font(theme.typography.secondary).foregroundStyle(theme.colors.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(theme.colors.mutedText.opacity(0.5))
            Text(message).font(theme.typography.secondary).foregroundStyle(theme.colors.mutedText).multilineTextAlignment(.center)
            GlassButton("Retry", icon: "arrow.clockwise") { Task { await eventsViewModel?.fetchDiscoveryEvents() } }
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(.horizontal, BlipSpacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: BlipSpacing.lg) {
            Spacer()
            Image(systemName: "calendar.badge.plus").font(.system(size: 48)).foregroundStyle(theme.colors.mutedText.opacity(0.5))
            Text("No events found").font(theme.typography.headline).foregroundStyle(theme.colors.text)
            Text("Check back later for upcoming events\nin your area.").font(theme.typography.secondary).foregroundStyle(theme.colors.mutedText).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity).staggeredReveal(index: 0)
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
