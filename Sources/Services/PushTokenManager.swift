import Foundation

/// Manages APNs device token registration and upload to the backend.
/// Fire-and-forget — errors are logged but never surface to the user.
@MainActor
final class PushTokenManager {

    static let shared = PushTokenManager()

    private(set) var currentToken: String?
    private(set) var lastUploadedToken: String?

    private init() {}

    // MARK: - AppDelegate callbacks

    /// Called by AppDelegate when APNs assigns a device token.
    func didRegisterToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        currentToken = hex
        DebugLogger.shared.log("PUSH", "APNs token registered: \(DebugLogger.redactHex(hex))")
        Task {
            await uploadTokenIfNeeded()
        }
    }

    /// Called by AppDelegate when APNs registration fails.
    func didFailToRegister(_ error: Error) {
        DebugLogger.shared.log("PUSH", "APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Upload

    /// Uploads the current token to the backend if it differs from the last uploaded value.
    func uploadTokenIfNeeded() async {
        guard let token = currentToken, token != lastUploadedToken else { return }
        do {
            try await UserSyncService().registerDeviceToken(token)
            lastUploadedToken = token
            DebugLogger.shared.log("PUSH", "Device token uploaded: \(DebugLogger.redactHex(token))")
        } catch {
            DebugLogger.shared.log("PUSH", "Device token upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear

    /// Unregisters the current token from the backend and clears local state.
    func clearToken() async {
        guard let token = currentToken else { return }
        do {
            try await UserSyncService().unregisterDeviceToken(token)
            DebugLogger.shared.log("PUSH", "Device token unregistered: \(DebugLogger.redactHex(token))")
        } catch {
            DebugLogger.shared.log("PUSH", "Device token unregister failed: \(error.localizedDescription)")
        }
        currentToken = nil
        lastUploadedToken = nil
    }
}
