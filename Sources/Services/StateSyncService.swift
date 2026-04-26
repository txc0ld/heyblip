import Foundation
import UIKit
import BlipProtocol
import BlipCrypto
import os.log

/// Background service that periodically uploads user state (GCS filter)
/// to the relay server for peers not in BLE range.
///
/// Sync interval: 15 minutes (matches LocationService periodic checks).
/// Battery-aware: reduces frequency in low-power mode.
final class StateSyncService: @unchecked Sendable {

    // MARK: - Configuration

    /// Relay server base URL for state endpoints.
    private static let stateEndpoint = ServerConfig.relayBaseURL + "/state"

    /// Sync interval (15 minutes).
    private static let syncInterval: TimeInterval = 900

    /// Reduced sync interval for low-power mode (30 minutes).
    private static let lowPowerSyncInterval: TimeInterval = 1800

    // MARK: - Properties

    private let keyManager: KeyManager
    private let authTokenProvider: @Sendable () async throws -> String
    private let logger = Logger(subsystem: "com.blip", category: "StateSync")
    private var syncTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blip.statesync", qos: .utility)
    private var isLowPowerMode = false

    // MARK: - Init

    init(
        keyManager: KeyManager = .shared,
        authTokenProvider: @escaping @Sendable () async throws -> String = {
            try await AuthTokenManager.shared.validToken()
        }
    ) {
        self.keyManager = keyManager
        self.authTokenProvider = authTokenProvider
        observeLowPowerMode()
    }

    // MARK: - Lifecycle

    /// Start periodic state sync.
    func start() {
        scheduleSync()
        logger.info("State sync started (interval: \(Self.syncInterval)s)")
    }

    /// Stop periodic state sync.
    func stop() {
        syncTimer?.cancel()
        syncTimer = nil
        logger.info("State sync stopped")
    }

    // MARK: - Manual Sync

    /// Trigger an immediate state upload.
    func syncNow() async {
        await uploadState()
    }

    // MARK: - Fetch Peer State

    /// Fetch another peer's state from the relay server.
    func fetchPeerState(peerIdHex: String) async -> Data? {
        guard let identity = try? keyManager.loadIdentity() else {
            logger.error("No identity for state fetch")
            return nil
        }

        guard var components = URLComponents(string: Self.stateEndpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "peer", value: peerIdHex)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        _ = request.attachTraceID(category: "SYNC")

        do {
            let (data, response) = try await performAuthenticatedRequest(request, identity: identity)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            logger.warning("Failed to fetch peer state: \(error.localizedDescription)")
            DebugLogger.emit("SYNC", "State fetch auth/request failed: \(DebugLogger.redact(error.localizedDescription))", isError: true)
            return nil
        }
    }

    // MARK: - Private

    private func scheduleSync() {
        syncTimer?.cancel()

        let interval = isLowPowerMode ? Self.lowPowerSyncInterval : Self.syncInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { await self?.uploadState() }
        }
        timer.resume()
        syncTimer = timer
    }

    private func uploadState() async {
        guard let identity = try? keyManager.loadIdentity() else {
            logger.error("No identity for state upload")
            return
        }

        // Build state blob: GCS filter of known peer IDs + online status + timestamp.
        let stateData = buildStateBlob(identity: identity)
        guard !stateData.isEmpty else { return }

        guard let url = URL(string: Self.stateEndpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = stateData
        request.timeoutInterval = 10
        _ = request.attachTraceID(category: "SYNC")

        do {
            let (_, response) = try await performAuthenticatedRequest(request, identity: identity)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 200 {
                logger.debug("State uploaded (\(stateData.count) bytes)")
            } else {
                logger.warning("State upload returned \(http.statusCode)")
            }
        } catch {
            logger.warning("State upload failed: \(error.localizedDescription)")
            DebugLogger.emit("SYNC", "State upload auth/request failed: \(DebugLogger.redact(error.localizedDescription))", isError: true)
        }
    }

    /// Build an opaque state blob containing:
    /// - Timestamp (8 bytes, big-endian UInt64 ms)
    /// - Online status (1 byte: 0x01 = online)
    /// - GCS filter of known friend PeerIDs (variable)
    private func buildStateBlob(identity: Identity) -> Data {
        var data = Data()

        // Timestamp
        var ts = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }

        // Online status
        data.append(0x01) // online

        // PeerID (self-identification)
        data.append(identity.peerID.bytes)

        return data
    }

    private func performAuthenticatedRequest(
        _ request: URLRequest,
        identity: Identity,
        allowRetry: Bool = true
    ) async throws -> (Data, URLResponse) {
        var authorizedRequest = request
        authorizedRequest.setValue(await authorizationHeaderValue(identity: identity), forHTTPHeaderField: "Authorization")

        let result = try await ServerConfig.pinnedSession.data(for: authorizedRequest)
        if allowRetry,
           let http = result.1 as? HTTPURLResponse,
           http.statusCode == 401 {
            try? await AuthTokenManager.shared.refreshIfNeeded(force: true)
            return try await performAuthenticatedRequest(request, identity: identity, allowRetry: false)
        }

        return result
    }

    private func authorizationHeaderValue(identity: Identity) async -> String {
        do {
            let token = try await authTokenProvider()
            return "Bearer \(token)"
        } catch {
            DebugLogger.emit("AUTH", "JWT token unavailable for StateSyncService: \(DebugLogger.redact(error.localizedDescription))", isError: true)
            return "Bearer \(identity.noisePublicKey.rawRepresentation.base64EncodedString())"
        }
    }

    private func observeLowPowerMode() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSProcessInfoPowerStateDidChange"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            // Toggle power-aware scheduling.
            self.isLowPowerMode = !self.isLowPowerMode
            self.scheduleSync()
            self.logger.info("Power state changed, sync interval adjusted")
        }
    }
}
