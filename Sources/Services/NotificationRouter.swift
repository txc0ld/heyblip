import Foundation

/// Parses a received (or tapped) notification's `blip` envelope and
/// emits a `NotificationDestination` on `AppCoordinator.pendingNotificationNavigation`.
///
/// All deeplink parsing for push notifications flows through this class so
/// the AppCoordinator stays thin and UI code has a single source of truth.
@MainActor
final class NotificationRouter {

    static let shared = NotificationRouter()

    weak var coordinator: AppCoordinator?

    private init() {}

    // MARK: - Public

    /// Route a notification tap. Reads `blip.deeplink` (preferred) or falls
    /// back to `blip.type` + `blip.threadId`. No-op if the coordinator is
    /// not yet wired or the envelope is malformed.
    func route(userInfo: [AnyHashable: Any]) {
        guard let destination = destination(from: userInfo) else {
            DebugLogger.shared.log("PUSH", "Router: no actionable destination in userInfo", isError: true)
            return
        }

        guard let coordinator else {
            DebugLogger.shared.log("PUSH", "Router: coordinator not wired yet — dropping \(destination)")
            return
        }

        coordinator.pendingNotificationNavigation = destination
        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "route_\(destinationBreadcrumb(destination))"
        )
    }

    /// Expose the parse step so `NotificationActionBackgroundWorker` can
    /// reuse the same envelope normalisation without triggering navigation.
    func destination(from userInfo: [AnyHashable: Any]) -> NotificationDestination? {
        let blip = blipEnvelope(from: userInfo)

        // Prefer an explicit deeplink if present.
        if let deeplink = blip["deeplink"] as? String,
           let url = URL(string: deeplink),
           url.scheme == "blip" {
            if let parsed = parseDeeplink(url) {
                return parsed
            }
        }

        // Fallback: infer from type + threadId.
        let type = blip["type"] as? String
        let threadID = blip["threadId"] as? String

        switch type {
        case "dm", "group_message", "group_mention", "voice_note":
            if let threadID, let uuid = UUID(uuidString: threadID) {
                return .conversation(channelID: uuid)
            }
        case "friend_request", "friend_accept":
            // threadId is the friend peer hex for friend envelopes — we
            // can't navigate directly without a Friend UUID, so we
            // surface the existing friend-request destination keyed by
            // a synthesised UUID derived from the peer hex hash.
            if let threadID, let peerUUID = syntheticUUID(fromHex: threadID) {
                return .friendRequest(friendID: peerUUID)
            }
        case "sos":
            if let threadID, let uuid = UUID(uuidString: threadID) {
                return .sosAlert(alertID: uuid)
            }
        default:
            break
        }

        return nil
    }

    // MARK: - Private

    private func parseDeeplink(_ url: URL) -> NotificationDestination? {
        // blip://channel/<UUID>, blip://friend/<peerHex>, blip://sos/<UUID>
        let host = url.host ?? ""
        let last = url.lastPathComponent
        switch host {
        case "channel":
            if let uuid = UUID(uuidString: last) { return .conversation(channelID: uuid) }
        case "friend":
            if let peerUUID = syntheticUUID(fromHex: last) {
                return .friendRequest(friendID: peerUUID)
            }
        case "sos":
            if let uuid = UUID(uuidString: last) { return .sosAlert(alertID: uuid) }
        default:
            break
        }
        return nil
    }

    private func blipEnvelope(from userInfo: [AnyHashable: Any]) -> [String: Any] {
        if let dict = userInfo["blip"] as? [String: Any] { return dict }
        // Some paths (AppDelegate under bridged APIs) hand us [String: Any]
        // already; match via string key as a safety net.
        if let dict = userInfo[AnyHashable("blip")] as? [String: Any] { return dict }
        return [:]
    }

    /// Derive a stable UUID from an 8+ byte peer hex so we can surface a
    /// friend-scoped destination before the Friend SwiftData record is
    /// resolved. The SwiftData-backed Friend.id is still the source of
    /// truth for navigation in-app — routers downstream lookup by peer hex
    /// to resolve the real Friend.
    private func syntheticUUID(fromHex hex: String) -> UUID? {
        let padded: String
        if hex.count >= 32 {
            padded = String(hex.prefix(32))
        } else {
            padded = hex + String(repeating: "0", count: max(0, 32 - hex.count))
        }
        guard padded.count == 32 else { return nil }
        let formatted = "\(padded.prefix(8))-\(padded.dropFirst(8).prefix(4))-\(padded.dropFirst(12).prefix(4))-\(padded.dropFirst(16).prefix(4))-\(padded.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted.uppercased())
    }

    private func destinationBreadcrumb(_ destination: NotificationDestination) -> String {
        switch destination {
        case .conversation: return "conversation"
        case .friendRequest: return "friend"
        case .sosAlert: return "sos"
        }
    }
}
