import SwiftUI

// MARK: - EventCard

/// Glassmorphism card for browsing events in the discovery tab.
struct EventCard: View {

    let event: EventsViewModel.DiscoverableEvent
    let onJoinToggle: () -> Void
    let onTap: () -> Void

    @State private var isPressed = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                headerRow
                dateRow
                locationRow
                footerRow
            }
            .padding(BlipSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.name), \(event.location), \(event.attendeeCount) attendees")
        .accessibilityAddTraits(.isButton)
        ._onButtonGesture { pressing in
            isPressed = pressing
        } perform: {}
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                    .font(.custom(BlipFontName.semiBold, size: 17, relativeTo: .headline))
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(2)

                categoryBadge
            }

            Spacer()

            joinButton
        }
    }

    // MARK: - Category Badge

    private var categoryBadge: some View {
        Text(event.category.rawValue)
            .font(.custom(BlipFontName.medium, size: 11, relativeTo: .caption2))
            .foregroundStyle(.blipAccentPurple)
            .padding(.horizontal, BlipSpacing.sm)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.blipAccentPurple.opacity(0.15))
            )
    }

    // MARK: - Date Row

    private var dateRow: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.mutedText)
            Text(formattedDateRange)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
        }
    }

    // MARK: - Location Row

    private var locationRow: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.mutedText)
            Text(event.location)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.mutedText)
                Text("\(event.attendeeCount)")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .accessibilityLabel("\(event.attendeeCount) attendees")

            Spacer()
        }
    }

    // MARK: - Join Button

    private var joinButton: some View {
        Button {
            onJoinToggle()
        } label: {
            Text(event.isJoined ? "Joined" : "Join")
                .font(.custom(BlipFontName.semiBold, size: 13, relativeTo: .footnote))
                .foregroundStyle(event.isJoined ? .blipAccentPurple : .white)
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.xs + 2)
                .background(
                    event.isJoined
                        ? AnyShapeStyle(.blipAccentPurple.opacity(0.15))
                        : AnyShapeStyle(LinearGradient.blipAccent)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: BlipSizing.minTapTarget, minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(event.isJoined ? "Leave \(event.name)" : "Join \(event.name)")
    }

    // MARK: - Helpers

    private var formattedDateRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: event.startDate)
        let end = formatter.string(from: event.endDate)
        return "\(start) – \(end)"
    }
}

// MARK: - Preview

#Preview("Event Card") {
    ZStack {
        GradientBackground()
        EventCard(
            event: .init(
                id: "1", name: "Glastonbury 2026", location: "Pilton, Somerset",
                startDate: Date(), endDate: Date().addingTimeInterval(3 * 86400),
                description: "The world's largest greenfield festival.",
                imageURL: nil, attendeeCount: 12450, category: .festival, isJoined: false
            ),
            onJoinToggle: {},
            onTap: {}
        )
        .padding()
    }
    .blipTheme()
}
