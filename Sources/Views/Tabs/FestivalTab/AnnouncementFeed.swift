import SwiftUI

// MARK: - AnnouncementFeed

/// Priority announcements from festival organizers.
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blipAccentPurple)

            Text("Announcements")
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
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.colors.mutedText)

                Text("No announcements")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)

                Text("Festival updates will appear here")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
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
                                .font(.system(size: 10))
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
        .accessibilityLabel("\(announcement.severity.accessibilityLabel) announcement: \(announcement.title). \(announcement.message)")
    }

    private var severityBadge: some View {
        VStack {
            Image(systemName: announcement.severity.iconName)
                .font(.system(size: 16, weight: .bold))
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
        case .info: return .blue
        case .warning: return BlipColors.darkColors.statusAmber
        case .urgent: return .orange
        case .emergency: return BlipColors.darkColors.statusRed
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
        case .info: return "Info"
        case .warning: return "Warning"
        case .urgent: return "Urgent"
        case .emergency: return "Emergency"
        }
    }
}

// MARK: - Preview

#Preview("Announcement Feed") {
    let announcements: [AnnouncementItem] = [
        AnnouncementItem(id: UUID(), title: "WEATHER WARNING", message: "Heavy rain expected from 8pm. Seek shelter in covered areas. Waterproofs recommended.", severity: .emergency, timestamp: Date().addingTimeInterval(-300), source: "Festival Safety", isPinned: true),
        AnnouncementItem(id: UUID(), title: "Schedule Change", message: "Fred Again.. moved from 9pm to 10pm on Pyramid Stage due to technical setup.", severity: .warning, timestamp: Date().addingTimeInterval(-1800), source: "Programme Team", isPinned: false),
        AnnouncementItem(id: UUID(), title: "Food Village Extended", message: "Food vendors in the Green Field area will remain open until 2am tonight.", severity: .info, timestamp: Date().addingTimeInterval(-3600), source: "Festival Info", isPinned: false),
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
