import Foundation

/// Double-tap debounce for async friend-list actions (accept, decline,
/// remove, block, unblock).
///
/// One `claim(for: friendID)` per row at a time. A second call while the
/// first is still in flight returns `false` so the caller can bail out
/// early — this is what stops Accept-then-Decline from racing two mutations
/// against the same `Friend` record and triggering SwiftData's
/// "trying to mutate a deleted object" assertion.
///
/// Lives in its own type (rather than as free helpers inside
/// `FriendsListView`) so the claim/release contract can be exercised in
/// unit tests without spinning up a SwiftUI view.
struct FriendActionGuard {
    private var inFlight: Set<UUID> = []

    /// Returns `true` if this caller was the first to claim `friendID`,
    /// `false` if an earlier async flow still holds the slot.
    mutating func claim(for friendID: UUID) -> Bool {
        if inFlight.contains(friendID) { return false }
        inFlight.insert(friendID)
        return true
    }

    mutating func release(for friendID: UUID) {
        inFlight.remove(friendID)
    }

    func isInFlight(_ friendID: UUID) -> Bool {
        inFlight.contains(friendID)
    }

    var count: Int { inFlight.count }
}
