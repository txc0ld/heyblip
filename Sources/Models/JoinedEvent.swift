import Foundation
import SwiftData

/// Persists which events the user has joined locally.
@Model
final class JoinedEvent {

    @Attribute(.unique)
    var id: UUID

    /// The remote event ID from the manifest.
    var eventId: String

    /// When the user joined this event.
    var joinedAt: Date

    init(id: UUID = UUID(), eventId: String, joinedAt: Date = Date()) {
        self.id = id
        self.eventId = eventId
        self.joinedAt = joinedAt
    }
}
