import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Thin wrapper over the server-authoritative badge-sync API.
///
/// The server is authoritative for unread counts. The client never
/// increments the badge locally; it only:
///   - clears a thread's unread on the server when the user opens it
///   - clears all threads' unread on explicit user action
///   - applies the badge value supplied by `silent_badge_sync` pushes
@MainActor
final class BadgeSyncService {

    static let shared = BadgeSyncService()

    private let authTokenProvider: @Sendable () async throws -> String

    private init(
        authTokenProvider: @escaping @Sendable () async throws -> String = {
            try await AuthTokenManager.shared.validToken()
        }
    ) {
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Public API

    /// Fire-and-forget: tell the server the user has read this thread.
    func clearThread(_ channelID: UUID) {
        let body: [String: Any] = ["threadId": channelID.uuidString]
        Task { [authTokenProvider] in
            await Self.post(
                body: body,
                authTokenProvider: authTokenProvider,
                breadcrumb: "badge_clear_thread"
            )
        }
    }

    /// Fire-and-forget: tell the server to clear the user's entire badge.
    func clearAll() {
        let body: [String: Any] = ["all": true]
        Task { [authTokenProvider] in
            await Self.post(
                body: body,
                authTokenProvider: authTokenProvider,
                breadcrumb: "badge_clear_all"
            )
        }
    }

    /// Apply a server-supplied badge count. Called from silent
    /// `silent_badge_sync` pushes.
    func applyServerBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                DebugLogger.emit(
                    "PUSH",
                    "setBadgeCount(\(count)) failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "badge_applied_\(count)"
        )
    }

    // MARK: - Private

    nonisolated private static func post(
        body: [String: Any],
        authTokenProvider: @Sendable () async throws -> String,
        breadcrumb: String
    ) async {
        guard let url = URL(string: "\(ServerConfig.authBaseURL)/badge/clear") else {
            DebugLogger.emit("PUSH", "BadgeSync invalid URL", isError: true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DebugLogger.emit(
                "PUSH",
                "BadgeSync body encode failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        do {
            let token = try await authTokenProvider()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } catch {
            DebugLogger.emit(
                "PUSH",
                "BadgeSync auth token fetch failed: \(error.localizedDescription)",
                isError: true
            )
            return
        }

        do {
            let (_, response) = try await ServerConfig.pinnedSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                DebugLogger.emit(
                    "PUSH",
                    "BadgeSync \(breadcrumb) non-2xx status=\(http.statusCode)",
                    isError: true
                )
            } else {
                DebugLogger.emit("PUSH", "BadgeSync \(breadcrumb) ok")
            }
        } catch {
            // Fire-and-forget — log and move on.
            DebugLogger.emit(
                "PUSH",
                "BadgeSync \(breadcrumb) failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
