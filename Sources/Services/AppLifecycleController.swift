import Foundation
import UserNotifications
import UIKit
import os.log
import BlipMesh

/// Owns runtime-bound observers, timers, and transport lifecycle concerns.
@MainActor
final class AppLifecycleController {
    private let runtime: AppRuntime
    private let logger = Logger(subsystem: "com.blip", category: "AppLifecycleController")

    private var broadcastObservation: NSObjectProtocol?
    private var peerStateObservation: NSObjectProtocol?
    private var foregroundObservation: NSObjectProtocol?
    private var badgeResetObservation: NSObjectProtocol?
    private var peerSyncTimer: Timer?
    private var announceTimer: Timer?
    private var peerPruneTimer: Timer?
    private var authRefreshTimer: Timer?
    private var currentPeerSyncInterval: TimeInterval?
    private var lastSyncedPeerIDs = Set<Data>()
    private var lastPostedTransportState: TransportStateSnapshot?

    private struct TransportStateSnapshot: Equatable {
        let bleActive: Bool
        let wsConnected: Bool
    }

    init(runtime: AppRuntime) {
        self.runtime = runtime
        setupBroadcastForwarding()
        setupPeerPersistence()
        setupForegroundObserver()
    }

    func start() {
        announceTimer?.invalidate()

        runtime.transportCoordinator.start()
        DebugLogger.shared.log("LIFECYCLE", "TransportCoordinator started")

        runtime.locationService.requestAuthorization()
        runtime.locationService.startUpdating(accuracy: .geohash)
        DebugLogger.shared.log("LIFECYCLE", "LocationService started (geohash accuracy)")

        runtime.messageRetryService.start()
        DebugLogger.shared.log("LIFECYCLE", "MessageRetryService started")

        Task { @MainActor in
            let notifGranted = await runtime.notificationService.requestAuthorization()
            DebugLogger.shared.log("LIFECYCLE", "NotificationService authorization: \(notifGranted ? "granted" : "denied")")
            if notifGranted {
                UIApplication.shared.registerForRemoteNotifications()
            }

            Task { await PushTokenManager.shared.uploadTokenIfNeeded() }

            await runtime.profileViewModel.loadProfile()
            if let user = runtime.profileViewModel.currentUser {
                CrashReportingService.shared.setUser(
                    id: user.id.uuidString,
                    username: user.username
                )
            }

            await runtime.chatViewModel.loadChannels()
            runtime.meshViewModel.startMonitoring()
            runtime.locationViewModel.startMonitoring()
            await runtime.eventsViewModel.loadEvents()
            await runtime.eventsViewModel.startGeofencing()
            await runtime.storeViewModel.start()
            DebugLogger.shared.log("LIFECYCLE", "StoreViewModel started (products + transaction listener)")
            await runtime.sosViewModel.loadResponderStatus()
            await runtime.sosViewModel.refreshVisibleAlerts()
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            do {
                try await runtime.messageService.broadcastPresence()
            } catch {
                DebugLogger.shared.log("PRESENCE", "Failed to broadcast presence: \(error.localizedDescription)", isError: true)
            }
        }

        let announceTimer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.runtime.messageService.broadcastPresence()
                } catch {
                    DebugLogger.emit("PRESENCE", "Failed to re-broadcast presence: \(error.localizedDescription)", isError: true)
                }
            }
        }
        RunLoop.main.add(announceTimer, forMode: .common)
        self.announceTimer = announceTimer

        let pruneTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runtime.peerStore.pruneStale(olderThan: 120)
            }
        }
        RunLoop.main.add(pruneTimer, forMode: .common)
        peerPruneTimer = pruneTimer

        runtime.messageCleanupService.start()

        if badgeResetObservation == nil {
            badgeResetObservation = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task {
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                }
            }
        }

        logger.info("Transports started")
    }

    func stop() {
        runtime.transportCoordinator.stop()
        authRefreshTimer?.invalidate()
        authRefreshTimer = nil
        peerSyncTimer?.invalidate()
        peerSyncTimer = nil
        currentPeerSyncInterval = nil
        announceTimer?.invalidate()
        announceTimer = nil
        peerPruneTimer?.invalidate()
        peerPruneTimer = nil
        lastSyncedPeerIDs.removeAll()
        lastPostedTransportState = nil
        runtime.messageCleanupService.stop()
        logger.info("Transports stopped")
    }

    func tearDown() {
        stop()

        if let observation = broadcastObservation {
            NotificationCenter.default.removeObserver(observation)
            broadcastObservation = nil
        }

        if let observation = peerStateObservation {
            NotificationCenter.default.removeObserver(observation)
            peerStateObservation = nil
        }

        if let observation = foregroundObservation {
            NotificationCenter.default.removeObserver(observation)
            foregroundObservation = nil
        }

        if let observation = badgeResetObservation {
            NotificationCenter.default.removeObserver(observation)
            badgeResetObservation = nil
        }
    }

    func establishAuthSession(forceRefresh: Bool = false) async {
        do {
            if forceRefresh {
                if runtime.authTokenManager.currentToken == nil {
                    _ = try await runtime.authTokenManager.validToken()
                } else {
                    try await runtime.authTokenManager.refreshIfNeeded(force: true)
                }
            } else {
                _ = try await runtime.authTokenManager.validToken()
            }

            DebugLogger.shared.log("AUTH", "JWT session ready")
            scheduleAuthRefreshTimer()
        } catch {
            DebugLogger.shared.log("AUTH", "JWT session bootstrap failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func setupForegroundObserver() {
        foregroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.runtime.bleService.recheckAuthorization()

            let ws = self.runtime.webSocketTransport
            guard ws.state != .running else { return }
            // Healthy resume path — the relay is intentionally torn down on
            // background (see BDEV-348) and re-established on foreground.
            // Phrase as the action being taken, not as an error condition,
            // so triage greps for "not running" surface only genuine wedges.
            DebugLogger.shared.log("APP", "Foreground resume: re-establishing relay (state=\(ws.state))")
            ws.reconnect(reason: "foreground_resume")
        }
    }

    private func setupBroadcastForwarding() {
        broadcastObservation = NotificationCenter.default.addObserver(
            forName: .shouldBroadcastPacket,
            object: nil,
            queue: nil
        ) { [weak coordinator = runtime.transportCoordinator, logger] notification in
            guard let data = notification.userInfo?["data"] as? Data else { return }
            coordinator?.broadcast(data: data)
            logger.debug("Forwarded broadcast packet (\(data.count) bytes)")
        }
    }

    private func setupPeerPersistence() {
        peerStateObservation = NotificationCenter.default.addObserver(
            forName: .meshPeerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncMeshPeers()
            }
        }

        schedulePeerSyncTimer(forConnectedPeerCount: runtime.bleService.connectedPeers.count)
    }

    private func schedulePeerSyncTimer(forConnectedPeerCount count: Int) {
        let interval: TimeInterval = count > 0 ? 5.0 : 15.0
        guard peerSyncTimer == nil || currentPeerSyncInterval != interval else { return }

        peerSyncTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncMeshPeers()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peerSyncTimer = timer
        currentPeerSyncInterval = interval
    }

    private func currentTransportStateSnapshot() -> TransportStateSnapshot {
        TransportStateSnapshot(
            bleActive: runtime.bleService.state == .running,
            wsConnected: runtime.webSocketTransport.state == .running
        )
    }

    private func postTransportStateIfNeeded(_ snapshot: TransportStateSnapshot) {
        guard snapshot != lastPostedTransportState else { return }

        NotificationCenter.default.post(
            name: .meshTransportStateChanged,
            object: nil,
            userInfo: [
                "bleActive": snapshot.bleActive,
                "wsConnected": snapshot.wsConnected
            ]
        )
        lastPostedTransportState = snapshot
    }

    private func syncMeshPeers() {
        let bleService = runtime.bleService
        let connectedPeerIDs = bleService.connectedPeers
        let connectedSet = Set(connectedPeerIDs.map(\.bytes))
        let transportState = currentTransportStateSnapshot()
        let peerSetChanged = connectedSet != lastSyncedPeerIDs

        schedulePeerSyncTimer(forConnectedPeerCount: connectedPeerIDs.count)

        guard !connectedPeerIDs.isEmpty || peerSetChanged else {
            postTransportStateIfNeeded(transportState)
            return
        }

        for peerID in connectedPeerIDs {
            if peerID == runtime.identity.peerID { continue }

            let peerData = peerID.bytes
            let existingPeer = runtime.peerStore.peer(for: peerData)
            let hasSignalData = bleService.hasConnectedPeripheral(for: peerID)
            let info = PeerInfo(
                peerID: peerData,
                noisePublicKey: existingPeer?.noisePublicKey ?? peerData,
                signingPublicKey: existingPeer?.signingPublicKey ?? Data(),
                username: existingPeer?.username,
                rssi: hasSignalData ? (bleService.rssi(for: peerID) ?? PeerInfo.noSignalRSSI) : PeerInfo.noSignalRSSI,
                isConnected: true,
                lastSeenAt: Date(),
                hopCount: 1,
                transportType: .bluetooth
            )
            runtime.peerStore.upsert(peer: info)
        }

        runtime.peerStore.markDisconnectedExcept(activePeerIDs: connectedSet)
        runtime.peerStore.pruneStale(olderThan: 300)

        postTransportStateIfNeeded(transportState)
        lastSyncedPeerIDs = connectedSet

        if !connectedPeerIDs.isEmpty {
            DebugLogger.shared.log("SYNC", "Peer sync: \(connectedPeerIDs.count) connected")
        }
    }

    private enum PushWakeError: LocalizedError {
        case relayConnectTimedOut
        case relayFailed(String)

        var errorDescription: String? {
            switch self {
            case .relayConnectTimedOut:
                return "Relay reconnect timed out during push wake"
            case .relayFailed(let reason):
                return "Relay reconnect failed: \(reason)"
            }
        }
    }

    func handlePushWakeUp(
        source: String = "silent",
        completionHandler: ((UIBackgroundFetchResult) -> Void)? = nil
    ) {
        let ws = runtime.webSocketTransport
        let initialState = ws.state
        let pushWakeStartedAt = Date()

        CrashReportingService.shared.addBreadcrumb(
            category: "push",
            message: "Push wake started (\(source), wsState=\(initialState))"
        )
        DebugLogger.shared.log("PUSH", "Push wake-up started (\(source), wsState=\(initialState))")

        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler?(.failed)
                return
            }

            do {
                if initialState != .running {
                    // Healthy wake path — silent push wakes the app while
                    // the relay is suspended; we re-establish to drain
                    // queued packets. Match the foreground-resume phrasing
                    // (BDEV-353) so triage greps stay clean.
                    DebugLogger.shared.log("PUSH", "Push wake-up: re-establishing relay (state=\(initialState))")
                    ws.reconnect(reason: "push_wake")
                    try await awaitWebSocketRunning(timeout: .seconds(8))
                } else {
                    DebugLogger.shared.log("PUSH", "Push wake-up: relay already connected")
                }

                await runtime.messageRetryService.triggerScan()
                let drainWindowMilliseconds = makeDrainWindowMilliseconds(
                    initialState: initialState,
                    pushWakeStartedAt: pushWakeStartedAt
                )
                try await Task.sleep(for: .milliseconds(drainWindowMilliseconds))

                CrashReportingService.shared.addBreadcrumb(
                    category: "push",
                    message: "Push wake completed (\(source), drainWindowMs=\(drainWindowMilliseconds))"
                )
                if let completionHandler {
                    completionHandler(.newData)
                }
            } catch {
                DebugLogger.shared.log("PUSH", "Push wake-up failed: \(error.localizedDescription)", isError: true)
                let context: [String: Any] = [
                    "operation": "push_wake",
                    "source": source,
                    "initialWebSocketState": String(describing: initialState)
                ]
                if case PushWakeError.relayConnectTimedOut = error {
                    CrashReportingService.shared.captureMessage(
                        "Push wake relay reconnect timed out",
                        level: .warning
                    )
                } else {
                    CrashReportingService.shared.captureError(error, context: context)
                }
                if let completionHandler {
                    completionHandler(.failed)
                }
            }
        }
    }

    private func awaitWebSocketRunning(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch runtime.webSocketTransport.state {
            case .running:
                return
            case .failed(let reason):
                throw PushWakeError.relayFailed(reason)
            default:
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        throw PushWakeError.relayConnectTimedOut
    }

    private func makeDrainWindowMilliseconds(
        initialState: TransportState,
        pushWakeStartedAt: Date
    ) -> Int {
        let minimumDrainMs = initialState == .running ? 1_000 : 2_000
        let maximumDrainMs = initialState == .running ? 5_000 : 10_000
        let totalBudgetMs = 28_000
        let safetyBufferMs = 2_000
        let elapsedMs = max(Int(Date().timeIntervalSince(pushWakeStartedAt) * 1_000), 0)
        let remainingDrainBudgetMs = totalBudgetMs - elapsedMs - safetyBufferMs
        let clampedDrainMs = min(maximumDrainMs, remainingDrainBudgetMs)
        return max(minimumDrainMs, clampedDrainMs)
    }

    private func scheduleAuthRefreshTimer() {
        authRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.runtime.authTokenManager.refreshIfNeeded()
                } catch {
                    DebugLogger.shared.log("AUTH", "Scheduled JWT refresh failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        authRefreshTimer = timer
    }
}
