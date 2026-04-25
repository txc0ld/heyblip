import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Manages APNs device token registration and upload to the backend.
///
/// Fire-and-forget — errors are logged but never surface to the user. The
/// manager re-uploads the token on every meaningful event (onboarding,
/// auth refresh, locale change, app version bump, periodic stale-check on
/// foreground) so the server always has the freshest metadata.
@MainActor
final class PushTokenManager {

    static let shared = PushTokenManager()

    // MARK: - State

    private(set) var currentToken: String?
    private(set) var lastUploadedToken: String?

    // MARK: - Persisted Markers (UserDefaults)

    private let lastUploadedTokenKey = "com.blip.push.lastUploadedToken"
    private let lastUploadedAtKey = "com.blip.push.lastUploadedAt"
    private let lastUploadedAppVersionKey = "com.blip.push.lastUploadedAppVersion"
    private let lastUploadedLocaleKey = "com.blip.push.lastUploadedLocale"

    /// Re-upload if the most recent successful upload is older than this.
    private let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Consecutive register failures — drives Sentry escalation once we
    /// cross the threshold (3+ in a row).
    private var consecutiveFailures = 0

    // MARK: - Observation

    private var tokenCancellable: AnyCancellable?
    private var observersInstalled = false

    private init() {
        // Hydrate "last uploaded" marker from defaults so we don't spam the
        // server on every launch.
        let defaults = UserDefaults.standard
        lastUploadedToken = defaults.string(forKey: lastUploadedTokenKey)

        installObserversIfNeeded()
    }

    // MARK: - AppDelegate callbacks

    /// Called by AppDelegate when APNs assigns a device token.
    func didRegisterToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        currentToken = hex
        DebugLogger.shared.log("PUSH", "APNs token registered: \(DebugLogger.redactHex(hex))")
        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "token_registered"
        )
        Task {
            await uploadTokenIfNeeded()
        }
    }

    /// Called by AppDelegate when APNs registration fails.
    func didFailToRegister(_ error: Error) {
        DebugLogger.shared.log("PUSH", "APNs registration failed: \(error.localizedDescription)", isError: true)
        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "register_failed: \(error.localizedDescription)",
            level: .warning
        )
    }

    // MARK: - Public lifecycle hooks

    /// Called from AppCoordinator when onboarding completes. Re-registers for
    /// remote notifications (in case permissions were granted late) and
    /// uploads the current token if present.
    func refreshAfterOnboarding() {
        DebugLogger.shared.log("PUSH", "refreshAfterOnboarding — re-registering with APNs")
        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "refresh_after_onboarding"
        )
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        Task { await self.uploadTokenIfNeeded(force: true) }
    }

    // MARK: - Upload

    /// Uploads the current token to the backend if the token, locale, or app
    /// version changed since last upload, or if the last upload is older
    /// than `refreshInterval`, or if `force` is true.
    func uploadTokenIfNeeded(force: Bool = false) async {
        guard let token = currentToken else { return }

        let defaults = UserDefaults.standard
        let currentLocale = Locale.current.identifier
        let currentVersion = Self.currentAppVersion()
        let lastToken = defaults.string(forKey: lastUploadedTokenKey)
        let lastLocale = defaults.string(forKey: lastUploadedLocaleKey)
        let lastVersion = defaults.string(forKey: lastUploadedAppVersionKey)
        let lastUploadedAt = defaults.object(forKey: lastUploadedAtKey) as? Date

        let shouldUpload: Bool = {
            if force { return true }
            if lastToken != token { return true }
            if lastLocale != currentLocale { return true }
            if lastVersion != currentVersion { return true }
            if let lastUploadedAt, Date().timeIntervalSince(lastUploadedAt) > refreshInterval {
                return true
            }
            return false
        }()

        guard shouldUpload else { return }

        let body = DeviceRegisterBody(
            token: token,
            platform: "ios",
            bundleId: Bundle.main.bundleIdentifier ?? "",
            locale: currentLocale,
            appVersion: currentVersion,
            sandbox: Self.isSandboxBuild
        )

        do {
            try await UserSyncService().registerDeviceToken(body: body)
            lastUploadedToken = token
            consecutiveFailures = 0

            defaults.set(token, forKey: lastUploadedTokenKey)
            defaults.set(Date(), forKey: lastUploadedAtKey)
            defaults.set(currentVersion, forKey: lastUploadedAppVersionKey)
            defaults.set(currentLocale, forKey: lastUploadedLocaleKey)

            DebugLogger.shared.log(
                "PUSH",
                "Device token uploaded: \(DebugLogger.redactHex(token)) (bundle=\(body.bundleId), locale=\(currentLocale), v\(currentVersion), sandbox=\(body.sandbox))"
            )
            CrashReportingService.shared.addBreadcrumb(
                category: "push",
                message: "token_uploaded"
            )
        } catch {
            consecutiveFailures += 1
            DebugLogger.shared.log(
                "PUSH",
                "Device token upload failed (attempt #\(consecutiveFailures)): \(error.localizedDescription)",
                isError: true
            )
            CrashReportingService.shared.addBreadcrumb(
                category: "push",
                message: "token_upload_failed: \(error.localizedDescription)",
                level: .warning
            )
            if consecutiveFailures >= 3 {
                CrashReportingService.shared.captureMessage(
                    "Push token upload failing repeatedly (\(consecutiveFailures) in a row)",
                    level: .warning
                )
            }
        }
    }

    // MARK: - Clear

    /// Unregisters the current token from the backend and clears local state.
    /// Called on sign out / account deletion.
    func clearToken() async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastUploadedTokenKey)
        defaults.removeObject(forKey: lastUploadedAtKey)
        defaults.removeObject(forKey: lastUploadedAppVersionKey)
        defaults.removeObject(forKey: lastUploadedLocaleKey)

        guard let token = currentToken else {
            currentToken = nil
            lastUploadedToken = nil
            return
        }
        do {
            try await UserSyncService().unregisterDeviceToken(token)
            DebugLogger.shared.log("PUSH", "Device token unregistered: \(DebugLogger.redactHex(token))")
        } catch {
            DebugLogger.shared.log(
                "PUSH",
                "Device token unregister failed: \(error.localizedDescription)",
                isError: true
            )
        }
        currentToken = nil
        lastUploadedToken = nil
        consecutiveFailures = 0
    }

    // MARK: - Observers

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // Observe auth token refreshes. AuthTokenManager publishes
        // `currentToken` via @Published; we ignore initial nil and react
        // whenever the value rotates (login, refresh).
        tokenCancellable = AuthTokenManager.shared.$currentToken
            .removeDuplicates()
            .sink { [weak self] newValue in
                guard let self, newValue != nil else { return }
                Task { @MainActor in
                    DebugLogger.shared.log("PUSH", "Auth token changed — re-uploading device token")
                    await self.uploadTokenIfNeeded(force: true)
                }
            }

        let center = NotificationCenter.default

        center.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                DebugLogger.shared.log("PUSH", "Locale changed — re-uploading device token")
                await self?.uploadTokenIfNeeded(force: true)
            }
        }

        #if canImport(UIKit)
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.uploadTokenIfNeeded()
            }
        }
        #endif
    }

    // MARK: - Helpers

    private static func currentAppVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private static var isSandboxBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Register Body

/// Extended device registration body sent to `${authBaseURL}/devices/register`.
/// Carried fields let the server pick the right APNs environment, filter by
/// locale, and age out stale devices on app upgrades.
struct DeviceRegisterBody: Sendable {
    let token: String
    let platform: String
    let bundleId: String
    let locale: String
    let appVersion: String
    let sandbox: Bool
}
