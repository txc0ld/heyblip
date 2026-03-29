import SwiftUI

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
    @Environment(\.colorScheme) private var colorScheme

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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
            Text(Self.timeFormatter.string(from: startTime))
                .font(theme.typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(isLive ? .blipAccentPurple : theme.colors.text)
                .monospacedDigit()

            Text(Self.timeFormatter.string(from: endTime))
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
                    .lineLimit(1)

                if isLive {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(.blipAccentPurple)
                        )
                        .accessibilityLabel("Currently live")
                }
            }

            HStack(spacing: BlipSpacing.xs) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 10))
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
                    .font(.system(size: 16))
                    .foregroundStyle(isSaved ? .blipAccentPurple : theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? "Remove from saved" : "Save act")

            // Reminder toggle
            Button(action: { onToggleReminder?() }) {
                Image(systemName: hasReminder ? "bell.fill" : "bell")
                    .font(.system(size: 14))
                    .foregroundStyle(hasReminder ? .blipAccentPurple : theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasReminder ? "Remove reminder" : "Set reminder")

            // "I'm going" share
            Button(action: { onShareGoing?() }) {
                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(width: BlipSizing.minTapTarget, height: BlipSizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share I'm going to \(artistName)")
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
        desc += ", \(Self.timeFormatter.string(from: startTime)) to \(Self.timeFormatter.string(from: endTime))"
        if isLive { desc += ", currently live" }
        if isSaved { desc += ", saved" }
        if hasReminder { desc += ", reminder set" }
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
                    artistName: "Bicep",
                    stageName: "Pyramid Stage",
                    startTime: now.addingTimeInterval(-1800),
                    endTime: now.addingTimeInterval(3600),
                    isLive: true,
                    isSaved: true,
                    hasReminder: true
                )

                SetTimeCell(
                    artistName: "Floating Points",
                    stageName: "West Holts",
                    startTime: now.addingTimeInterval(3600),
                    endTime: now.addingTimeInterval(9000),
                    isLive: false,
                    isSaved: false,
                    hasReminder: false
                )

                SetTimeCell(
                    artistName: "Headliner TBA",
                    stageName: "Other Stage",
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
