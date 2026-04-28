import SwiftUI

private enum ScheduleViewL10n {
    static let collapse = String(localized: "events.schedule.accessibility.collapse", defaultValue: "Collapse")
    static let expand = String(localized: "events.schedule.accessibility.expand", defaultValue: "Expand")
    static let noSavedActs = String(localized: "events.schedule.empty.saved", defaultValue: "No saved acts yet")
    static let noActsPlaying = String(localized: "events.schedule.empty.live_now", defaultValue: "No acts playing right now")
    static let noActsScheduled = String(localized: "events.schedule.empty.all", defaultValue: "No acts scheduled")
    static let all = String(localized: "common.all", defaultValue: "All")
    static let saved = String(localized: "common.saved", defaultValue: "Saved")
    static let liveNow = String(localized: "events.schedule.filter.live_now", defaultValue: "Live Now")
    static let previewPyramidStage = "Pyramid Stage"
    static let previewBicep = "Bicep"
    static let previewHeadliner = "Headliner TBA"
    static let previewWestHolts = "West Holts"
    static let previewFloatingPoints = "Floating Points"
    static let previewBonobo = "Bonobo"

    static func actCount(_ count: Int) -> String {
        String(format: String(localized: "events.schedule.act_count", defaultValue: "%d acts"), locale: Locale.current, count)
    }

    static func stageAccessibility(_ name: String, _ count: Int) -> String {
        String(format: String(localized: "events.schedule.stage.accessibility_label", defaultValue: "%@, %d acts"), locale: Locale.current, name, count)
    }
}

// MARK: - ScheduleView

/// Scrollable schedule grouped by stage with save and reminder toggles.
///
/// Each stage section is collapsible. Acts display with SetTimeCell.
/// Filtering options: All / Saved / Live Now.
struct ScheduleView: View {

    let stages: [ScheduleStage]

    var onSaveAct: ((UUID) -> Void)?
    var onToggleReminder: ((UUID) -> Void)?
    var onShareGoing: ((UUID) -> Void)?

    @State private var filter: ScheduleFilter = .all
    @State private var expandedStages: Set<UUID> = []

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            scheduleList
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlipSpacing.sm) {
                ForEach(ScheduleFilter.allCases, id: \.self) { option in
                    filterChip(option)
                }

                Spacer()
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
        }
    }

    private func filterChip(_ option: ScheduleFilter) -> some View {
        Button(action: {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                filter = option
            }
        }) {
            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: option.iconName)
                    .font(theme.typography.caption)

                Text(option.displayName)
                    .font(theme.typography.caption)
                    .fontWeight(filter == option ? .semibold : .regular)
            }
            .foregroundStyle(filter == option ? .white : theme.colors.text)
            .padding(.horizontal, BlipSpacing.md)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                Capsule()
                    .fill(filter == option
                          ? AnyShapeStyle(LinearGradient.blipAccent)
                          : AnyShapeStyle(theme.colors.hover))
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(filter == option ? .isSelected : [])
    }

    // MARK: - Schedule List

    private var scheduleList: some View {
        ScrollView {
            LazyVStack(spacing: BlipSpacing.md, pinnedViews: .sectionHeaders) {
                ForEach(filteredStages) { stage in
                    Section {
                        stageSection(stage)
                    } header: {
                        stageSectionHeader(stage)
                    }
                }

                if filteredStages.isEmpty {
                    emptyFilterState
                }
            }
            .padding(.horizontal, BlipSpacing.md)
            .padding(.bottom, BlipSpacing.xxl)
        }
    }

    // MARK: - Stage Section

    @ViewBuilder
    private func stageSectionHeader(_ stage: ScheduleStage) -> some View {
        Button(action: {
            withAnimation(SpringConstants.accessiblePageEntrance) {
                if expandedStages.contains(stage.id) {
                    expandedStages.remove(stage.id)
                } else {
                    expandedStages.insert(stage.id)
                }
            }
        }) {
            HStack {
                Image(systemName: "music.note.house.fill")
                    .font(theme.typography.secondary)
                    .foregroundStyle(.blipAccentPurple)

                Text(stage.name)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text(ScheduleViewL10n.actCount(stage.acts.count))
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)

                Image(systemName: expandedStages.contains(stage.id) ? "chevron.up" : "chevron.down")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(.vertical, BlipSpacing.sm)
            .padding(.horizontal, BlipSpacing.md)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(ScheduleViewL10n.stageAccessibility(stage.name, stage.acts.count))
        .accessibilityHint(expandedStages.contains(stage.id) ? ScheduleViewL10n.collapse : ScheduleViewL10n.expand)
    }

    @ViewBuilder
    private func stageSection(_ stage: ScheduleStage) -> some View {
        if expandedStages.contains(stage.id) || expandedStages.isEmpty {
            let acts = filteredActs(for: stage)
            ForEach(Array(acts.enumerated()), id: \.element.id) { index, act in
                SetTimeCell(
                    artistName: act.artistName,
                    stageName: stage.name,
                    startTime: act.startTime,
                    endTime: act.endTime,
                    isLive: act.isLive,
                    isSaved: act.isSaved,
                    hasReminder: act.hasReminder,
                    onSave: { onSaveAct?(act.id) },
                    onToggleReminder: { onToggleReminder?(act.id) },
                    onShareGoing: { onShareGoing?(act.id) }
                )
                .staggeredReveal(index: index)
            }
        }
    }

    // MARK: - Empty State

    private var emptyFilterState: some View {
        GlassCard(thickness: .ultraThin) {
            EmptyStateView(
                icon: filter == .saved ? "star" : "music.note",
                title: filter == .saved
                    ? ScheduleViewL10n.noSavedActs
                    : filter == .liveNow
                    ? ScheduleViewL10n.noActsPlaying
                    : ScheduleViewL10n.noActsScheduled,
                subtitle: "",
                style: .inline
            )
            .padding(.vertical, BlipSpacing.xl)
        }
    }

    // MARK: - Filtering

    private var filteredStages: [ScheduleStage] {
        stages.filter { stage in
            !filteredActs(for: stage).isEmpty
        }
    }

    private func filteredActs(for stage: ScheduleStage) -> [ScheduleAct] {
        stage.acts.filter { act in
            switch filter {
            case .all:
                return true
            case .saved:
                return act.isSaved
            case .liveNow:
                return act.isLive
            }
        }
    }
}

// MARK: - Supporting Types

enum ScheduleFilter: CaseIterable {
    case all
    case saved
    case liveNow

    var displayName: String {
        switch self {
        case .all: return ScheduleViewL10n.all
        case .saved: return ScheduleViewL10n.saved
        case .liveNow: return ScheduleViewL10n.liveNow
        }
    }

    var iconName: String {
        switch self {
        case .all: return "list.bullet"
        case .saved: return "star.fill"
        case .liveNow: return "waveform"
        }
    }
}

struct ScheduleStage: Identifiable {
    let id: UUID
    let name: String
    let acts: [ScheduleAct]
}

struct ScheduleAct: Identifiable {
    let id: UUID
    let artistName: String
    let startTime: Date
    let endTime: Date
    let isLive: Bool
    let isSaved: Bool
    let hasReminder: Bool
}

// MARK: - Preview

#Preview("Schedule View") {
    let now = Date()
    let stages: [ScheduleStage] = [
        ScheduleStage(id: UUID(), name: ScheduleViewL10n.previewPyramidStage, acts: [
            ScheduleAct(id: UUID(), artistName: ScheduleViewL10n.previewBicep, startTime: now.addingTimeInterval(-1800), endTime: now.addingTimeInterval(3600), isLive: true, isSaved: true, hasReminder: true),
            ScheduleAct(id: UUID(), artistName: "Fred Again..", startTime: now.addingTimeInterval(3600), endTime: now.addingTimeInterval(9000), isLive: false, isSaved: false, hasReminder: false),
            ScheduleAct(id: UUID(), artistName: ScheduleViewL10n.previewHeadliner, startTime: now.addingTimeInterval(14400), endTime: now.addingTimeInterval(19800), isLive: false, isSaved: true, hasReminder: false),
        ]),
        ScheduleStage(id: UUID(), name: ScheduleViewL10n.previewWestHolts, acts: [
            ScheduleAct(id: UUID(), artistName: ScheduleViewL10n.previewFloatingPoints, startTime: now.addingTimeInterval(7200), endTime: now.addingTimeInterval(12600), isLive: false, isSaved: false, hasReminder: false),
            ScheduleAct(id: UUID(), artistName: ScheduleViewL10n.previewBonobo, startTime: now.addingTimeInterval(14400), endTime: now.addingTimeInterval(18000), isLive: false, isSaved: true, hasReminder: true),
        ]),
    ]

    ZStack {
        GradientBackground()
        ScheduleView(stages: stages)
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
