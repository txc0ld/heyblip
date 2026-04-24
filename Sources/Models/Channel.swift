import Foundation
import SwiftData

// MARK: - Enums

enum ChannelType: String, Codable, CaseIterable {
    case dm
    case group
    case locationChannel
    case stageChannel
    case lostAndFound
    case emergency
}

enum MuteStatus: String, Codable, CaseIterable {
    case unmuted
    case mutedTimed
    case mutedForever
}

// MARK: - Model

@Model
final class Channel {

    @Attribute(.unique)
    var id: UUID

    var typeRaw: String
    var name: String?

    @Relationship(deleteRule: .cascade, inverse: \GroupMembership.channel)
    var memberships: [GroupMembership] = []

    var event: Event?
    var geohash: String?

    @Relationship
    var pinnedMessages: [Message] = []

    var muteStatusRaw: String
    var maxRetention: TimeInterval
    var isPinned: Bool
    var isAutoJoined: Bool
    var unreadCount: Int
    var createdAt: Date
    var lastActivityAt: Date

    /// Optional free-form description surfaced in ad-hoc location channels
    /// (user-created meet-up channels from the Events tab). Nil for system-
    /// created channels (DMs, stage channels, lost&found).
    var channelDescription: String?

    /// Optional wall-clock expiry. Currently set by ad-hoc location channels
    /// so user-created meet-ups auto-disappear at the chosen time. Left nil
    /// for persistent channels (DMs, event stages).
    var expiresAt: Date?

    // MARK: - Inverse Relationships

    @Relationship(deleteRule: .cascade, inverse: \Message.channel)
    var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \MeetingPoint.channel)
    var meetingPoints: [MeetingPoint] = []

    @Relationship(deleteRule: .cascade, inverse: \GroupSenderKey.channel)
    var senderKeys: [GroupSenderKey] = []

    // MARK: - Computed Properties

    var type: ChannelType {
        get { ChannelType(rawValue: typeRaw) ?? .dm }
        set { typeRaw = newValue.rawValue }
    }

    var muteStatus: MuteStatus {
        get { MuteStatus(rawValue: muteStatusRaw) ?? .unmuted }
        set { muteStatusRaw = newValue.rawValue }
    }

    var isMuted: Bool {
        muteStatus != .unmuted
    }

    var isGroup: Bool {
        type == .group
    }

    var isPublic: Bool {
        switch type {
        case .locationChannel, .stageChannel, .lostAndFound:
            return true
        case .dm, .group, .emergency:
            return false
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        type: ChannelType = .dm,
        name: String? = nil,
        event: Event? = nil,
        geohash: String? = nil,
        muteStatus: MuteStatus = .unmuted,
        maxRetention: TimeInterval = .infinity,
        isPinned: Bool = false,
        isAutoJoined: Bool = false,
        unreadCount: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        channelDescription: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.name = name
        self.event = event
        self.geohash = geohash
        self.muteStatusRaw = muteStatus.rawValue
        self.maxRetention = maxRetention
        self.isPinned = isPinned
        self.isAutoJoined = isAutoJoined
        self.unreadCount = unreadCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.channelDescription = channelDescription
        self.expiresAt = expiresAt
    }

    /// True when the channel has an expiry date that has already passed.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }
}

extension Channel {
    var dmConversationKey: String? {
        guard type == .dm else { return nil }
        guard let member = memberships.compactMap(\.user).first else { return nil }

        if !member.noisePublicKey.isEmpty {
            return "noise:\(member.noisePublicKey.base64EncodedString())"
        }

        let normalizedUsername = member.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedUsername.isEmpty else { return nil }
        return "username:\(normalizedUsername)"
    }
}
