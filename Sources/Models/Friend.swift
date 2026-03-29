import Foundation
import SwiftData

// MARK: - Enums

enum FriendStatus: String, Codable, CaseIterable {
    case pending
    case accepted
    case blocked
}

enum LocationPrecision: String, Codable, CaseIterable {
    case precise
    case fuzzy
    case off
}

// MARK: - Model

@Model
final class Friend {

    @Attribute(.unique)
    var id: UUID

    var user: User?
    var statusRaw: String
    var phoneVerified: Bool
    var locationSharingEnabled: Bool
    var locationPrecisionRaw: String
    var lastSeenLatitude: Double?
    var lastSeenLongitude: Double?
    var lastSeenAt: Date?
    var nickname: String?

    @Relationship
    var lastMessage: Message?

    var addedAt: Date

    // MARK: - Inverse Relationships

    @Relationship(inverse: \FriendLocation.friend)
    var locations: [FriendLocation] = []

    @Relationship(inverse: \SOSAlert.reportedFor)
    var sosAlerts: [SOSAlert] = []

    // MARK: - Computed Properties

    var status: FriendStatus {
        get { FriendStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var locationPrecision: LocationPrecision {
        get { LocationPrecision(rawValue: locationPrecisionRaw) ?? .off }
        set { locationPrecisionRaw = newValue.rawValue }
    }

    var lastSeenLocation: GeoPoint? {
        get {
            guard let lat = lastSeenLatitude, let lon = lastSeenLongitude else { return nil }
            return GeoPoint(latitude: lat, longitude: lon)
        }
        set {
            lastSeenLatitude = newValue?.latitude
            lastSeenLongitude = newValue?.longitude
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        user: User? = nil,
        status: FriendStatus = .pending,
        phoneVerified: Bool = false,
        locationSharingEnabled: Bool = false,
        locationPrecision: LocationPrecision = .off,
        lastSeenLatitude: Double? = nil,
        lastSeenLongitude: Double? = nil,
        lastSeenAt: Date? = nil,
        nickname: String? = nil,
        lastMessage: Message? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.user = user
        self.statusRaw = status.rawValue
        self.phoneVerified = phoneVerified
        self.locationSharingEnabled = locationSharingEnabled
        self.locationPrecisionRaw = locationPrecision.rawValue
        self.lastSeenLatitude = lastSeenLatitude
        self.lastSeenLongitude = lastSeenLongitude
        self.lastSeenAt = lastSeenAt
        self.nickname = nickname
        self.lastMessage = lastMessage
        self.addedAt = addedAt
    }
}
