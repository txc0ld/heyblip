import SwiftUI

private enum AnnouncementFeedL10n {
    static let title = String(localized: "events.announcements.feed.title", defaultValue: "Announcements")
    static let emptyTitle = String(localized: "events.announcements.feed.empty.title", defaultValue: "No announcements")
    static let emptySubtitle = String(localized: "events.announcements.feed.empty.subtitle", defaultValue: "Event updates will appear here")
    static let info = String(localized: "events.announcements.severity.info", defaultValue: "Info")
    static let warning = String(localized: "events.announcements.severity.warning", defaultValue: "Warning")
    static let urgent = String(localized: "events.announcements.severity.urgent", defaultValue: "Urgent")
    static let emergency = String(localized: "events.announcements.severity.emergency", defaultValue: "Emergency")
    static let previewWeatherWarning = "WEATHER WARNING"
    static let previewWeatherMessage = "Heavy rain expected from 8pm. Seek shelter in covered areas. Waterproofs recommended."
    static let previewEventSafety = "Event Safety"
    static let previewScheduleChange = "Schedule Change"
    static let previewScheduleMessage = "Fred Again.. moved from 9pm to 10pm on Pyramid Stage due to technical setup."
    static let previewProgrammeTeam = "Programme Team"
    static let previewFoodVillage = "Food Village Extended"
    static let previewFoodVillageMessage = "Food vendors in the Green Field area will remain open until 2am tonight."
    static let previewEventInfo = "Event Info"

    static func accessibilityLabel(severity: String, title: String, message: String) -> String {
        String(
            format: String(localized: "events.announcements.card.accessibility", defaultValue: "%1$@ announcement: %2$@. %3$@"),
            locale: Locale.current,
            severity,
            title,
            message
        )
    }
}

// MARK: - AnnouncementFeed

/// Priority announcements from event organizers.
///
/// Displays glass cards with severity-based color coding.
/// Emergency announcements are pinned at the top with red accent.
struct AnnouncementFeed: View {

    let announcements: [AnnouncementItem]
    var onAnnouncementTap: ((AnnouncementItem) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            sectionHeader

            if announcements.isEmpty {
                emptyState
            } else {
                announcementList
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack {
            Image(systemName: "megaphone.fill")
                .font(theme.typography.secondary)
                .foregroundStyle(.blipAccentPurple)

            Text(AnnouncementFeedL10n.title)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Spacer()

            if !announcements.isEmpty {
                Text("\(announcements.count)")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xs)
                    .background(Capsule().fill(theme.colors.hover))
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    // MARK: - List

    private var announcementList: some View {
        LazyVStack(spacing: BlipSpacing.sm) {
            // Emergency announcements pinned at top
            let emergencies = announcements.filter { $0.severity == .emergency }
            let regular = announcements.filter { $0.severity != .emergency }

            ForEach(Array(emergencies.enumerated()), id: \.element.id) { index, announcement in
                AnnouncementCard(announcement: announcement) {
                    onAnnouncementTap?(announcement)
                }
                .staggeredReveal(index: index)
            }

            ForEach(Array(regular.enumerated()), id: \.element.id) { index, announcement in
                AnnouncementCard(announcement: announcement) {
                    onAnnouncementTap?(announcement)
                }
                .staggeredReveal(index: emergencies.count + index)
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        GlassCard(thickness: .ultraThin) {
            EmptyStateView(
                icon: "checkmark.circle",
                title: AnnouncementFeedL10n.emptyTitle,
                subtitle: AnnouncementFeedL10n.emptySubtitle,
                style: .inline
            )
        }
        .padding(.horizontal, BlipSpacing.md)
    }
}

// MARK: - AnnouncementCard

/// Individual announcement card with severity-based styling.
private struct AnnouncementCard: View {

    let announcement: AnnouncementItem
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: BlipSpacing.md) {
                // Severity indicator
                severityBadge

                // Content
                VStack(alignment: .leading, spacing: BlipSpacing.xs) {
                    HStack {
                        Text(announcement.title)
                            .font(theme.typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.colors.text)
                            .lineLimit(2)

                        Spacer()

                        if announcement.isPinned {
                            Image(systemName: "pin.fill")
                                .font(theme.typography.caption2)
                                .foregroundStyle(severityColor)
                        }
                    }

                    Text(announcement.message)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: BlipSpacing.sm) {
                        Text(announcement.timestamp, style: .relative)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.mutedText.opacity(0.7))

                        if let source = announcement.source {
                            Text(source)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.mutedText.opacity(0.7))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .padding(BlipSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.xl, style: .continuous)
                .stroke(
                    announcement.severity == .emergency
                        ? severityColor.opacity(0.4)
                        : (colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08)),
                    lineWidth: announcement.severity == .emergency ? 1 : BlipSizing.hairline
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AnnouncementFeedL10n.accessibilityLabel(
                severity: announcement.severity.accessibilityLabel,
                title: announcement.title,
                message: announcement.message
            )
        )
    }

    private var severityBadge: some View {
        VStack {
            Image(systemName: announcement.severity.iconName)
                .font(theme.typography.callout)
                .foregroundStyle(severityColor)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(severityColor.opacity(0.15))
                )
        }
    }

    private var severityColor: Color {
        switch announcement.severity {
        case .info: return .blipAccentPurple
        case .warning: return theme.colors.statusAmber
        case .urgent: return theme.colors.statusAmber
        case .emergency: return theme.colors.statusRed
        }
    }
}

// MARK: - AnnouncementItem

struct AnnouncementItem: Identifiable {
    let id: UUID
    let title: String
    let message: String
    let severity: AnnouncementSeverity
    let timestamp: Date
    let source: String?
    let isPinned: Bool
}

enum AnnouncementSeverity {
    case info
    case warning
    case urgent
    case emergency

    var iconName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent: return "exclamationmark.circle.fill"
        case .emergency: return "exclamationmark.octagon.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .info: return AnnouncementFeedL10n.info
        case .warning: return AnnouncementFeedL10n.warning
        case .urgent: return AnnouncementFeedL10n.urgent
        case .emergency: return AnnouncementFeedL10n.emergency
        }
    }
}

// MARK: - Preview

#Preview("Announcement Feed") {
    let announcements: [AnnouncementItem] = [
        AnnouncementItem(id: UUID(), title: AnnouncementFeedL10n.previewWeatherWarning, message: AnnouncementFeedL10n.previewWeatherMessage, severity: .emergency, timestamp: Date().addingTimeInterval(-300), source: AnnouncementFeedL10n.previewEventSafety, isPinned: true),
        AnnouncementItem(id: UUID(), title: AnnouncementFeedL10n.previewScheduleChange, message: AnnouncementFeedL10n.previewScheduleMessage, severity: .warning, timestamp: Date().addingTimeInterval(-1800), source: AnnouncementFeedL10n.previewProgrammeTeam, isPinned: false),
        AnnouncementItem(id: UUID(), title: AnnouncementFeedL10n.previewFoodVillage, message: AnnouncementFeedL10n.previewFoodVillageMessage, severity: .info, timestamp: Date().addingTimeInterval(-3600), source: AnnouncementFeedL10n.previewEventInfo, isPinned: false),
    ]

    ZStack {
        GradientBackground()
        ScrollView {
            AnnouncementFeed(announcements: announcements)
                .padding(.top, BlipSpacing.md)
        }
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
