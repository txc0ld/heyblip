import Foundation
import UserNotifications

// MARK: - Remote category identifiers

/// Stable identifiers for remote-push notification categories. The APNs
/// payload's `aps.category` field uses these strings verbatim. The existing
/// local-notification identifiers in `BlipNotificationCategory` remain the
/// source of truth for on-device events.
enum BlipRemotePushCategory: String, Sendable, CaseIterable {
    case friendRequest = "FRIEND_REQUEST"
    case friendAccept  = "FRIEND_ACCEPT"
    case dm            = "DM"
    case group         = "GROUP"
    case sos           = "SOS"
}

// MARK: - Remote action identifiers

/// Action identifiers used across remote-push categories. These are the
/// `actionIdentifier` strings the OS reports back to `didReceive` so the
/// background worker can dispatch without touching UI.
enum BlipRemoteNotificationAction: String, Sendable {
    case accept       = "ACCEPT"
    case decline      = "DECLINE"
    case reply        = "REPLY"
    case markRead     = "MARK_READ"
    case mute1h       = "MUTE_1H"
    case viewSOS      = "VIEW"
    case callResponder = "CALL_RESPONDER"
}

// MARK: - Category Registry

/// Central registry for all UNNotificationCategory definitions. Both the
/// local-notification categories (existing) and the remote-push categories
/// (new, HEY1321) are installed in one call so the set never drifts between
/// call sites.
enum NotificationCategoryRegistry {

    /// Register every category Blip knows about on the given center.
    /// Safe to call multiple times — `setNotificationCategories` replaces
    /// the existing set.
    static func registerAll(on center: UNUserNotificationCenter) {
        var categories = Set<UNNotificationCategory>()

        // Remote-push categories (HEY1321)
        categories.insert(makeFriendRequestCategory())
        categories.insert(makeFriendAcceptCategory())
        categories.insert(makeDMCategory())
        categories.insert(makeGroupCategory())
        categories.insert(makeSOSCategory())

        // Local categories (pre-existing — mirrored here so a single
        // registerAll call fully installs the set).
        for cat in makeLegacyLocalCategories() {
            categories.insert(cat)
        }

        center.setNotificationCategories(categories)
    }

    // MARK: - Remote push categories

    private static func makeFriendRequestCategory() -> UNNotificationCategory {
        let accept = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.accept.rawValue,
            title: "Accept",
            options: []
        )
        let decline = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.decline.rawValue,
            title: "Decline",
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: BlipRemotePushCategory.friendRequest.rawValue,
            actions: [accept, decline],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func makeFriendAcceptCategory() -> UNNotificationCategory {
        // No inline actions — taps open the friend's profile via deeplink.
        UNNotificationCategory(
            identifier: BlipRemotePushCategory.friendAccept.rawValue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func makeDMCategory() -> UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: BlipRemoteNotificationAction.reply.rawValue,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a message\u{2026}"
        )
        let markRead = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.markRead.rawValue,
            title: "Mark Read",
            options: []
        )
        return UNNotificationCategory(
            identifier: BlipRemotePushCategory.dm.rawValue,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func makeGroupCategory() -> UNNotificationCategory {
        let mute = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.mute1h.rawValue,
            title: "Mute 1h",
            options: [.destructive]
        )
        let markRead = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.markRead.rawValue,
            title: "Mark Read",
            options: []
        )
        return UNNotificationCategory(
            identifier: BlipRemotePushCategory.group.rawValue,
            actions: [mute, markRead],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func makeSOSCategory() -> UNNotificationCategory {
        let view = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.viewSOS.rawValue,
            title: "View",
            options: [.foreground]
        )
        let call = UNNotificationAction(
            identifier: BlipRemoteNotificationAction.callResponder.rawValue,
            title: "Call Responder",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: BlipRemotePushCategory.sos.rawValue,
            actions: [view, call],
            intentIdentifiers: [],
            // No dismissive action per spec — SOS always requires explicit
            // dismissal via one of the foreground actions.
            options: []
        )
    }

    // MARK: - Legacy local categories

    private static func makeLegacyLocalCategories() -> [UNNotificationCategory] {
        let replyAction = UNTextInputNotificationAction(
            identifier: BlipNotificationAction.reply.rawValue,
            title: "Reply",
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a message..."
        )
        let markReadAction = UNNotificationAction(
            identifier: BlipNotificationAction.markRead.rawValue,
            title: "Mark as Read"
        )
        let muteAction = UNNotificationAction(
            identifier: BlipNotificationAction.mute.rawValue,
            title: "Mute",
            options: .destructive
        )
        let messageCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.newMessage.rawValue,
            actions: [replyAction, markReadAction, muteAction],
            intentIdentifiers: []
        )

        let viewMapAction = UNNotificationAction(
            identifier: BlipNotificationAction.viewMap.rawValue,
            title: "View on Map",
            options: .foreground
        )
        let friendNearbyCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.friendNearby.rawValue,
            actions: [viewMapAction],
            intentIdentifiers: []
        )
        let setTimeCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.setTimeAlert.rawValue,
            actions: [viewMapAction],
            intentIdentifiers: []
        )

        let respondAction = UNNotificationAction(
            identifier: BlipNotificationAction.respondSOS.rawValue,
            title: "I Can Help",
            options: .foreground
        )
        let sosCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.sosAssist.rawValue,
            actions: [respondAction],
            intentIdentifiers: []
        )

        let acceptAction = UNNotificationAction(
            identifier: BlipNotificationAction.acceptFriend.rawValue,
            title: "Accept"
        )
        let declineAction = UNNotificationAction(
            identifier: BlipNotificationAction.declineFriend.rawValue,
            title: "Decline",
            options: .destructive
        )
        let friendReqCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.friendRequest.rawValue,
            actions: [acceptAction, declineAction],
            intentIdentifiers: []
        )

        let sosResolvedCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.sosResolved.rawValue,
            actions: [],
            intentIdentifiers: []
        )

        let orgCategory = UNNotificationCategory(
            identifier: BlipNotificationCategory.organizerAnnouncement.rawValue,
            actions: [],
            intentIdentifiers: []
        )

        return [
            messageCategory, friendNearbyCategory, setTimeCategory,
            sosCategory, friendReqCategory, sosResolvedCategory, orgCategory
        ]
    }
}
