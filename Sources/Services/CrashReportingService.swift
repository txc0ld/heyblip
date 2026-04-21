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
        // Don't initialise Sentry when the process is hosting the test harness.
        // Xcode's test action sets XCTestConfigurationFilePath for both XCTest
        // and Swift Testing runs. Without this guard, any runtime trap inside a
        // test function (force-unwrap, precondition, #expect via trap) is
        // captured as a fatal mach exception and mailed out.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            logger.info("Sentry disabled — running under test harness")
            return
        }

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

        isConfigured = true
        logger.info("Sentry crash reporting configured")
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
