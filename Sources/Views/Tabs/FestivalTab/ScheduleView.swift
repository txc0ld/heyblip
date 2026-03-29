import SwiftUI

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
    @State private var searchText: String = ""

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
                    .font(.system(size: 12, weight: .medium))

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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blipAccentPurple)

                Text(stage.name)
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Spacer()

                Text("\(stage.acts.count) acts")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)

                Image(systemName: expandedStages.contains(stage.id) ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.mutedText)
            }
            .padding(.vertical, BlipSpacing.sm)
            .padding(.horizontal, BlipSpacing.md)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel("\(stage.name), \(stage.acts.count) acts")
        .accessibilityHint(expandedStages.contains(stage.id) ? "Collapse" : "Expand")
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
            VStack(spacing: BlipSpacing.md) {
                Image(systemName: filter == .saved ? "star" : "music.note")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.colors.mutedText)

                Text(filter == .saved
                     ? "No saved acts yet"
                     : filter == .liveNow
                     ? "No acts playing right now"
                     : "No acts scheduled")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
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
        case .all: return "All"
        case .saved: return "Saved"
        case .liveNow: return "Live Now"
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
        ScheduleStage(id: UUID(), name: "Pyramid Stage", acts: [
            ScheduleAct(id: UUID(), artistName: "Bicep", startTime: now.addingTimeInterval(-1800), endTime: now.addingTimeInterval(3600), isLive: true, isSaved: true, hasReminder: true),
            ScheduleAct(id: UUID(), artistName: "Fred Again..", startTime: now.addingTimeInterval(3600), endTime: now.addingTimeInterval(9000), isLive: false, isSaved: false, hasReminder: false),
            ScheduleAct(id: UUID(), artistName: "Headliner TBA", startTime: now.addingTimeInterval(14400), endTime: now.addingTimeInterval(19800), isLive: false, isSaved: true, hasReminder: false),
        ]),
        ScheduleStage(id: UUID(), name: "West Holts", acts: [
            ScheduleAct(id: UUID(), artistName: "Floating Points", startTime: now.addingTimeInterval(7200), endTime: now.addingTimeInterval(12600), isLive: false, isSaved: false, hasReminder: false),
            ScheduleAct(id: UUID(), artistName: "Bonobo", startTime: now.addingTimeInterval(14400), endTime: now.addingTimeInterval(18000), isLive: false, isSaved: true, hasReminder: true),
        ]),
    ]

    ZStack {
        GradientBackground()
        ScheduleView(stages: stages)
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
