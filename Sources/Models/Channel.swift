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

    var festival: Festival?
    var geohash: String?

    @Relationship
    var pinnedMessages: [Message] = []

    var muteStatusRaw: String
    var maxRetention: TimeInterval
    var isAutoJoined: Bool
    var createdAt: Date
    var lastActivityAt: Date

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
        festival: Festival? = nil,
        geohash: String? = nil,
        muteStatus: MuteStatus = .unmuted,
        maxRetention: TimeInterval = .infinity,
        isAutoJoined: Bool = false,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.name = name
        self.festival = festival
        self.geohash = geohash
        self.muteStatusRaw = muteStatus.rawValue
        self.maxRetention = maxRetention
        self.isAutoJoined = isAutoJoined
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
