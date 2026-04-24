import Foundation
import SwiftData

// MARK: - Model

/// Per-friend mute, keyed by the friend's PeerID hex string. Additive
/// SwiftData model introduced for HEY-1321 push notification preferences.
///
/// We key by hex (not by `Friend` relationship) so the NSE cache — which
/// has no SwiftData access — can consume the same identifier from a shared
/// App-Group store.
///
/// `until == nil` means the mute is indefinite. `isActive` returns `false`
/// once `until` is in the past.
@Model
final class FriendMute {

    @Attribute(.unique)
    var id: UUID

    var peerIdHex: String
    var until: Date?
    var createdAt: Date

    init(peerIdHex: String, until: Date? = nil) {
        self.id = UUID()
        self.peerIdHex = peerIdHex
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
