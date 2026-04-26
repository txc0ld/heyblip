import Foundation
import SwiftData

// MARK: - Wire Format

/// Body sent to `POST /v1/users/notification-prefs`. Keep in sync with the
/// locked contract in the HEY-1321 push notifications PR.
private struct NotificationPrefsRequestBody: Encodable {
    struct MutedChannel: Encodable {
        let channelId: String
        let until: String?
    }
    struct MutedFriend: Encodable {
        let peerIdHex: String
        let until: String?
    }

    let dmEnabled: Bool
    let friendRequestsEnabled: Bool
    let groupMentionsEnabled: Bool
    let voiceNotesEnabled: Bool
    let quietHoursStartUtc: Int?
    let quietHoursEndUtc: Int?
    let utcOffsetSeconds: Int
    let mutedChannels: [MutedChannel]
    let mutedFriends: [MutedFriend]
}

private struct NotificationPrefsResponse: Decodable {
    let updated: Bool
}

// MARK: - Service

/// Owns push-notification preferences: reads from SwiftData, persists mutations,
/// syncs to the auth server, and mirrors mute state into the shared App-Group
/// cache so the NSE can apply mutes on the very next push.
///
/// Lifecycle:
/// - `configure(modelContext:)` is called once at app launch with the root
///   `ModelContext`. Without this, every accessor returns a best-effort value
///   and logs.
/// - Every mutator is fire-and-forget `sync()`: we don't block the UI on the
///   network round-trip. If the POST fails we log and retry on the next change.
/// - `sync()` is idempotent — calling it repeatedly with the same state is fine.
@MainActor
final class NotificationPreferencesService {

    static let shared = NotificationPreferencesService()

    private var modelContext: ModelContext?
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    // MARK: - Configuration

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Preferences (reads)

    /// Fetches the singleton `UserPreferences` row, creating one if it doesn't
    /// exist. The app maintains at most one `UserPreferences` instance.
    func currentPreferences() -> UserPreferences {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "modelContext not configured — returning transient UserPreferences")
            return UserPreferences()
        }

        let descriptor = FetchDescriptor<UserPreferences>()
        do {
            let existing = try modelContext.fetch(descriptor)
            if let first = existing.first {
                return first
            }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "Failed to fetch UserPreferences: \(error.localizedDescription)",
                isError: true
            )
        }

        let prefs = UserPreferences()
        modelContext.insert(prefs)
        do {
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "Failed to insert UserPreferences: \(error.localizedDescription)",
                isError: true
            )
        }
        return prefs
    }

    // MARK: - Type toggles

    func updateDMsEnabled(_ value: Bool) async {
        mutatePreferences { $0.notificationsDMsEnabled = value }
        await fireAndForgetSync()
    }

    func updateFriendRequestsEnabled(_ value: Bool) async {
        mutatePreferences { $0.notificationsFriendRequestsEnabled = value }
        await fireAndForgetSync()
    }

    func updateGroupMentionsEnabled(_ value: Bool) async {
        mutatePreferences { $0.notificationsGroupMentionsEnabled = value }
        await fireAndForgetSync()
    }

    func updateVoiceNotesEnabled(_ value: Bool) async {
        mutatePreferences { $0.notificationsVoiceNotesEnabled = value }
        await fireAndForgetSync()
    }

    // MARK: - Quiet hours

    /// `startUtc` / `endUtc` are minutes-of-day in UTC (0..<1440) or nil to
    /// disable. Both must be non-nil for the window to be active server-side.
    func updateQuietHours(startUtc: Int?, endUtc: Int?) async {
        let clampedStart = startUtc.map { max(0, min(1439, $0)) }
        let clampedEnd = endUtc.map { max(0, min(1439, $0)) }
        mutatePreferences {
            $0.quietHoursStartUtc = clampedStart
            $0.quietHoursEndUtc = clampedEnd
        }
        await fireAndForgetSync()
    }

    // MARK: - Channel mutes

    func muteChannel(_ channelID: UUID, until: Date?) async {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "muteChannel: modelContext not configured", isError: true)
            return
        }

        // Replace any existing mute row so the user-facing "until" value
        // always reflects the last selection — avoids two stacked rows.
        let target = channelID
        let descriptor = FetchDescriptor<ChannelMute>(
            predicate: #Predicate { $0.channelID == target }
        )
        do {
            let existing = try modelContext.fetch(descriptor)
            for mute in existing {
                modelContext.delete(mute)
            }
            let mute = ChannelMute(channelID: channelID, until: until)
            modelContext.insert(mute)
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "muteChannel failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        await writeMuteMirrorToAppGroup()
        await fireAndForgetSync()
    }

    func unmuteChannel(_ channelID: UUID) async {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "unmuteChannel: modelContext not configured", isError: true)
            return
        }

        let target = channelID
        let descriptor = FetchDescriptor<ChannelMute>(
            predicate: #Predicate { $0.channelID == target }
        )
        do {
            let existing = try modelContext.fetch(descriptor)
            for mute in existing {
                modelContext.delete(mute)
            }
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "unmuteChannel failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        await writeMuteMirrorToAppGroup()
        await fireAndForgetSync()
    }

    // MARK: - Friend mutes

    func muteFriend(peerIdHex: String, until: Date?) async {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "muteFriend: modelContext not configured", isError: true)
            return
        }

        let target = peerIdHex
        let descriptor = FetchDescriptor<FriendMute>(
            predicate: #Predicate { $0.peerIdHex == target }
        )
        do {
            let existing = try modelContext.fetch(descriptor)
            for mute in existing {
                modelContext.delete(mute)
            }
            let mute = FriendMute(peerIdHex: peerIdHex, until: until)
            modelContext.insert(mute)
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "muteFriend failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        await writeMuteMirrorToAppGroup()
        await fireAndForgetSync()
    }

    func unmuteFriend(peerIdHex: String) async {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "unmuteFriend: modelContext not configured", isError: true)
            return
        }

        let target = peerIdHex
        let descriptor = FetchDescriptor<FriendMute>(
            predicate: #Predicate { $0.peerIdHex == target }
        )
        do {
            let existing = try modelContext.fetch(descriptor)
            for mute in existing {
                modelContext.delete(mute)
            }
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "unmuteFriend failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        await writeMuteMirrorToAppGroup()
        await fireAndForgetSync()
    }

    // MARK: - Queries (used by NotificationService / UI)

    func isChannelMuted(_ channelID: UUID) -> Bool {
        guard let modelContext else { return false }
        let target = channelID
        let descriptor = FetchDescriptor<ChannelMute>(
            predicate: #Predicate { $0.channelID == target }
        )
        do {
            let mutes = try modelContext.fetch(descriptor)
            return mutes.contains { $0.isActive }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "isChannelMuted fetch failed: \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    func isFriendMuted(_ peerIdHex: String) -> Bool {
        guard let modelContext else { return false }
        let target = peerIdHex
        let descriptor = FetchDescriptor<FriendMute>(
            predicate: #Predicate { $0.peerIdHex == target }
        )
        do {
            let mutes = try modelContext.fetch(descriptor)
            return mutes.contains { $0.isActive }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "isFriendMuted fetch failed: \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    // MARK: - Server sync

    /// POSTs the current preferences + active mutes to the auth server. Called
    /// fire-and-forget from every mutator and, on demand, from callers that
    /// want to force a push (e.g. after login when prefs were restored).
    func sync() async {
        guard let body = buildRequestBody() else {
            DebugLogger.emit("PUSH_PREFS", "sync: no preferences context — skipping")
            return
        }

        let token: String
        do {
            token = try await AuthTokenManager.shared.validToken()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "sync: JWT unavailable — skipping (\(error.localizedDescription))",
                isError: true
            )
            return
        }

        guard let url = URL(string: "\(ServerConfig.authBaseURL)/users/notification-prefs") else {
            DebugLogger.emit("PUSH_PREFS", "sync: invalid URL", isError: true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = request.attachTraceID(category: "PUSH_PREFS")

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "sync: encode failed \(error.localizedDescription)",
                isError: true
            )
            return
        }

        do {
            let (data, response) = try await ServerConfig.pinnedSession.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                DebugLogger.emit("PUSH_PREFS", "sync: non-HTTP response", isError: true)
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                DebugLogger.emit(
                    "PUSH_PREFS",
                    "sync: server returned \(http.statusCode)",
                    isError: true
                )
                return
            }

            if let parsed = try? JSONDecoder().decode(NotificationPrefsResponse.self, from: data),
               parsed.updated {
                DebugLogger.emit("PUSH_PREFS", "sync ok")
            } else {
                DebugLogger.emit("PUSH_PREFS", "sync ok (unparsed body)")
            }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "sync: network error \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Helpers

    private func mutatePreferences(_ body: (UserPreferences) -> Void) {
        guard let modelContext else {
            DebugLogger.emit("PUSH_PREFS", "mutate: modelContext not configured", isError: true)
            return
        }
        let prefs = currentPreferences()
        body(prefs)
        do {
            try modelContext.save()
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "mutate save failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func fireAndForgetSync() async {
        // Detached from the mutator so the UI toggle doesn't await network.
        Task { [weak self] in
            await self?.sync()
        }
    }

    private func buildRequestBody() -> NotificationPrefsRequestBody? {
        guard let modelContext else { return nil }
        let prefs = currentPreferences()

        let channelMutes = activeChannelMutes(context: modelContext)
        let friendMutes = activeFriendMutes(context: modelContext)

        let mutedChannels = channelMutes.map { mute in
            NotificationPrefsRequestBody.MutedChannel(
                channelId: mute.channelID.uuidString,
                until: mute.until.map { iso8601.string(from: $0) }
            )
        }
        let mutedFriends = friendMutes.map { mute in
            NotificationPrefsRequestBody.MutedFriend(
                peerIdHex: mute.peerIdHex,
                until: mute.until.map { iso8601.string(from: $0) }
            )
        }

        return NotificationPrefsRequestBody(
            dmEnabled: prefs.notificationsDMsEnabled,
            friendRequestsEnabled: prefs.notificationsFriendRequestsEnabled,
            groupMentionsEnabled: prefs.notificationsGroupMentionsEnabled,
            voiceNotesEnabled: prefs.notificationsVoiceNotesEnabled,
            quietHoursStartUtc: prefs.quietHoursStartUtc,
            quietHoursEndUtc: prefs.quietHoursEndUtc,
            utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: Date()),
            mutedChannels: mutedChannels,
            mutedFriends: mutedFriends
        )
    }

    private func activeChannelMutes(context: ModelContext) -> [ChannelMute] {
        let descriptor = FetchDescriptor<ChannelMute>()
        do {
            return try context.fetch(descriptor).filter { $0.isActive }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "activeChannelMutes failed: \(error.localizedDescription)",
                isError: true
            )
            return []
        }
    }

    private func activeFriendMutes(context: ModelContext) -> [FriendMute] {
        let descriptor = FetchDescriptor<FriendMute>()
        do {
            return try context.fetch(descriptor).filter { $0.isActive }
        } catch {
            DebugLogger.emit(
                "PUSH_PREFS",
                "activeFriendMutes failed: \(error.localizedDescription)",
                isError: true
            )
            return []
        }
    }

    /// Writes active mutes through to the App-Group cache so the NSE can apply
    /// them on the very next push without waiting for a round-trip through the
    /// server.
    ///
    /// NOTE: `NotificationEnrichmentCacheWriter` does not currently expose an
    /// `updateMutes(channels:friends:)` method — it only has per-entity
    /// upsert/remove for display metadata. The call site below is staged for
    /// the follow-up in this PR that adds the mute mirror to the cache
    /// schema + writer. Until then this method is a no-op that logs the
    /// pending sync, so the service API is stable for consumers.
    private func writeMuteMirrorToAppGroup() async {
        guard let modelContext else { return }
        let channels = activeChannelMutes(context: modelContext).map { $0.channelID }
        let friends = activeFriendMutes(context: modelContext).map { $0.peerIdHex }

        // TODO(HEY-1321): call
        //   await NotificationEnrichmentCacheWriter.shared.updateMutes(
        //       channels: channels,
        //       friends: friends
        //   )
        // once the writer exposes that API (owned by the NSE-cache slice).
        DebugLogger.emit(
            "PUSH_PREFS",
            "mute mirror pending: channels=\(channels.count) friends=\(friends.count)"
        )
    }
}
