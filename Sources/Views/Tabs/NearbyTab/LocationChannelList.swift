import SwiftUI

private enum LocationChannelListL10n {
    static let nearbyChannels = String(localized: "nearby.location_channels.title", defaultValue: "Nearby Channels")
    static let noChannels = String(localized: "nearby.location_channels.empty.title", defaultValue: "No channels nearby")
    static let noChannelsSubtitle = String(localized: "nearby.location_channels.empty.subtitle", defaultValue: "Channels appear when people are chatting in your area")
    static let autoJoined = String(localized: "nearby.location_channels.auto_joined", defaultValue: "Auto-joined")
    static let tapToJoin = String(localized: "nearby.location_channels.tap_to_join", defaultValue: "Tap to join")
    static let previewMainField = "Main Field"
    static let previewFoodTrucks = "Anyone know where the food trucks are?"
    static let previewCampingAreaB = "Camping Area B"
    static let previewShowers = "The showers are open until midnight"
    static let previewCarPark3 = "Car Park 3"

    static func memberCount(_ count: Int) -> String {
        String(format: String(localized: "nearby.location_channels.member_count", defaultValue: "%d %@"), locale: Locale.current, count, count == 1 ? "person" : "people")
    }

    static func channelAccessibility(_ name: String, _ count: Int) -> String {
        String(format: String(localized: "nearby.location_channels.accessibility_label", defaultValue: "%@, %d members"), locale: Locale.current, name, count)
    }
}

// MARK: - LocationChannelList

/// Auto-discovered location channels displayed as a scrollable list.
///
/// Each channel card shows the channel name, member count, and last message
/// preview. Tapping a channel triggers a join/navigate action.
struct LocationChannelList: View {

    let channels: [LocationChannelItem]
    var onChannelTap: ((LocationChannelItem) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.md) {
            sectionHeader

            if channels.isEmpty {
                emptyState
            } else {
                channelsList
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blipAccentPurple)

            Text(LocationChannelListL10n.nearbyChannels)
                .font(theme.typography.headline)
                .foregroundStyle(theme.colors.text)

            Spacer()

            if !channels.isEmpty {
                Text("\(channels.count)")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .padding(.horizontal, BlipSpacing.sm)
                    .padding(.vertical, BlipSpacing.xs)
                    .background(Capsule().fill(theme.colors.hover))
            }
        }
        .padding(.horizontal, BlipSpacing.md)
    }

    // MARK: - Channels List

    private var channelsList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BlipSpacing.md) {
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    LocationChannelCard(channel: channel) {
                        onChannelTap?(channel)
                    }
                    .staggeredReveal(index: index)
                }
            }
            .padding(.horizontal, BlipSpacing.md)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        GlassCard(thickness: .ultraThin, cornerRadius: BlipCornerRadius.xl) {
            VStack(spacing: BlipSpacing.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.colors.mutedText)

                Text(LocationChannelListL10n.noChannels)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.mutedText)

                Text(LocationChannelListL10n.noChannelsSubtitle)
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.md)
        }
        .padding(.horizontal, BlipSpacing.md)
    }
}

// MARK: - LocationChannelCard

/// Individual channel card within the horizontal list.
private struct LocationChannelCard: View {

    let channel: LocationChannelItem
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                // Channel icon and name
                HStack(spacing: BlipSpacing.sm) {
                    Image(systemName: channel.iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blipAccentPurple)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(.blipAccentPurple.opacity(0.15))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(channel.name)
                            .font(theme.typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.colors.text)
                            .lineLimit(1)

                        Text(channel.isAutoJoined ? LocationChannelListL10n.autoJoined : LocationChannelListL10n.tapToJoin)
                            .font(theme.typography.caption)
                            .foregroundStyle(.blipAccentPurple.opacity(0.8))
                    }
                }

                // Member count
                HStack(spacing: BlipSpacing.xs) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.colors.mutedText)

                    Text(LocationChannelListL10n.memberCount(channel.memberCount))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText)
                }

                // Last message preview
                if let lastMessage = channel.lastMessagePreview {
                    Text(lastMessage)
                        .font(theme.typography.secondary)
                        .foregroundStyle(theme.colors.mutedText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Timestamp
                if let lastActivity = channel.lastActivityAt {
                    Text(lastActivity, style: .relative)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.mutedText.opacity(0.6))
                }
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .glassCard(
            thickness: .regular,
            cornerRadius: BlipCornerRadius.xl,
            borderOpacity: 0.12
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LocationChannelListL10n.channelAccessibility(channel.name, channel.memberCount))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - LocationChannelItem

/// View-level data for a location channel.
struct LocationChannelItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let iconName: String
    let memberCount: Int
    let lastMessagePreview: String?
    let lastActivityAt: Date?
    let isAutoJoined: Bool
    let geohash: String?

    static func == (lhs: LocationChannelItem, rhs: LocationChannelItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview

#Preview("Location Channels - Populated") {
    let channels: [LocationChannelItem] = [
        LocationChannelItem(
            id: UUID(),
            name: LocationChannelListL10n.previewMainField,
            iconName: "mappin.and.ellipse",
            memberCount: 42,
            lastMessagePreview: LocationChannelListL10n.previewFoodTrucks,
            lastActivityAt: Date().addingTimeInterval(-120),
            isAutoJoined: true,
            geohash: "gcpu2e"
        ),
        LocationChannelItem(
            id: UUID(),
            name: LocationChannelListL10n.previewCampingAreaB,
            iconName: "tent.fill",
            memberCount: 18,
            lastMessagePreview: LocationChannelListL10n.previewShowers,
            lastActivityAt: Date().addingTimeInterval(-300),
            isAutoJoined: false,
            geohash: "gcpu2f"
        ),
        LocationChannelItem(
            id: UUID(),
            name: LocationChannelListL10n.previewCarPark3,
            iconName: "car.fill",
            memberCount: 7,
            lastMessagePreview: nil,
            lastActivityAt: nil,
            isAutoJoined: false,
            geohash: "gcpu2g"
        ),
    ]

    ZStack {
        GradientBackground()
        ScrollView {
            LocationChannelList(channels: channels)
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Location Channels - Empty") {
    ZStack {
        GradientBackground()
        LocationChannelList(channels: [])
    }
    .preferredColorScheme(.dark)
}
