import SwiftUI

private enum EventCardL10n {
    static let joined = String(localized: "events.discovery.card.joined", defaultValue: "Joined")
    static let join = String(localized: "events.discovery.card.join", defaultValue: "Join")

    static func attendees(_ count: Int) -> String {
        String(
            format: String(localized: "events.discovery.card.attendees", defaultValue: "%d attendees"),
            locale: Locale.current,
            count
        )
    }

    static func leave(_ name: String) -> String {
        String(
            format: String(localized: "events.discovery.card.leave.accessibility", defaultValue: "Leave %@"),
            locale: Locale.current,
            name
        )
    }

    static func join(_ name: String) -> String {
        String(
            format: String(localized: "events.discovery.card.join.accessibility", defaultValue: "Join %@"),
            locale: Locale.current,
            name
        )
    }
}

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
        .buttonStyle(EventCardPressStyle(isPressed: $isPressed))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.name), \(event.location), \(EventCardL10n.attendees(event.attendeeCount))")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                    .font(.custom(BlipFontName.semiBold, size: 17, relativeTo: .headline))
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(2)
                    // Lets the event-name VStack expand vertically at AX5
                    // instead of compressing into the row height. Long
                    // festival names (e.g. "Splendour in the Grass 2026")
                    // wrap to 2 lines cleanly rather than truncating.
                    .fixedSize(horizontal: false, vertical: true)

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
            .padding(.vertical, BlipSpacing.xxs)
            .background(
                Capsule().fill(.blipAccentPurple.opacity(0.15))
            )
    }

    // MARK: - Date Row

    private var dateRow: some View {
        HStack(spacing: BlipSpacing.xs) {
            Image(systemName: "calendar")
                .font(theme.typography.caption)
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
                .font(theme.typography.caption)
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
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                Text("\(event.attendeeCount)")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .accessibilityLabel(EventCardL10n.attendees(event.attendeeCount))

            Spacer()
        }
    }

    // MARK: - Join Button

    private var joinButton: some View {
        Button {
            onJoinToggle()
        } label: {
            Text(event.isJoined ? EventCardL10n.joined : EventCardL10n.join)
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
        .accessibilityLabel(event.isJoined ? EventCardL10n.leave(event.name) : EventCardL10n.join(event.name))
    }

    // MARK: - Helpers

    private var formattedDateRange: String {
        let start = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = event.endDate.formatted(date: .abbreviated, time: .omitted)
        return "\(start) – \(end)"
    }
}

// MARK: - EventCardPressStyle

/// Custom ButtonStyle that forwards press state to a binding,
/// replacing the private `_onButtonGesture` API.
private struct EventCardPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - Preview

#Preview("Event Card") {
    ZStack {
        GradientBackground()
        EventCard(
            event: .init(
                id: "1", name: "Glastonbury 2026", location: "Pilton, Somerset",
                latitude: 51.1537, longitude: -2.5875,
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
