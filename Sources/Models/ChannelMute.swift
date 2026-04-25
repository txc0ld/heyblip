import Foundation
import SwiftData

// MARK: - Model

/// Per-channel mute (DM or group). Additive SwiftData model introduced for
/// HEY-1321 push notification preferences.
///
/// Queried by `channelID` (not by relationship) to stay decoupled from the
/// `Channel` model — keeps this model schema-simple so a lightweight
/// migration can add it without touching the `Channel` graph.
///
/// `until == nil` means the mute is indefinite. `isActive` returns `false`
/// once `until` is in the past, so expired mutes naturally drop out of the
/// settings UI without a scheduled cleanup job. (A background sweep can
/// still delete stale rows later if we care about storage.)
@Model
final class ChannelMute {

    @Attribute(.unique)
    var id: UUID

    var channelID: UUID
    var until: Date?
    var createdAt: Date

    init(channelID: UUID, until: Date? = nil) {
        self.id = UUID()
        self.channelID = channelID
        self.until = until
        self.createdAt = Date()
    }

    /// `true` while the mute should still suppress notifications.
    var isActive: Bool {
        if let until {
            return until > Date()
        }
        return true
    }
}
