import XCTest
@testable import Blip

/// Tests for `FriendActionGuard`, the debounce type that backs
/// `FriendsListView`'s `actionsGuard`.
///
/// The underlying concern is the Accept-then-Decline double-tap race
/// documented in CLAUDE.md. The guard is pure, synchronous, and has no
/// dependency on SwiftUI — which is the point of extracting it. The five
/// call sites in `FriendsListView` (`acceptFriendRequest`, `declineFriend`,
/// `removeFriend`, `blockFriend`, `unblockFriend`) all use the same
/// claim/release contract, so the invariants here apply to every action
/// by construction.
final class FriendActionRaceGuardTests: XCTestCase {

    func test_claim_succeedsOnFirstCall() {
        var guardState = FriendActionGuard()
        let id = UUID()
        XCTAssertTrue(guardState.claim(for: id))
        XCTAssertTrue(guardState.isInFlight(id))
        XCTAssertEqual(guardState.count, 1)
    }

    func test_claim_returnsFalseWhileFirstStillHeld() {
        var guardState = FriendActionGuard()
        let id = UUID()

        XCTAssertTrue(guardState.claim(for: id))
        XCTAssertFalse(
            guardState.claim(for: id),
            "the second concurrent claim on the same friend must bail out"
        )
        XCTAssertFalse(
            guardState.claim(for: id),
            "subsequent claims also bail out until the first releases"
        )
        XCTAssertEqual(guardState.count, 1)
    }

    func test_release_reopensTheSlot() {
        var guardState = FriendActionGuard()
        let id = UUID()

        XCTAssertTrue(guardState.claim(for: id))
        guardState.release(for: id)
        XCTAssertFalse(guardState.isInFlight(id))
        XCTAssertTrue(
            guardState.claim(for: id),
            "after release a fresh claim for the same friend must succeed"
        )
    }

    func test_release_withUnknownID_isNoOp() {
        var guardState = FriendActionGuard()
        let id = UUID()
        guardState.release(for: id) // never claimed
        XCTAssertFalse(guardState.isInFlight(id))
        XCTAssertEqual(guardState.count, 0)
    }

    func test_separateFriendIDs_claimIndependently() {
        var guardState = FriendActionGuard()
        let alice = UUID()
        let bob = UUID()

        XCTAssertTrue(guardState.claim(for: alice))
        XCTAssertTrue(
            guardState.claim(for: bob),
            "claiming a different friend must succeed even while another is in flight"
        )
        XCTAssertEqual(guardState.count, 2)

        guardState.release(for: alice)
        XCTAssertFalse(guardState.isInFlight(alice))
        XCTAssertTrue(guardState.isInFlight(bob), "releasing alice must not free bob")
    }

    // The exact regression CLAUDE.md flags: Accept-then-Decline.
    func test_acceptThenDecline_onSameFriend_dropsTheSecondAction() {
        var guardState = FriendActionGuard()
        let friend = UUID()

        // Simulate the tap that fires acceptFriendRequest.
        let acceptClaimed = guardState.claim(for: friend)
        XCTAssertTrue(acceptClaimed)

        // Before the async accept flow completes, a decline tap fires.
        let declineClaimed = guardState.claim(for: friend)
        XCTAssertFalse(
            declineClaimed,
            "decline tap must no-op while accept is still in flight"
        )

        // Accept's Task finishes and releases.
        guardState.release(for: friend)

        // A fresh decline tap is now free to proceed.
        XCTAssertTrue(guardState.claim(for: friend))
    }

    func test_doubleTapAccept_onlyOneFires() {
        var guardState = FriendActionGuard()
        let friend = UUID()
        var firesHandled = 0

        // First tap: proceeds.
        if guardState.claim(for: friend) {
            firesHandled += 1
        }
        // Rapid second tap before the first releases.
        if guardState.claim(for: friend) {
            firesHandled += 1
        }
        XCTAssertEqual(firesHandled, 1, "double-tap Accept must collapse to one action")
    }
}
