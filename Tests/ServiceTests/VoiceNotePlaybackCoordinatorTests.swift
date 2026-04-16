import XCTest
@testable import Blip

/// Behaviour tests for `VoiceNotePlaybackCoordinator`. The coordinator's job is
/// to ensure exactly one voice note is playing at a time across an arbitrary
/// number of `VoiceNotePlayer` bubbles in a long chat scroll.
@MainActor
final class VoiceNotePlaybackCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VoiceNotePlaybackCoordinator.shared.clear()
    }

    func testClaimReturnsUniqueTokens() {
        let first = VoiceNotePlaybackCoordinator.shared.claim()
        let second = VoiceNotePlaybackCoordinator.shared.claim()
        XCTAssertNotEqual(first, second, "each claim must mint a fresh token")
    }

    func testClaimUpdatesActiveToken() {
        let token = VoiceNotePlaybackCoordinator.shared.claim()
        XCTAssertEqual(VoiceNotePlaybackCoordinator.shared.activePlayerToken, token)
    }

    func testClaimSupersedesPreviousClaim() {
        // Simulate two voice notes being tapped in succession. The second claim
        // must invalidate the first — observers comparing their stored token to
        // `activePlayerToken` should detect the mismatch and stop their player.
        let first = VoiceNotePlaybackCoordinator.shared.claim()
        let second = VoiceNotePlaybackCoordinator.shared.claim()
        XCTAssertNotEqual(VoiceNotePlaybackCoordinator.shared.activePlayerToken, first)
        XCTAssertEqual(VoiceNotePlaybackCoordinator.shared.activePlayerToken, second)
    }

    func testReleaseOnlyClearsWhenTokenStillActive() {
        let first = VoiceNotePlaybackCoordinator.shared.claim()
        let second = VoiceNotePlaybackCoordinator.shared.claim()

        // The first player calling release with its (now-stale) token must NOT
        // clear the active claim — that would silently abort the second player.
        VoiceNotePlaybackCoordinator.shared.release(first)
        XCTAssertEqual(VoiceNotePlaybackCoordinator.shared.activePlayerToken, second)

        // The active player releasing its own token clears the slot.
        VoiceNotePlaybackCoordinator.shared.release(second)
        XCTAssertNil(VoiceNotePlaybackCoordinator.shared.activePlayerToken)
    }

    func testClearForcesAllPlayersToStop() {
        let token = VoiceNotePlaybackCoordinator.shared.claim()
        XCTAssertNotNil(VoiceNotePlaybackCoordinator.shared.activePlayerToken)

        VoiceNotePlaybackCoordinator.shared.clear()
        XCTAssertNil(VoiceNotePlaybackCoordinator.shared.activePlayerToken)

        // Releasing the (already-cleared) token after `clear()` is a no-op,
        // not a crash — important for unit tests of player teardown.
        VoiceNotePlaybackCoordinator.shared.release(token)
        XCTAssertNil(VoiceNotePlaybackCoordinator.shared.activePlayerToken)
    }
}
