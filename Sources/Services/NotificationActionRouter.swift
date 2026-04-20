import Foundation
import SwiftData
import os.log

@MainActor
final class NotificationActionRouter {
    struct Dependencies {
        let fetchChannel: @MainActor (UUID) -> Channel?
        let fetchFriend: @MainActor (UUID) -> Friend?
        let markChannelAsRead: @MainActor (Channel) -> Void
        let toggleMute: @MainActor (Channel) -> Void
        let acceptFriendRequest: @MainActor (Friend) async throws -> Void
        let declineFriendRequest: @MainActor (Friend) -> Void
        let visibleAlert: @MainActor (UUID) -> SOSViewModel.SOSAlertInfo?
        let acceptAlert: @MainActor (SOSViewModel.SOSAlertInfo) async -> Void
        let sendTextMessage: @MainActor (String, Channel) async throws -> Void
        let createDMDestination: @MainActor (String) async -> NotificationDestination?
    }

    private let dependencies: Dependencies
    private let logger = Logger(subsystem: "com.blip", category: "NotificationActionRouter")

    init(modelContainer: ModelContainer, runtime: AppRuntime) {
        self.dependencies = Dependencies(
            fetchChannel: { id in
                do {
                    return try modelContainer.mainContext.fetch(FetchDescriptor<Channel>()).first(where: { $0.id == id })
                } catch {
                    DebugLogger.shared.log("DB", "fetchChannel failed: \(error.localizedDescription)", isError: true)
                    return nil
                }
            },
            fetchFriend: { id in
                do {
                    return try modelContainer.mainContext.fetch(FetchDescriptor<Friend>()).first(where: { $0.id == id })
                } catch {
                    DebugLogger.shared.log("DB", "fetchFriend failed: \(error.localizedDescription)", isError: true)
                    return nil
                }
            },
            markChannelAsRead: { channel in
                runtime.chatViewModel.markChannelAsRead(channel)
            },
            toggleMute: { channel in
                runtime.chatViewModel.toggleMute(for: channel)
            },
            acceptFriendRequest: { friend in
                try await runtime.messageService.acceptFriendRequest(from: friend)
            },
            declineFriendRequest: { friend in
                friend.statusRaw = "declined"
            },
            visibleAlert: { alertID in
                runtime.sosViewModel.visibleAlerts.first(where: { $0.id == alertID })
            },
            acceptAlert: { alertInfo in
                await runtime.sosViewModel.acceptAlert(alertInfo)
            },
            sendTextMessage: { text, channel in
                _ = try await runtime.messageService.sendTextMessage(content: text, to: channel)
            },
            createDMDestination: { username in
                do {
                    let users = try modelContainer.mainContext.fetch(FetchDescriptor<User>())
                    guard let user = users.first(where: { $0.username == username }) else {
                        DebugLogger.shared.log("CHAT", "openDM: no user for username \(DebugLogger.redact(username))")
                        return nil
                    }
                    guard let channel = await runtime.chatViewModel.createDMChannel(with: user) else {
                        return nil
                    }
                    return .conversation(channelID: channel.id)
                } catch {
                    DebugLogger.shared.log("CHAT", "openDM failed: \(error.localizedDescription)", isError: true)
                    return nil
                }
            }
        )
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func handleAction(_ action: BlipNotificationAction, userInfo: [String: String]) async -> NotificationDestination? {
        switch action {
        case .openConversation:
            guard let channelID = parseUUID("channelID", from: userInfo) else { return nil }
            return .conversation(channelID: channelID)

        case .markRead:
            guard let channelID = parseUUID("channelID", from: userInfo),
                  let channel = dependencies.fetchChannel(channelID) else { return nil }
            dependencies.markChannelAsRead(channel)
            return nil

        case .mute:
            guard let channelID = parseUUID("channelID", from: userInfo),
                  let channel = dependencies.fetchChannel(channelID) else { return nil }
            dependencies.toggleMute(channel)
            return nil

        case .acceptFriend:
            guard let friendID = parseUUID("friendID", from: userInfo),
                  let friend = dependencies.fetchFriend(friendID) else { return nil }
            do {
                try await dependencies.acceptFriendRequest(friend)
            } catch {
                logger.error("Accept-friend action failed: \(error.localizedDescription)")
            }
            return nil

        case .declineFriend:
            guard let friendID = parseUUID("friendID", from: userInfo),
                  let friend = dependencies.fetchFriend(friendID) else { return nil }
            dependencies.declineFriendRequest(friend)
            return nil

        case .respondSOS:
            guard let alertID = parseUUID("alertID", from: userInfo),
                  let alert = dependencies.visibleAlert(alertID) else { return nil }
            await dependencies.acceptAlert(alert)
            return nil

        case .reply, .viewMap:
            return nil
        }
    }

    func handleReply(text: String, userInfo: [String: String]) async {
        guard !text.isEmpty,
              let channelID = parseUUID("channelID", from: userInfo),
              let channel = dependencies.fetchChannel(channelID) else { return }

        do {
            try await dependencies.sendTextMessage(text, channel)
        } catch {
            logger.error("Notification reply failed: \(error.localizedDescription)")
        }
    }

    func openDM(withUsername username: String) async -> NotificationDestination? {
        await dependencies.createDMDestination(username)
    }

    private func parseUUID(_ key: String, from userInfo: [String: String]) -> UUID? {
        guard let value = userInfo[key] else { return nil }
        return UUID(uuidString: value)
    }
}
