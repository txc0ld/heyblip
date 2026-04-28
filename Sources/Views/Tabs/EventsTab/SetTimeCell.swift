import SwiftUI

private enum SetTimeCellL10n {
    static let live = String(localized: "events.schedule.live_badge", defaultValue: "LIVE")
    static let currentlyLive = String(localized: "events.schedule.live_accessibility", defaultValue: "Currently live")
    static let removeFromSaved = String(localized: "events.schedule.save.remove", defaultValue: "Remove from saved")
    static let saveAct = String(localized: "events.schedule.save.add", defaultValue: "Save act")
    static let removeReminder = String(localized: "events.schedule.reminder.remove", defaultValue: "Remove reminder")
    static let setReminder = String(localized: "events.schedule.reminder.add", defaultValue: "Set reminder")
    static let currentlyLiveState = String(localized: "events.schedule.accessibility.currently_live", defaultValue: "currently live")
    static let saved = String(localized: "events.schedule.accessibility.saved", defaultValue: "saved")
    static let reminderSet = String(localized: "events.schedule.accessibility.reminder_set", defaultValue: "reminder set")
    static let previewPyramidStage = "Pyramid Stage"
    static let previewBicep = "Bicep"
    static let previewWestHolts = "West Holts"
    static let previewFloatingPoints = "Floating Points"
    static let previewHeadliner = "Headliner TBA"
    static let previewOtherStage = "Other Stage"

    static func shareGoing(artistName: String) -> String {
        String(
            format: String(localized: "events.schedule.share_going.accessibility", defaultValue: "Share I'm going to %@"),
            locale: Locale.current,
            artistName
        )
    }
}

// MARK: - SetTimeCell

/// A single schedule entry showing artist name, time, stage, save star,
/// and "I'm going" share button.
///
/// Uses glass styling with accent highlights for live acts.
struct SetTimeCell: View {

    let artistName: String
    let stageName: String
    let startTime: Date
    let endTime: Date
    let isLive: Bool
    let isSaved: Bool
    let hasReminder: Bool

    var onSave: (() -> Void)?
    var onToggleReminder: (() -> Void)?
    var onShareGoing: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: BlipSpacing.md) {
            // Time column
            timeColumn

            // Divider
            Rectangle()
                .fill(isLive ? .blipAccentPurple : theme.colors.border)
                .frame(width: isLive ? 2 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            // Artist info
            artistColumn

            Spacer(minLength: 0)

            // Actions
            actionsColumn
        }
        .padding(.vertical, BlipSpacing.sm)
        .padding(.horizontal, BlipSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .fill(isLive ? .blipAccentPurple.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlipCornerRadius.lg, style: .continuous)
                .stroke(
                    isLive ? .blipAccentPurple.opacity(0.2) : .clear,
                    lineWidth: BlipSizing.hairline
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Time Column

    private var timeColumn: some View {
        VStack(spacing: BlipSpacing.xs) {
            Text(startTime.formatted(date: .omitted, time: .shortened))
                .font(theme.typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(isLive ? .blipAccentPurple : theme.colors.text)
                .monospacedDigit()

            Text(endTime.formatted(date: .omitted, time: .shortened))
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.mutedText)
                .monospacedDigit()
        }
        .frame(width: 48)
    }

    // MARK: - Artist Column

    private var artistColumn: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.xs) {
            HStack(spacing: BlipSpacing.sm) {
                Text(artistName)
                    .font(theme.typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)
                    // Allow 2 lines so artist names like "Floating Points"
                    // or "King Gizzard & The Lizard Wizard" stay readable
                    // at AX5 instead of truncating to "Float…" / "King G…".
                    .lineLimit(2)

                if isLive {
                    Text(SetTimeCellL10n.live)
                        .font(theme.typography.micro)
                        .foregroundStyle(.white)
                        .padding(.horizontal, BlipSpacing.sm)
                        .padding(.vertical, BlipSpacing.xxs)
                        .background(
                            Capsule()
                                .fill(.blipAccentPurple)
                        )
                        .accessibilityLabel(SetTimeCellL10n.currentlyLive)
                }
            }

            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: "music.note.house")
                    .font(theme.typography.caption2)
                    .foregroundStyle(theme.colors.mutedText)

                Text(stageName)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)

                Text(durationString)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.7))
            }
        }
    }

    // MARK: - Actions Column

    private var actionsColumn: some View {
        HStack(spacing: BlipSpacing.xs) {
            // Save/star button
            Button(action: { onSave?() }) {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .font(theme.typography.callout)
                    .foregroundStyle(isSaved ? .blipAccentPurple : theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? SetTimeCellL10n.removeFromSaved : SetTimeCellL10n.saveAct)

            // Reminder toggle
            Button(action: { onToggleReminder?() }) {
                Image(systemName: hasReminder ? "bell.fill" : "bell")
                    .font(theme.typography.secondary)
                    .foregroundStyle(hasReminder ? .blipAccentPurple : theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasReminder ? SetTimeCellL10n.removeReminder : SetTimeCellL10n.setReminder)

            // "I'm going" share
            Button(action: { onShareGoing?() }) {
                Image(systemName: "hand.thumbsup.fill")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SetTimeCellL10n.shareGoing(artistName: artistName))
        }
    }

    // MARK: - Helpers

    private var durationString: String {
        let duration = endTime.timeIntervalSince(startTime)
        let minutes = Int(duration / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            if remaining > 0 {
                return "\(hours)h \(remaining)m"
            }
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private var accessibilityDescription: String {
        var desc = "\(artistName) at \(stageName)"
        desc += ", \(startTime.formatted(date: .omitted, time: .shortened)) to \(endTime.formatted(date: .omitted, time: .shortened))"
        if isLive { desc += ", \(SetTimeCellL10n.currentlyLiveState)" }
        if isSaved { desc += ", \(SetTimeCellL10n.saved)" }
        if hasReminder { desc += ", \(SetTimeCellL10n.reminderSet)" }
        return desc
    }
}

// MARK: - Preview

#Preview("Set Time Cells") {
    let now = Date()
    ZStack {
        GradientBackground()
        ScrollView {
            VStack(spacing: 0) {
                SetTimeCell(
                    artistName: SetTimeCellL10n.previewBicep,
                    stageName: SetTimeCellL10n.previewPyramidStage,
                    startTime: now.addingTimeInterval(-1800),
                    endTime: now.addingTimeInterval(3600),
                    isLive: true,
                    isSaved: true,
                    hasReminder: true
                )

                SetTimeCell(
                    artistName: SetTimeCellL10n.previewFloatingPoints,
                    stageName: SetTimeCellL10n.previewWestHolts,
                    startTime: now.addingTimeInterval(3600),
                    endTime: now.addingTimeInterval(9000),
                    isLive: false,
                    isSaved: false,
                    hasReminder: false
                )

                SetTimeCell(
                    artistName: SetTimeCellL10n.previewHeadliner,
                    stageName: SetTimeCellL10n.previewOtherStage,
                    startTime: now.addingTimeInterval(14400),
                    endTime: now.addingTimeInterval(19800),
                    isLive: false,
                    isSaved: true,
                    hasReminder: false
                )
            }
            .padding()
        }
    }
    .preferredColorScheme(.dark)
    .blipTheme()
}
