import Foundation
import SwiftData

// MARK: - Enums

enum GroupRole: String, Codable, CaseIterable {
    case member
    case admin
    case creator
}

// MARK: - Model

@Model
final class GroupMembership {
    @Attribute(.unique)
    var id: UUID

    var user: User?
    var channel: Channel?
    var roleRaw: String
    var nickname: String?
    var muted: Bool
    var mutedUntil: Date?
    var joinedAt: Date

    // MARK: - Computed Properties

    var role: GroupRole {
        get { GroupRole(rawValue: roleRaw) ?? .member }
        set { roleRaw = newValue.rawValue }
    }

    var isAdmin: Bool {
        role == .admin || role == .creator
    }

    var isCreator: Bool {
        role == .creator
    }

    var isMutedNow: Bool {
        guard muted else { return false }
        // Require an expiry date — nil mutedUntil means the mute has no duration,
        // which should be treated as "not muted" to prevent accidental permanent mutes.
        guard let until = mutedUntil else { return false }
        return Date() < until
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        user: User? = nil,
        channel: Channel? = nil,
        role: GroupRole = .member,
        nickname: String? = nil,
        muted: Bool = false,
        mutedUntil: Date? = nil,
        joinedAt: Date = Date()
    ) {
        self.id = id
        self.user = user
        self.channel = channel
        self.roleRaw = role.rawValue
        self.nickname = nickname
        self.muted = muted
        self.mutedUntil = mutedUntil
        self.joinedAt = joinedAt
    }
}
