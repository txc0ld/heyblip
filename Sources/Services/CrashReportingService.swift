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

            // Defence in depth — the test-harness guard in
            // fix/sentry-skip-test-harness should make this unreachable, but
            // also drop any event that slips through with a fake event_id.
            //
            // Also: split DebugLogger.captureMessage events by their `[TAG]`
            // prefix so unrelated [AUTH] / [NOISE] / [PUSH] log captures stop
            // collapsing onto one mixed-fingerprint Sentry issue (BDEV-417).
            options.beforeSend = { event in
                if let envName = event.environment, envName == "development",
                   ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    return nil
                }
                if let eventID = event.tags?["blip.event_id"],
                   Self.isSuspiciousEventID(eventID) {
                    return nil
                }
                if let formatted = event.message?.formatted,
                   let fingerprint = Self.fingerprintForLogMessage(formatted) {
                    event.fingerprint = fingerprint
                }
                return event
            }
        }

        // The `Embed Git Info` post-build script in project.yml injects
        // GitCommitHash, GitBranch, and BuildDate into the product's Info.plist
        // on every build. Read them here so every event carries the exact
        // commit that shipped it.
        let info = Bundle.main.infoDictionary
        SentrySDK.configureScope { scope in
            if let hash = info?["GitCommitHash"] as? String {
                scope.setTag(value: hash, key: "git.commit")
            }
            if let branch = info?["GitBranch"] as? String {
                scope.setTag(value: branch, key: "git.branch")
            }
            if let buildDate = info?["BuildDate"] as? String {
                scope.setTag(value: buildDate, key: "build.date")
            }
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

    /// Derive a stable Sentry fingerprint from a `[TAG] message body` log
    /// string captured via `DebugLogger.captureMessage`. The default
    /// fingerprint groups by call-site stack frame, which collapses
    /// unrelated tagged log captures onto a single Sentry issue (BDEV-417 —
    /// APPLE-IOS-1Z was bucketing [AUTH] 429 with [NOISE] msg2 failures).
    ///
    /// Returns `nil` for messages that don't start with a `[TAG]` prefix —
    /// those keep Sentry's default grouping (crashes, ANRs, NSExceptions).
    ///
    /// Numeric runs (HTTP status codes, byte lengths, hex prefixes) inside
    /// the message are normalised to `N` so e.g. `HTTP 429` and `HTTP 500`
    /// group together under `[AUTH] Challenge request failed HTTP N`.
    static func fingerprintForLogMessage(_ message: String) -> [String]? {
        guard message.hasPrefix("["),
              let close = message.firstIndex(of: "]") else { return nil }
        let tag = String(message[message.index(after: message.startIndex)..<close])
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let after = message.index(after: close)
        let rest = String(message[after...]).trimmingCharacters(in: .whitespaces)
        // Take the first ~60 chars so we don't fingerprint by per-event
        // values (peer IDs, byte counts) that appear later in the line.
        let head = String(rest.prefix(60))
        let normalised = head.replacingOccurrences(
            of: #"\d+"#,
            with: "N",
            options: .regularExpression
        )
        return ["log", tag, normalised]
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
