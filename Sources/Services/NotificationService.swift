import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Notification Category

/// Categories of local notifications that Blip can send. These identifiers
/// stay stable — they appear in delivered notifications from prior app
/// versions and must continue to route correctly.
enum BlipNotificationCategory: String, Sendable {
    /// New message received in a DM or group.
    case newMessage = "com.blip.notification.newMessage"
    /// A friend is nearby (proximity alert).
    case friendNearby = "com.blip.notification.friendNearby"
    /// A saved set time is about to start.
    case setTimeAlert = "com.blip.notification.setTimeAlert"
    /// SOS alert: a nearby person needs assistance.
    case sosAssist = "com.blip.notification.sosAssist"
    /// Friend request received.
    case friendRequest = "com.blip.notification.friendRequest"
    /// SOS alert resolved.
    case sosResolved = "com.blip.notification.sosResolved"
    /// Organizer announcement.
    case organizerAnnouncement = "com.blip.notification.orgAnnouncement"
}

// MARK: - Notification Action

/// Actions available on local notifications.
enum BlipNotificationAction: String, Sendable {
    case reply = "com.blip.action.reply"
    case markRead = "com.blip.action.markRead"
    case mute = "com.blip.action.mute"
    case acceptFriend = "com.blip.action.acceptFriend"
    case declineFriend = "com.blip.action.declineFriend"
    case viewMap = "com.blip.action.viewMap"
    case respondSOS = "com.blip.action.respondSOS"
    case openConversation = "com.blip.action.openConversation"
}

// MARK: - Unsafe payload bridge

/// Carries an APNs `userInfo` dictionary across a MainActor hop without the
/// compiler complaining about `[AnyHashable: Any]` not being Sendable. APNs
/// payloads are always JSON value trees, so the underlying bytes are safe
/// to read from the receiving actor.
struct UnsafeNotificationPayload: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

// MARK: - Notification Service Delegate

protocol NotificationServiceDelegate: AnyObject, Sendable {
    func notificationService(_ service: NotificationService, didReceiveAction action: BlipNotificationAction, with userInfo: [String: Any])
    func notificationService(_ service: NotificationService, didReceiveReplyText text: String, with userInfo: [String: Any])
}

// MARK: - Notification Service

/// Manages local notifications for Blip events.
///
/// Handles:
/// - New message notifications (DM, group, channel)
/// - Friend nearby proximity alerts
/// - Set time reminders (artist about to play)
/// - SOS nearby assist requests
/// - Friend request notifications
/// - Organizer announcements
/// - Remote push taps and category actions (HEY1321)
///
/// Uses UNUserNotificationCenter with categories and actions for rich notification interactions.
@MainActor
final class NotificationService: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private let center: UNUserNotificationCenter
    weak var delegate: (any NotificationServiceDelegate)?

    /// Whether notification permissions have been granted.
    private(set) var isAuthorized = false

    /// Whether notifications are enabled in user preferences.
    var notificationsEnabled = true

    /// The currently visible chat channel, set by `ChatViewModel.openConversation` and
    /// cleared on `closeConversation`. While the user is staring at a thread, foreground
    /// banners for that thread are noise; we still play sound + bump the badge so the
    /// system continues to feel "alive" but we suppress the visual interruption.
    private var activeChannelID: UUID?

    func setActiveChannel(_ channelID: UUID?) {
        lock.lock()
        let previous = activeChannelID
        activeChannelID = channelID
        lock.unlock()

        // Server-authoritative badge: when the user opens a conversation,
        // clear that thread's unread on the server. Fire-and-forget.
        if let channelID, channelID != previous {
            Task { @MainActor in
                BadgeSyncService.shared.clearThread(channelID)
            }
        }
    }

    func currentActiveChannelID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeChannelID
    }

    /// Decide the presentation options for an incoming notification based on
    /// its category and the currently active channel. Extracted from
    /// `willPresent` so it can be unit-tested without constructing a
    /// `UNNotification` (which has no public initializer).
    func presentationOptions(
        forCategory category: String,
        channelID: UUID?
    ) -> UNNotificationPresentationOptions {
        // SOS is always interruptive — that's the point.
        if category == BlipNotificationCategory.sosAssist.rawValue
            || category == BlipRemotePushCategory.sos.rawValue {
            return [.banner, .sound, .badge]
        }

        // Suppress the foreground banner if the user is already inside the
        // relevant chat. Badge still updates so other channels' counts stay
        // accurate; sound is dropped because the bubble itself already
        // provides feedback.
        if let channelID, currentActiveChannelID() == channelID {
            switch category {
            case BlipNotificationCategory.newMessage.rawValue,
                 BlipRemotePushCategory.dm.rawValue,
                 BlipRemotePushCategory.group.rawValue:
                return [.badge]
            default:
                break
            }
        }

        return [.banner, .badge]
    }

    /// Tracks recently shown notification IDs to prevent duplicates within a short window.
    private var recentNotifications: [String: Date] = [:]
    private let deduplicationWindow: TimeInterval = 5.0
    private let lock = NSLock()

    // MARK: - Init

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        NotificationCategoryRegistry.registerAll(on: center)
    }

    // MARK: - Authorization

    /// Request explicit notification permissions from the user. Triggers
    /// the standard iOS permission dialog. Caller is responsible for
    /// presenting a pre-prompt screen first if desired.
    ///
    /// `.providesAppNotificationSettings` adds a "Notification Settings"
    /// shortcut inside iOS's notification UI so users can deep-link back
    /// to our in-app settings. `.criticalAlert` is intentionally omitted —
    /// it requires a separate Apple entitlement (see BDEV-421).
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .badge, .sound, .providesAppNotificationSettings]
            )
            isAuthorized = granted
            CrashReportingService.shared.addBreadcrumb(
                category: "push",
                message: "permission_grant_\(granted)"
            )
            return granted
        } catch {
            DebugLogger.shared.log(
                "PUSH",
                "Authorization request failed: \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    /// Check current authorization status.
    func checkAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Register with APNs for remote notifications if not yet registered.
    /// Always dispatched to the main thread per Apple's guidance.
    func registerRemoteNotificationsIfNeeded() async {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    // MARK: - New Message Notification

    /// Show a notification for a new incoming message.
    ///
    /// - Parameters:
    ///   - senderName: Display name of the message sender.
    ///   - messagePreview: Preview text of the message (truncated).
    ///   - channelID: The channel UUID for deep linking.
    ///   - channelName: Optional channel/group name.
    ///   - messageType: Type of message (text, voice, image).
    func notifyNewMessage(
        senderName: String,
        messagePreview: String,
        channelID: UUID,
        channelName: String?,
        messageType: String = "text"
    ) {
        guard notificationsEnabled else { return }
        guard !isDuplicate(id: "msg_\(channelID.uuidString)_\(senderName)") else { return }

        let content = UNMutableNotificationContent()

        if let channelName {
            content.title = channelName
            content.subtitle = senderName
        } else {
            content.title = senderName
        }

        switch messageType {
        case "voiceNote":
            content.body = "Sent a voice note"
        case "image":
            content.body = "Sent a photo"
        case "pttAudio":
            content.body = "Sent a walkie-talkie message"
        default:
            content.body = messagePreview
        }

        content.categoryIdentifier = BlipNotificationCategory.newMessage.rawValue
        content.sound = .default
        content.threadIdentifier = channelID.uuidString
        content.userInfo = [
            "channelID": channelID.uuidString,
            "senderName": senderName,
            "type": "newMessage"
        ]

        scheduleNotification(content: content, id: "msg_\(channelID.uuidString)_\(UUID().uuidString)")
    }

    // MARK: - Friend Nearby Notification

    /// Show a notification when a friend is detected on the local BLE mesh.
    ///
    /// Title-only — we don't claim a metres distance because RSSI doesn't
    /// translate cleanly to metres outside controlled environments.
    /// Caller (`MeshViewModel`) is responsible for gating on direct peer
    /// + signal-strength + recency before calling.
    func notifyFriendNearby(friendName: String, friendID: UUID) {
        guard notificationsEnabled else { return }
        guard !isDuplicate(id: "friend_nearby_\(friendID.uuidString)") else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(friendName) is nearby on the mesh"
        content.categoryIdentifier = BlipNotificationCategory.friendNearby.rawValue
        content.sound = UNNotificationSound(named: UNNotificationSoundName("friend_ping.caf"))
        content.userInfo = [
            "friendID": friendID.uuidString,
            "friendName": friendName,
            "type": "friendNearby"
        ]

        scheduleNotification(content: content, id: "friend_nearby_\(friendID.uuidString)")
    }

    // MARK: - Set Time Alert

    /// Schedule a notification for an upcoming set time (artist performance).
    ///
    /// - Parameters:
    ///   - artistName: Name of the artist.
    ///   - stageName: Name of the stage.
    ///   - startTime: When the set starts.
    ///   - reminderMinutes: Minutes before the set to fire the notification.
    func scheduleSetTimeAlert(
        artistName: String,
        stageName: String,
        startTime: Date,
        setTimeID: UUID,
        reminderMinutes: Int = 15
    ) {
        let content = UNMutableNotificationContent()
        content.title = "\(artistName) starting soon"
        content.body = "\(stageName) in \(reminderMinutes) minutes"
        content.categoryIdentifier = BlipNotificationCategory.setTimeAlert.rawValue
        content.sound = .default
        content.userInfo = [
            "setTimeID": setTimeID.uuidString,
            "artistName": artistName,
            "stageName": stageName,
            "type": "setTimeAlert"
        ]

        // Calculate trigger time
        let fireDate = startTime.addingTimeInterval(-TimeInterval(reminderMinutes * 60))
        let now = Date()
        guard fireDate > now else { return } // Don't schedule past alerts

        let triggerDate = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)

        let request = UNNotificationRequest(
            identifier: "settime_\(setTimeID.uuidString)",
            content: content,
            trigger: trigger
        )

        center.add(request)
    }

    /// Cancel a scheduled set time alert.
    func cancelSetTimeAlert(setTimeID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["settime_\(setTimeID.uuidString)"])
    }

    // MARK: - SOS Nearby Assist

    /// Show a high-priority notification for a nearby SOS alert.
    ///
    /// - Parameters:
    ///   - severity: SOS severity level.
    ///   - alertID: The SOS alert UUID.
    ///   - distance: Approximate distance in meters.
    ///   - message: Optional description from the reporter.
    func notifySOSNearby(
        severity: String,
        alertID: UUID,
        distance: Int,
        message: String?
    ) {
        let content = UNMutableNotificationContent()

        switch severity {
        case "red":
            content.title = "EMERGENCY nearby"
            content.sound = UNNotificationSound.defaultCritical
        case "amber":
            content.title = "Help needed nearby"
            content.sound = UNNotificationSound.defaultCritical
        default:
            content.title = "Assistance request nearby"
            content.sound = .default
        }

        if let message, !message.isEmpty {
            content.body = message
        } else {
            content.body = "Someone about \(distance)m away needs help"
        }

        content.categoryIdentifier = BlipNotificationCategory.sosAssist.rawValue
        content.interruptionLevel = .critical
        content.userInfo = [
            "alertID": alertID.uuidString,
            "severity": severity,
            "distance": distance,
            "type": "sosAssist"
        ]

        scheduleNotification(content: content, id: "sos_\(alertID.uuidString)")
    }

    /// Notify that an SOS alert has been resolved.
    func notifySOSResolved(alertID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "SOS Alert Resolved"
        content.body = "The nearby emergency has been handled"
        content.categoryIdentifier = BlipNotificationCategory.sosResolved.rawValue
        content.sound = .default
        content.userInfo = ["alertID": alertID.uuidString, "type": "sosResolved"]

        scheduleNotification(content: content, id: "sos_resolved_\(alertID.uuidString)")

        // Remove the original SOS notification
        center.removeDeliveredNotifications(withIdentifiers: ["sos_\(alertID.uuidString)"])
    }

    // MARK: - Friend Request

    /// Show a notification for an incoming friend request.
    func notifyFriendRequest(fromName: String, friendID: UUID) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Friend Request"
        content.body = "\(fromName) wants to be friends"
        content.categoryIdentifier = BlipNotificationCategory.friendRequest.rawValue
        content.sound = .default
        content.userInfo = [
            "friendID": friendID.uuidString,
            "friendName": fromName,
            "type": "friendRequest"
        ]

        scheduleNotification(content: content, id: "friendreq_\(friendID.uuidString)")
    }

    /// Show a notification when someone accepts your friend request.
    func notifyFriendAccepted(friendName: String, friendID: UUID) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Friend Request Accepted"
        content.body = "\(friendName) accepted your friend request"
        content.categoryIdentifier = BlipNotificationCategory.friendRequest.rawValue
        content.sound = .default
        content.userInfo = [
            "friendID": friendID.uuidString,
            "friendName": friendName,
            "type": "friendAccepted"
        ]

        scheduleNotification(content: content, id: "friendaccept_\(friendID.uuidString)")
    }

    // MARK: - Organizer Announcement

    /// Show a notification for an organizer announcement.
    func notifyOrgAnnouncement(eventName: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = eventName
        content.body = message
        content.categoryIdentifier = BlipNotificationCategory.organizerAnnouncement.rawValue
        content.sound = .default
        content.userInfo = ["type": "orgAnnouncement", "event": eventName]

        scheduleNotification(content: content, id: "org_\(UUID().uuidString)")
    }

    // MARK: - Badge Management

    /// Update the app badge count.
    func updateBadge(count: Int) {
        center.setBadgeCount(count)
    }

    /// Clear all delivered notifications.
    func clearAllDelivered() {
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }

    /// Remove delivered notifications for a specific channel.
    func clearNotifications(forChannel channelID: UUID) {
        center.getDeliveredNotifications { notifications in
            let matching = notifications.filter { notification in
                notification.request.content.threadIdentifier == channelID.uuidString
            }
            let ids = matching.map(\.request.identifier)
            Task { @MainActor [weak self] in
                self?.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    // MARK: - Remote push helpers

    /// Handle a silent push — invoked from AppDelegate's `didReceiveRemoteNotification`
    /// completion handler path. Currently only the `silent_badge_sync` type is
    /// supported; other silent payloads are a no-op here.
    func handleSilentRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard
            let aps = userInfo["aps"] as? [String: Any],
            aps["content-available"] as? Int == 1,
            let blip = userInfo["blip"] as? [String: Any],
            (blip["type"] as? String) == "silent_badge_sync",
            let count = blip["badgeCount"] as? Int
        else {
            return
        }
        Task { @MainActor in
            BadgeSyncService.shared.applyServerBadge(count)
        }
    }

    // MARK: - Private: Scheduling

    private func scheduleNotification(content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // Deliver immediately
        )
        center.add(request)
    }

    // MARK: - Private: Deduplication

    private func isDuplicate(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // Clean up old entries
        recentNotifications = recentNotifications.filter { now.timeIntervalSince($0.value) < deduplicationWindow }

        if recentNotifications[id] != nil {
            return true
        }

        recentNotifications[id] = now
        return false
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: @preconcurrency UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let userInfo = content.userInfo
        let channelID: UUID? = {
            if let id = userInfo["channelID"] as? String, let uuid = UUID(uuidString: id) {
                return uuid
            }
            if let blip = userInfo["blip"] as? [String: Any],
               let id = blip["threadId"] as? String,
               let uuid = UUID(uuidString: id) {
                return uuid
            }
            return nil
        }()
        return presentationOptions(
            forCategory: content.categoryIdentifier,
            channelID: channelID
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo

        // Prefer the remote-push path when the envelope looks like HEY1321
        // (has a `blip` dictionary). Remote actions dispatch through the
        // background worker; default tap goes through the router.
        let hasRemoteEnvelope = info["blip"] is [String: Any]

        if hasRemoteEnvelope {
            let textInput = (response as? UNTextInputNotificationResponse)?.userText
            let actionID = response.actionIdentifier

            // UNSafe bridge: `[AnyHashable: Any]` is not Sendable, but APNs
            // payloads are JSON-compatible value trees — safe to pass across
            // the MainActor hop. The `@unchecked Sendable` wrapper pins this
            // promise so the compiler stops warning.
            let snapshot = UnsafeNotificationPayload(info)

            if actionID == UNNotificationDefaultActionIdentifier {
                await MainActor.run {
                    NotificationRouter.shared.route(userInfo: snapshot.value)
                }
            } else if actionID != UNNotificationDismissActionIdentifier {
                await NotificationActionBackgroundWorker.shared.handle(
                    action: actionID,
                    userInfo: snapshot.value,
                    textInput: textInput
                )
            }
        } else {
            let stringInfo = info as? [String: Any] ?? [:]

            if let textResponse = response as? UNTextInputNotificationResponse {
                delegate?.notificationService(self, didReceiveReplyText: textResponse.userText, with: stringInfo)
            } else if let action = BlipNotificationAction(rawValue: response.actionIdentifier) {
                delegate?.notificationService(self, didReceiveAction: action, with: stringInfo)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                delegate?.notificationService(self, didReceiveAction: .openConversation, with: stringInfo)
            }
        }

        // Clear lingering banners for the channel that was just tapped/swiped — leaving
        // them queued in Notification Centre after the user has already opened the
        // conversation is the kind of detail users notice in a "godmode" app.
        let channelStringCandidate: String? = {
            if let s = info["channelID"] as? String { return s }
            if let blip = info["blip"] as? [String: Any],
               let s = blip["threadId"] as? String {
                return s
            }
            return nil
        }()
        if let channelString = channelStringCandidate,
           let channelID = UUID(uuidString: channelString) {
            clearNotifications(forChannel: channelID)
        }
    }
}
