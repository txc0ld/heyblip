import MapKit
import SwiftUI

private enum EventDetailL10n {
    static let notFound = String(localized: "events.detail.not_found", defaultValue: "Event not found")
    static let fallbackTitle = String(localized: "events.detail.fallback_title", defaultValue: "Event")
    static let dates = String(localized: "events.detail.dates", defaultValue: "Dates")
    static let location = String(localized: "events.detail.location", defaultValue: "Location")
    static let attendees = String(localized: "events.detail.attendees", defaultValue: "Attendees")
    static let mapUnavailable = String(localized: "events.detail.map_unavailable", defaultValue: "Map available after joining")
    static let leaveEvent = String(localized: "events.detail.leave", defaultValue: "Leave Event")
    static let joinEvent = String(localized: "events.detail.join", defaultValue: "Join Event")
    static let previewUnavailable = "Preview unavailable"
    static let previewGlastonbury = "Glastonbury 2026"
    static let previewPilton = "Pilton, Somerset"
    static let previewDescription = "The world's most famous greenfield music and performing arts festival. Five days of music, art, and culture across multiple stages."

    static func attendeeCount(_ count: Int) -> String {
        String(format: String(localized: "events.detail.attendee_count", defaultValue: "%d"), locale: Locale.current, count)
    }

    static func detailAccessibility(_ label: String, _ value: String) -> String {
        String(format: String(localized: "events.detail.accessibility_label", defaultValue: "%@: %@"), locale: Locale.current, label, value)
    }

    static func leaveAccessibility(_ name: String) -> String {
        String(format: String(localized: "events.detail.leave_accessibility_label", defaultValue: "Leave %@"), locale: Locale.current, name)
    }

    static func joinAccessibility(_ name: String) -> String {
        String(format: String(localized: "events.detail.join_accessibility_label", defaultValue: "Join %@"), locale: Locale.current, name)
    }
}

// MARK: - EventDetailView

/// Full event detail with description, dates, location, and join/leave action.
struct EventDetailView: View {

    var eventsViewModel: EventsViewModel
    let eventID: String

    @Environment(\.theme) private var theme

    var body: some View {
        if let event = event {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                    headerSection(event)
                    descriptionSection(event)
                    detailsCard(event)
                    mapSection(event)
                    joinSection(event)
                }
                .padding(BlipSpacing.md)
                .padding(.bottom, BlipSpacing.xxl)
            }
            .navigationTitle(event.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(GradientBackground().ignoresSafeArea())
        } else {
            ContentUnavailableView(EventDetailL10n.notFound, systemImage: "calendar.badge.exclamationmark")
                .navigationTitle(EventDetailL10n.fallbackTitle)
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(.hidden, for: .navigationBar)
                .background(GradientBackground().ignoresSafeArea())
        }
    }

    // MARK: - Header

    private var event: EventsViewModel.DiscoverableEvent? {
        eventsViewModel.discoveryEvents.first { $0.id == eventID }
    }

    private func headerSection(_ event: EventsViewModel.DiscoverableEvent) -> some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            Text(event.category.rawValue)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(.blipAccentPurple)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, BlipSpacing.xxs)
                .background(Capsule().fill(.blipAccentPurple.opacity(0.15)))

            Text(event.name)
                .font(.custom(BlipFontName.bold, size: 28, relativeTo: .largeTitle))
                .foregroundStyle(theme.colors.text)
        }
    }

    // MARK: - Description

    private func descriptionSection(_ event: EventsViewModel.DiscoverableEvent) -> some View {
        Group {
            if !event.description.isEmpty {
                Text(event.description)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .lineSpacing(4)
            }
        }
    }

    // MARK: - Details Card

    private func detailsCard(_ event: EventsViewModel.DiscoverableEvent) -> some View {
        GlassCard(thickness: .ultraThin) {
            VStack(spacing: BlipSpacing.md) {
                detailRow(icon: "calendar", label: EventDetailL10n.dates, value: formattedDateRange(for: event))
                Divider().opacity(0.15)
                detailRow(icon: "mappin.and.ellipse", label: EventDetailL10n.location, value: event.location)
                Divider().opacity(0.15)
                detailRow(icon: "person.2.fill", label: EventDetailL10n.attendees, value: EventDetailL10n.attendeeCount(event.attendeeCount))
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(theme.typography.secondary)
                .foregroundStyle(.blipAccentPurple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                Text(value)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(EventDetailL10n.detailAccessibility(label, value))
    }

    // MARK: - Map

    @ViewBuilder
    private func mapSection(_ event: EventsViewModel.DiscoverableEvent) -> some View {
        if event.isJoined {
            let coordinate = CLLocationCoordinate2D(latitude: event.latitude, longitude: event.longitude)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))) {
                Marker(event.name, coordinate: coordinate)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg))
            .accessibilityLabel(EventDetailL10n.location)
        } else {
            mapPlaceholder
        }
    }

    private var mapPlaceholder: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "map")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.colors.mutedText.opacity(0.5))
                Text(EventDetailL10n.mapUnavailable)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
        }
    }

    // MARK: - Join Section

    private func joinSection(_ event: EventsViewModel.DiscoverableEvent) -> some View {
        Button(action: {
            if event.isJoined {
                eventsViewModel.leaveEvent(eventID)
            } else {
                eventsViewModel.joinEvent(eventID)
            }
        }) {
            HStack {
                Image(systemName: event.isJoined ? "checkmark.circle.fill" : "plus.circle.fill")
                Text(event.isJoined ? EventDetailL10n.leaveEvent : EventDetailL10n.joinEvent)
            }
            .font(.custom(BlipFontName.semiBold, size: 17, relativeTo: .body))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.sm + 4)
            .background(
                event.isJoined
                    ? AnyShapeStyle(Color.red.opacity(0.8))
                    : AnyShapeStyle(LinearGradient.blipAccent)
            )
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.lg))
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(event.isJoined ? EventDetailL10n.leaveAccessibility(event.name) : EventDetailL10n.joinAccessibility(event.name))
    }

    // MARK: - Helpers

    private func formattedDateRange(for event: EventsViewModel.DiscoverableEvent) -> String {
        let start = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = event.endDate.formatted(date: .abbreviated, time: .omitted)
        return "\(start) – \(end)"
    }
}

// MARK: - Preview

@MainActor
private enum EventDetailViewPreviewData {

    static func makeViewModel() -> EventsViewModel? {
        guard let previewContainer = try? BlipSchema.createPreviewContainer() else {
            return nil
        }

        let previewViewModel = EventsViewModel(
            modelContainer: previewContainer,
            locationService: LocationService(),
            notificationService: NotificationService()
        )

        previewViewModel.discoveryEvents = [
            .init(
                id: "1",
                name: EventDetailL10n.previewGlastonbury,
                location: EventDetailL10n.previewPilton,
                latitude: 51.1537,
                longitude: -2.5875,
                startDate: Date(),
                endDate: Date().addingTimeInterval(3 * 86400),
                description: EventDetailL10n.previewDescription,
                imageURL: nil,
                attendeeCount: 12450,
                category: .festival,
                isJoined: false
            )
        ]

        return previewViewModel
    }
}

#Preview("Event Detail") {
    NavigationStack {
        if let previewViewModel = EventDetailViewPreviewData.makeViewModel() {
            EventDetailView(
                eventsViewModel: previewViewModel,
                eventID: "1"
            )
        } else {
            ContentUnavailableView(EventDetailL10n.previewUnavailable, systemImage: "calendar.badge.exclamationmark")
        }
    }
    .blipTheme()
}
