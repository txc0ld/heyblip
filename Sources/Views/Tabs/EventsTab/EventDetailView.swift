import SwiftUI

// MARK: - EventDetailView

/// Full event detail with description, dates, location, and join/leave action.
struct EventDetailView: View {

    let event: EventsViewModel.DiscoverableEvent
    let onJoinToggle: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlipSpacing.lg) {
                headerSection
                descriptionSection
                detailsCard
                mapPlaceholder
                joinSection
            }
            .padding(BlipSpacing.md)
            .padding(.bottom, BlipSpacing.xxl)
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(GradientBackground().ignoresSafeArea())
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            Text(event.category.rawValue)
                .font(.custom(BlipFontName.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(.blipAccentPurple)
                .padding(.horizontal, BlipSpacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(.blipAccentPurple.opacity(0.15)))

            Text(event.name)
                .font(.custom(BlipFontName.bold, size: 28, relativeTo: .largeTitle))
                .foregroundStyle(theme.colors.text)
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
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

    private var detailsCard: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(spacing: BlipSpacing.md) {
                detailRow(icon: "calendar", label: "Dates", value: formattedDateRange)
                Divider().opacity(0.15)
                detailRow(icon: "mappin.and.ellipse", label: "Location", value: event.location)
                Divider().opacity(0.15)
                detailRow(icon: "person.2.fill", label: "Attendees", value: "\(event.attendeeCount)")
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: BlipSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
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
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Map Placeholder

    private var mapPlaceholder: some View {
        GlassCard(thickness: .ultraThin) {
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "map")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.colors.mutedText.opacity(0.5))
                Text("Map available after joining")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
        }
    }

    // MARK: - Join Section

    private var joinSection: some View {
        Button(action: onJoinToggle) {
            HStack {
                Image(systemName: event.isJoined ? "checkmark.circle.fill" : "plus.circle.fill")
                Text(event.isJoined ? "Leave Event" : "Join Event")
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
        .accessibilityLabel(event.isJoined ? "Leave \(event.name)" : "Join \(event.name)")
    }

    // MARK: - Helpers

    private var formattedDateRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        let start = formatter.string(from: event.startDate)
        let end = formatter.string(from: event.endDate)
        return "\(start) – \(end)"
    }
}

// MARK: - Preview

#Preview("Event Detail") {
    NavigationStack {
        EventDetailView(
            event: .init(
                id: "1", name: "Glastonbury 2026", location: "Pilton, Somerset",
                startDate: Date(), endDate: Date().addingTimeInterval(3 * 86400),
                description: "The world's most famous greenfield music and performing arts festival. Five days of music, art, and culture across multiple stages.",
                imageURL: nil, attendeeCount: 12450, category: .festival, isJoined: false
            ),
            onJoinToggle: {}
        )
    }
    .blipTheme()
}
