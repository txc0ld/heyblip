import Foundation
import Sentry
import os

/// Thin wrapper around Sentry SDK for crash reporting, ANR detection,
/// and breadcrumb logging. All mesh/BLE events are forwarded as
/// breadcrumbs via DebugLogger integration.
final class CrashReportingService {

    static let shared = CrashReportingService()

    private let logger = Logger(subsystem: "com.blip.app", category: "crash-reporting")

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
        }

        logger.info("Sentry crash reporting configured")
    }

    /// Set user context (call after auth/profile load).
    func setUser(id: String, username: String?) {
        let user = Sentry.User()
        user.userId = id
        user.username = username
        SentrySDK.setUser(user)
    }

    /// Clear user context on logout.
    func clearUser() {
        SentrySDK.setUser(nil)
    }

    /// Add a breadcrumb manually (for important non-crash events).
    func addBreadcrumb(category: String, message: String, level: SentryLevel = .info) {
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Capture a non-fatal error with optional context.
    func captureError(_ error: Error, context: [String: Any]? = nil) {
        SentrySDK.capture(error: error) { scope in
            if let context {
                scope.setContext(value: context, key: "blip")
            }
        }
    }

    /// Capture a message (for important events that aren't errors).
    func captureMessage(_ message: String, level: SentryLevel = .info) {
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
    }
}
