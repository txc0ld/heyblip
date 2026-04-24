import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Handles tapped category actions from the lock screen / Notification
/// Centre. Runs work in the background via a UIApplication background task
/// so the OS can suspend us cleanly once the handler completes.
///
/// Non-foreground actions (Reply, Mark Read, Mute 1h, Accept/Decline) land
/// here. Foreground actions (SOS View, SOS Call Responder) open the app and
/// flow through `NotificationRouter` instead.
@MainActor
final class NotificationActionBackgroundWorker {

    static let shared = NotificationActionBackgroundWorker()

    weak var coordinator: AppCoordinator?

    private init() {}

    // MARK: - Entry point

    /// Dispatch an action identifier to the right handler. `textInput` is
    /// populated when the action is the DM Reply (UNTextInputNotificationAction).
    func handle(
        action rawAction: String,
        userInfo: [AnyHashable: Any],
        textInput: String?
    ) async {
        guard let action = BlipRemoteNotificationAction(rawValue: rawAction) else {
            DebugLogger.shared.log("PUSH", "Worker: unknown action \(rawAction)")
            return
        }

        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "action_\(action.rawValue)"
        )

        let taskID = beginBackgroundTask()
        defer { endBackgroundTask(taskID) }

        let blip = (userInfo["blip"] as? [String: Any]) ?? [:]

        switch action {
        case .accept:
            await handleFriendAccept(blip: blip)
        case .decline:
            await handleFriendDecline(blip: blip)
        case .reply:
            await handleReply(blip: blip, text: textInput ?? "")
        case .markRead:
            await handleMarkRead(blip: blip)
        case .mute1h:
            await handleMute1h(blip: blip)
        case .viewSOS, .callResponder:
            // Foreground actions — routing handled by NotificationRouter.
            NotificationRouter.shared.route(userInfo: userInfo)
        }
    }

    // MARK: - Action handlers

    private func handleFriendAccept(blip: [String: Any]) async {
        guard let peerHex = blip["senderPeerIdHex"] as? String ?? blip["threadId"] as? String,
              !peerHex.isEmpty else {
            DebugLogger.shared.log("PUSH", "Worker: Accept missing peerIdHex", isError: true)
            return
        }
        guard let friend = fetchFriend(byPeerHex: peerHex) else {
            DebugLogger.shared.log(
                "PUSH",
                "Worker: Accept: no local Friend for peer \(DebugLogger.redactHex(peerHex))"
            )
            return
        }
        guard let messageService = coordinator?.messageService else {
            DebugLogger.shared.log("PUSH", "Worker: Accept: MessageService not ready", isError: true)
            return
        }
        do {
            try await messageService.acceptFriendRequest(from: friend)
            DebugLogger.shared.log("PUSH", "Worker: accepted friend \(DebugLogger.redactHex(peerHex))")
        } catch {
            DebugLogger.shared.log(
                "PUSH",
                "Worker: acceptFriendRequest failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleFriendDecline(blip: [String: Any]) async {
        guard let peerHex = blip["senderPeerIdHex"] as? String ?? blip["threadId"] as? String,
              !peerHex.isEmpty else {
            DebugLogger.shared.log("PUSH", "Worker: Decline missing peerIdHex", isError: true)
            return
        }
        guard let friend = fetchFriend(byPeerHex: peerHex) else {
            DebugLogger.shared.log(
                "PUSH",
                "Worker: Decline: no local Friend for peer \(DebugLogger.redactHex(peerHex))"
            )
            return
        }

        // There is no `MessageService.declineFriendRequest` — flip the
        // local Friend status to "declined" directly. This matches
        // `AppCoordinator.handleNotificationAction(.declineFriend)`.
        friend.statusRaw = "declined"
        do {
            if let context = coordinator?.runtime?.modelContainer.mainContext {
                try context.save()
            }
        } catch {
            DebugLogger.shared.log(
                "PUSH",
                "Worker: decline save failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleReply(blip: [String: Any], text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DebugLogger.shared.log("PUSH", "Worker: Reply empty")
            return
        }
        guard let threadID = blip["threadId"] as? String,
              let channelID = UUID(uuidString: threadID) else {
            DebugLogger.shared.log("PUSH", "Worker: Reply missing/invalid threadId", isError: true)
            return
        }
        guard let channel = fetchChannel(id: channelID),
              let messageService = coordinator?.messageService else {
            DebugLogger.shared.log("PUSH", "Worker: Reply: channel or service missing", isError: true)
            return
        }
        do {
            try await messageService.sendTextMessage(content: trimmed, to: channel)
            DebugLogger.shared.log("PUSH", "Worker: Reply sent to \(channelID)")
        } catch {
            DebugLogger.shared.log(
                "PUSH",
                "Worker: Reply send failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleMarkRead(blip: [String: Any]) async {
        guard let threadID = blip["threadId"] as? String,
              let channelID = UUID(uuidString: threadID) else {
            DebugLogger.shared.log("PUSH", "Worker: MarkRead missing threadId", isError: true)
            return
        }

        // Local: flip unread + fire ChatViewModel's normal flow if it's
        // already loaded, otherwise touch the Channel directly.
        if let chatVM = coordinator?.chatViewModel,
           let channel = fetchChannel(id: channelID) {
            chatVM.markChannelAsRead(channel)
        } else if let channel = fetchChannel(id: channelID) {
            channel.unreadCount = 0
            do {
                if let context = coordinator?.runtime?.modelContainer.mainContext {
                    try context.save()
                }
            } catch {
                DebugLogger.shared.log(
                    "PUSH",
                    "Worker: markRead save failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        // Server: authoritative clear.
        BadgeSyncService.shared.clearThread(channelID)
    }

    private func handleMute1h(blip: [String: Any]) async {
        guard let threadID = blip["threadId"] as? String,
              let channelID = UUID(uuidString: threadID) else {
            DebugLogger.shared.log("PUSH", "Worker: Mute1h missing threadId", isError: true)
            return
        }

        // The project's NotificationPreferencesService is owned by another
        // agent and may not exist at compile time in this slice. We keep the
        // best-effort contract: tag the channel locally with a short mute
        // window, and log a breadcrumb so the preferences service (when it
        // lands) can converge.
        if let channel = fetchChannel(id: channelID) {
            channel.muteStatus = .mutedTimed
            do {
                if let context = coordinator?.runtime?.modelContainer.mainContext {
                    try context.save()
                }
            } catch {
                DebugLogger.shared.log(
                    "PUSH",
                    "Worker: mute save failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        // Post a NotificationCenter event so `NotificationPreferencesService`
        // (added by a sibling agent) can pick up the mute deadline without
        // this worker importing that service directly.
        NotificationCenter.default.post(
            name: Notification.Name("com.blip.notification.muteChannelRequest"),
            object: nil,
            userInfo: [
                "channelID": channelID,
                "until": Date().addingTimeInterval(3_600)
            ]
        )

        DebugLogger.shared.log("PUSH", "Worker: Mute1h set for \(channelID)")
    }

    // MARK: - Fetch helpers

    private func fetchChannel(id: UUID) -> Channel? {
        guard let context = coordinator?.runtime?.modelContainer.mainContext else { return nil }
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == id })
        do {
            return try context.fetch(descriptor).first
        } catch {
            DebugLogger.shared.log("PUSH", "Worker: fetchChannel failed: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    private func fetchFriend(byPeerHex peerHex: String) -> Friend? {
        guard let context = coordinator?.runtime?.modelContainer.mainContext else { return nil }
        let keyData = Self.hexToBytes(peerHex)
        guard !keyData.isEmpty else { return nil }
        do {
            let friends = try context.fetch(FetchDescriptor<Friend>())
            return friends.first { friend in
                guard let user = friend.user else { return false }
                return user.noisePublicKey == keyData
                    || user.noisePublicKey.prefix(keyData.count) == keyData
            }
        } catch {
            DebugLogger.shared.log("PUSH", "Worker: fetchFriend failed: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    private static func hexToBytes(_ hex: String) -> Data {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count.isMultiple(of: 2) else { return Data() }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return Data() }
            data.append(byte)
            idx = next
        }
        return data
    }

    // MARK: - Background task wrapper

    #if canImport(UIKit)
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "blip.push.action") {
            // Expiration handler — nothing to do, the defer will no-op once
            // the task identifier is invalid.
        }
    }

    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
    #else
    private func beginBackgroundTask() -> Int { 0 }
    private func endBackgroundTask(_ id: Int) {}
    #endif
}
