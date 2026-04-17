import XCTest
import UserNotifications
@testable import Blip

/// Tests for `NotificationService.presentationOptions(forCategory:channelID:)`
/// and the `setActiveChannel` / `currentActiveChannelID` round-trip that
/// backs it.
///
/// The decision lives in `presentationOptions` so tests don't need to
/// construct a `UNNotification` (which has no public initializer). The
/// critical invariants, all covered below:
///
/// - SOS is always unconditional banner + sound + badge.
/// - A `newMessage` notification for the currently-active channel is
///   suppressed to badge-only.
/// - A `newMessage` notification for *another* channel still fires the
///   banner.
/// - Clearing the active channel restores default banner behaviour.
/// - Concurrent `setActiveChannel` from a background queue is race-free.
@MainActor
final class NotificationServiceTests: XCTestCase {

    private var service: NotificationService!

    override func setUp() async throws {
        service = NotificationService()
    }

    override func tearDown() async throws {
        service = nil
    }

    // MARK: - Active-channel round-trip

    func test_setActiveChannel_roundTrip() {
        XCTAssertNil(service.currentActiveChannelID())

        let id = UUID()
        service.setActiveChannel(id)
        XCTAssertEqual(service.currentActiveChannelID(), id)

        service.setActiveChannel(nil)
        XCTAssertNil(service.currentActiveChannelID())
    }

    // MARK: - SOS is unconditional

    func test_sosNotification_alwaysReturnsFullBannerSoundBadge_evenWhenChannelActive() {
        let anyActive = UUID()
        service.setActiveChannel(anyActive)

        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.sosAssist.rawValue,
            channelID: anyActive // same UUID — must still be interruptive
        )
        XCTAssertEqual(options, [.banner, .sound, .badge])
    }

    func test_sosNotification_whenNoActiveChannel_isFullBannerSoundBadge() {
        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.sosAssist.rawValue,
            channelID: nil
        )
        XCTAssertEqual(options, [.banner, .sound, .badge])
    }

    // MARK: - newMessage suppression

    func test_newMessageForActiveChannel_returnsBadgeOnly() {
        let channel = UUID()
        service.setActiveChannel(channel)

        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.newMessage.rawValue,
            channelID: channel
        )
        XCTAssertEqual(options, [.badge], "banner must be suppressed while user is inside this thread")
    }

    func test_newMessageForDifferentChannel_firesBanner() {
        let activeChannel = UUID()
        let incomingChannel = UUID()
        service.setActiveChannel(activeChannel)

        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.newMessage.rawValue,
            channelID: incomingChannel
        )
        XCTAssertEqual(options, [.banner, .badge])
    }

    func test_newMessageWithNoActiveChannel_firesBanner() {
        service.setActiveChannel(nil)

        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.newMessage.rawValue,
            channelID: UUID()
        )
        XCTAssertEqual(options, [.banner, .badge])
    }

    func test_newMessageWithMissingChannelID_firesBanner() {
        // Simulate a notification whose userInfo did not contain a parsable
        // channelID — the `willPresent` path would pass `nil` through to
        // `presentationOptions`.
        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.newMessage.rawValue,
            channelID: nil
        )
        XCTAssertEqual(options, [.banner, .badge])
    }

    // MARK: - Clearing active channel restores default

    func test_clearingActiveChannel_restoresBannerBehaviour() {
        let channel = UUID()
        service.setActiveChannel(channel)

        XCTAssertEqual(
            service.presentationOptions(
                forCategory: BlipNotificationCategory.newMessage.rawValue,
                channelID: channel
            ),
            [.badge]
        )

        service.setActiveChannel(nil)

        XCTAssertEqual(
            service.presentationOptions(
                forCategory: BlipNotificationCategory.newMessage.rawValue,
                channelID: channel
            ),
            [.banner, .badge]
        )
    }

    // MARK: - Other categories fall through to default

    func test_otherCategory_returnsDefaultBannerBadge() {
        let options = service.presentationOptions(
            forCategory: BlipNotificationCategory.friendNearby.rawValue,
            channelID: nil
        )
        XCTAssertEqual(options, [.banner, .badge])
    }

    // MARK: - Concurrency

    func test_concurrentSetActiveChannel_doesNotRace() async {
        // Hammer setActiveChannel from many tasks while reads happen in
        // parallel. The NSLock must prevent observable corruption; at the
        // end we pin a known value and verify the last write wins.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 100 {
                group.addTask { [service] in
                    service?.setActiveChannel(UUID())
                }
                group.addTask { [service] in
                    _ = service?.currentActiveChannelID()
                }
            }
        }

        let sentinel = UUID()
        service.setActiveChannel(sentinel)
        XCTAssertEqual(service.currentActiveChannelID(), sentinel)
    }
}
