import Foundation
import SwiftData

@Model
final class User {
    @Attribute(.unique)
    var id: UUID

    @Attribute(.unique)
    var username: String

    var displayName: String?
    var emailHash: String
    var noisePublicKey: Data
    var signingPublicKey: Data
    var avatarThumbnail: Data?
    var avatarFullRes: Data?
    var bio: String?
    var createdAt: Date

    // MARK: - Inverse Relationships

    @Relationship(inverse: \Friend.user)
    var friends: [Friend] = []

    @Relationship(inverse: \Message.sender)
    var sentMessages: [Message] = []

    @Relationship(inverse: \GroupMembership.user)
    var memberships: [GroupMembership] = []

    @Relationship(inverse: \MeetingPoint.creator)
    var meetingPoints: [MeetingPoint] = []

    @Relationship(inverse: \SOSAlert.reporter)
    var reportedAlerts: [SOSAlert] = []

    @Relationship(inverse: \MedicalResponder.user)
    var medicalResponders: [MedicalResponder] = []

    // MARK: - Computed Properties

    var resolvedDisplayName: String {
        displayName ?? username
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        username: String,
        displayName: String? = nil,
        emailHash: String,
        noisePublicKey: Data,
        signingPublicKey: Data,
        avatarThumbnail: Data? = nil,
        avatarFullRes: Data? = nil,
        bio: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.emailHash = emailHash
        self.noisePublicKey = noisePublicKey
        self.signingPublicKey = signingPublicKey
        self.avatarThumbnail = avatarThumbnail
        self.avatarFullRes = avatarFullRes
        self.bio = bio
        self.createdAt = createdAt
    }
}
