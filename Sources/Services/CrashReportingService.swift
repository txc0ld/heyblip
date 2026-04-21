import Foundation
import Sentry
import os

/// Thin wrapper around Sentry SDK for crash reporting, ANR detection,
/// and breadcrumb logging. All mesh/BLE events are forwarded as
/// breadcrumbs via DebugLogger integration.
final class CrashReportingService: @unchecked Sendable {

    static let shared = CrashReportingService()

    private let logger = Logger(subsystem: "com.blip.app", category: "crash-reporting")

    /// Whether Sentry SDK has been successfully started.
    /// All public methods no-op when this is false.
    private(set) var isConfigured = false

    private init() {}

    /// Call once at app launch, before any other setup.
    /// DSN should come from Info.plist (build config), never hardcoded.
    func configure(dsn: String, environment: String = "production") {
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment

            // Performance monitoring — sample 20% of transactions
            options.tracesSampleRate = 0.2

            // Detect ANR (App Not Responding)
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 5.0

            // Capture HTTP client errors for relay/auth server calls
            options.enableCaptureFailedRequests = true
            options.failedRequestStatusCodes = [
                HttpStatusCodeRange(min: 400, max: 599)
            ]

            // Attach screenshots on crash
            options.attachScreenshot = true

            // Don't send PII by default
            options.sendDefaultPii = false

            #if DEBUG
            options.debug = true
            options.environment = "development"
            #endif

            // Defence in depth — the test-harness guard in
            // fix/sentry-skip-test-harness should make this unreachable, but
            // also drop any event that slips through with a fake event_id.
            options.beforeSend = { event in
                if let envName = event.environment, envName == "development",
                   ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    return nil
                }
                if let eventID = event.tags?["blip.event_id"],
                   Self.isSuspiciousEventID(eventID) {
                    return nil
                }
                return event
            }
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: BuildInfo.gitHash, key: "git.commit")
            scope.setTag(value: BuildInfo.gitBranch, key: "git.branch")
            scope.setTag(value: BuildInfo.buildDate, key: "build.date")
            // Scheme leaks through the BLE service UUID — debug scheme uses ...FA,
            // release uses ...FB. Tag so crashes from each are filterable.
            if let bleUUID = ProcessInfo.processInfo.environment["BLE_SERVICE_UUID"] {
                scope.setTag(value: bleUUID, key: "ble.service_uuid")
            }
        }

        isConfigured = true
        logger.info("Sentry crash reporting configured")
    }

    /// Tag every subsequent event with the active event id/name (or clear the
    /// tags when the user leaves the geofence). Crash filters in the dashboard
    /// can then scope by event without needing per-event Sentry projects.
    func setActiveEvent(id: String?, name: String?) {
        guard isConfigured else { return }
        SentrySDK.configureScope { scope in
            if let id { scope.setTag(value: id, key: "blip.event_id") }
            else { scope.removeTag(key: "blip.event_id") }
            if let name { scope.setTag(value: name, key: "blip.event_name") }
            else { scope.removeTag(key: "blip.event_name") }
        }
    }

    private static func isSuspiciousEventID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        return lowered == "test" || lowered == "fake" || lowered == "null" || lowered == "undefined"
    }

    /// Set user context (call after auth/profile load).
    func setUser(id: String, username: String?) {
        guard isConfigured else { return }
        let user = Sentry.User()
        user.userId = id
        user.username = username
        SentrySDK.setUser(user)
    }

    /// Clear user context on logout.
    func clearUser() {
        guard isConfigured else { return }
        SentrySDK.setUser(nil)
    }

    /// Add a breadcrumb manually (for important non-crash events).
    func addBreadcrumb(category: String, message: String, level: SentryLevel = .info) {
        guard isConfigured else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Capture a non-fatal error with optional context.
    func captureError(_ error: Error, context: [String: Any]? = nil) {
        guard isConfigured else { return }
        SentrySDK.capture(error: error) { scope in
            if let context {
                scope.setContext(value: context, key: "blip")
            }
        }
    }

    /// Capture a message (for important events that aren't errors).
    func captureMessage(_ message: String, level: SentryLevel = .info) {
        guard isConfigured else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
    }
}
