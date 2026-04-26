import UserNotifications

/// Notification Service Extension (NSE) for Blip.
///
/// The NSE is a short-lived, sandboxed process that iOS wakes when an APNs
/// payload with `mutable-content: 1` arrives. It has ~30s of wall-clock time
/// to enrich the notification before the system gives up and delivers the
/// original payload unchanged.
///
/// Blip's NSE performs zero-knowledge enrichment only: it looks up the
/// sender's display name and (for group messages) the channel name from an
/// App Group JSON cache that the main app keeps in sync. It does NOT attempt
/// Noise decryption — see `docs/NSE_DESIGN.md` for the rationale.
///
/// Safety contract:
///   - Never `fatalError`, never force-unwrap. The NSE runs in the user-
///     notification daemon; a crash kills delivery for the whole system.
///   - On any unexpected shape, fall back to the original notification
///     content via `contentHandler(request.content)`.
///   - `serviceExtensionTimeWillExpire` returns whatever we have so far so
///     the user still sees something — generic copy beats silence.
final class BlipNotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttempt = mutable

        guard let blip = request.content.userInfo["blip"] as? [String: Any],
              let type = blip["type"] as? String else {
            contentHandler(mutable)
            return
        }

        // Zero-knowledge enrichment only: look up friend displayName / channel name
        // from App Group cache. Never attempt Noise decryption.
        let cache = NotificationEnrichmentCacheReader.load()
        enrich(mutable: mutable, blip: blip, type: type, cache: cache)

        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS gives the NSE ~30s. If we're about to time out, deliver the
        // original-best-effort content so the user still sees *something* —
        // better a generic "New message" than silence.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    private func enrich(mutable: UNMutableNotificationContent,
                        blip: [String: Any],
                        type: String,
                        cache: NotificationEnrichmentCache?) {
        let senderHex = blip["senderPeerIdHex"] as? String
        let threadId = blip["threadId"] as? String

        let payloadDisplayName = (blip["senderDisplayName"] as? String)
            ?? (blip["senderUsername"] as? String)
        let friend = senderHex.flatMap { cache?.friends[$0] }
        let channel = threadId.flatMap { cache?.channels[$0] }

        // Cache hit wins for established friends (preserves user-set display
        // names). For senders the recipient hasn't befriended yet — friend
        // requests being the canonical case — fall through to the payload's
        // `senderUsername` (server-resolved). "Someone" is the last-resort
        // fallback (BDEV-409).
        let displayName: String = friend?.displayName ?? payloadDisplayName ?? "Someone"
        let channelName: String? = channel?.name

        switch type {
        case "friend_request":
            mutable.title = "Friend request"
            mutable.body  = "\(displayName) wants to connect"
            mutable.interruptionLevel = .passive
            mutable.categoryIdentifier = "FRIEND_REQUEST"
        case "friend_accept":
            mutable.title = "Friend request accepted"
            mutable.body  = "\(displayName) accepted your friend request"
            mutable.interruptionLevel = .passive
            mutable.categoryIdentifier = "FRIEND_ACCEPT"
        case "dm":
            mutable.title = displayName
            mutable.body  = "Sent you a message"
            mutable.interruptionLevel = .active
            mutable.categoryIdentifier = "DM"
        case "group_message":
            mutable.title = channelName ?? "New message"
            mutable.body  = "\(displayName) sent a message"
            mutable.interruptionLevel = .active
            mutable.categoryIdentifier = "GROUP"
        case "group_mention":
            mutable.title = channelName ?? "Mention"
            mutable.body  = "\(displayName) mentioned you"
            mutable.interruptionLevel = .timeSensitive
            mutable.categoryIdentifier = "GROUP"
        case "voice_note":
            mutable.title = displayName
            mutable.body  = "Sent a voice note"
            mutable.interruptionLevel = .active
            mutable.categoryIdentifier = "DM"
        case "sos":
            mutable.title = "Emergency nearby"
            mutable.body  = "Someone nearby needs help"
            mutable.interruptionLevel = .critical
            mutable.categoryIdentifier = "SOS"
            mutable.sound = UNNotificationSound.defaultCriticalSound(withAudioVolume: 1.0)
        case "silent_badge_sync":
            // Keep aps.content-available intact; no alert enrichment needed.
            return
        default:
            // Unknown type — preserve original content; likely a future feature.
            return
        }

        if let threadId {
            mutable.threadIdentifier = threadId
        }
    }
}
