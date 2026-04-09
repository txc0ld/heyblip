import Foundation
import CoreLocation
import SwiftData
import BlipProtocol
import BlipMesh
import BlipCrypto
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Wires BLE mesh, WebSocket relay, identity, and MessageService together on launch.
///
/// Lifecycle:
/// 1. Attempts to load identity from Keychain on init
/// 2. If identity exists: creates transports, configures MessageService, sets `isReady`
/// 3. If no identity: sets `needsOnboarding` so the UI shows onboarding flow
/// 4. Call `start()` to begin BLE scanning + WebSocket connection
/// 5. Call `stop()` for cleanup
@MainActor @Observable
final class AppCoordinator {

    // MARK: - Observable state

    /// Whether the coordinator has finished initializing and services are ready.
    private(set) var isReady = false

    /// Whether the user needs to complete onboarding (no identity found).
    private(set) var needsOnboarding = false

    /// Initialization error, if any.
    private(set) var initError: String?

    // MARK: - Services

    private(set) var bleService: BLEService?
    private(set) var webSocketTransport: WebSocketTransport?
    private(set) var transportCoordinator: TransportCoordinator?
    private(set) var meshRelayService: MeshRelayService?
    private(set) var messageService: MessageService?
    private(set) var messageRetryService: MessageRetryService?
    private(set) var peerStore = PeerStore.shared
    private(set) var locationService = LocationService()
    private(set) var notificationService = NotificationService()
    private(set) var backgroundTaskService: BackgroundTaskService?
    private(set) var authTokenManager = AuthTokenManager.shared

    // MARK: - Feature View Models

    private(set) var chatViewModel: ChatViewModel?
    private(set) var meshViewModel: MeshViewModel?
    private(set) var locationViewModel: LocationViewModel?
    private(set) var friendFinderViewModel: FriendFinderViewModel?
    private(set) var eventsViewModel: EventsViewModel?
    private(set) var profileViewModel: ProfileViewModel?
    private(set) var storeViewModel: StoreViewModel?
    private(set) var sosViewModel: SOSViewModel?

    // MARK: - Identity

    private(set) var identity: Identity?
    private(set) var localPeerID: PeerID?

    // MARK: - Dependencies

    private let keyManager: KeyManager
    private let logger = Logger(subsystem: "com.blip", category: "AppCoordinator")
    private var modelContainer: ModelContainer?
    @ObservationIgnored nonisolated(unsafe) private var broadcastObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var peerStateObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var foregroundObservation: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var peerSyncTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var announceTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var peerPruneTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var authRefreshTimer: Timer?
    private(set) var powerManager: PowerManager?
    private(set) var messageCleanupService: MessageCleanupService?
    @ObservationIgnored nonisolated(unsafe) private var powerTierCancellable: AnyCancellable?
    private var currentPeerSyncInterval: TimeInterval?
    private var lastSyncedPeerIDs = Set<Data>()
    private var lastPostedTransportState: TransportStateSnapshot?

    private struct TransportStateSnapshot: Equatable {
        let bleActive: Bool
        let wsConnected: Bool
    }

    // MARK: - Init

    init(keyManager: KeyManager = .shared) {
        self.keyManager = keyManager

        // Configure Sentry crash reporting early, before any other setup
        if let dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String, !dsn.isEmpty, !dsn.hasPrefix("$(") {
            CrashReportingService.shared.configure(dsn: dsn)
        }

        loadIdentityAndConfigure()
    }

    deinit {
        // Clean up NotificationCenter observers that may outlive the coordinator.
        // These are nonisolated(unsafe) so direct access from deinit is safe.
        if let obs = broadcastObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = peerStateObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        peerSyncTimer?.invalidate()
        announceTimer?.invalidate()
        peerPruneTimer?.invalidate()
    }

    // MARK: - Configuration

    private func loadIdentityAndConfigure() {
        do {
            guard let loadedIdentity = try keyManager.loadIdentity() else {
                logger.info("No identity found — onboarding required")
                needsOnboarding = true
                return
            }

            identity = loadedIdentity
            localPeerID = loadedIdentity.peerID

            logger.info("Identity loaded, PeerID: \(loadedIdentity.peerID)")
        } catch {
            logger.error("Failed to load identity: \(error.localizedDescription)")
            initError = "Failed to load identity: \(error.localizedDescription)"
            needsOnboarding = true
        }
    }

    /// Set up all services with a model container. Called after SwiftData is available.
    func configure(modelContainer: ModelContainer) {
        guard let identity = identity else {
            logger.warning("configure() called without identity")
            return
        }

        teardownRuntimeState()
        ensureUserPreferencesExists(in: modelContainer)
        locationService.delegate = self

        let peerID = identity.peerID

        // Create transports
        let ble = BLEService(localPeerID: peerID)
        let ws = WebSocketTransport(
            localPeerID: peerID,
            pinnedCertHashes: ServerConfig.pinnedCertHashes,
            pinnedDomains: ServerConfig.pinnedDomains,
            tokenProvider: { @Sendable in
                try await AuthTokenManager.shared.validToken()
            },
            tokenRefreshHandler: { @Sendable in
                try await AuthTokenManager.shared.refreshIfNeeded(force: true)
            },
            relayURL: ServerConfig.relayWebSocketURL
        )
        let coordinator = TransportCoordinator(
            bleTransport: ble,
            webSocketTransport: ws
        )

        // Wire BLE transport events to DebugLogger
        ble.transportEventHandler = { category, message in
            Task { @MainActor in
                DebugLogger.shared.log(category, message)
            }
        }

        // Create PowerManager and wire tier changes to BLEService
        let power = PowerManager()
        power.startMonitoring()
        self.powerManager = power
        powerTierCancellable = power.tierPublisher
            .removeDuplicates()
            .sink { [weak ble] tier in
                ble?.updatePowerTier(tier)
            }

        self.bleService = ble
        self.webSocketTransport = ws
        self.transportCoordinator = coordinator

        // Create and configure MessageService with TransportCoordinator
        // so messages route through the full BLE → WebSocket → local queue chain.
        let msgService = MessageService(modelContainer: modelContainer, keyManager: keyManager)
        msgService.configure(transport: coordinator, identity: identity)

        // Wire gossip relay middleware between transport and message service.
        // Data flow: BLE → TransportCoordinator → MeshRelayService → MessageService
        // Relay flow: MeshRelayService → TransportCoordinator.broadcast(excluding:)
        let relay = MeshRelayService(transport: coordinator)
        relay.delegate = msgService
        coordinator.delegate = relay
        self.meshRelayService = relay
        self.messageService = msgService

        // Create retry service for queued messages (exponential backoff)
        let retryService = MessageRetryService(modelContainer: modelContainer, messageService: msgService)
        self.messageRetryService = retryService

        self.messageCleanupService = MessageCleanupService(modelContainer: modelContainer)

        self.chatViewModel = ChatViewModel(
            modelContainer: modelContainer,
            messageService: msgService
        )
        self.meshViewModel = MeshViewModel(modelContainer: modelContainer, peerStore: peerStore)
        self.locationViewModel = LocationViewModel(
            modelContainer: modelContainer,
            locationService: locationService
        )
        self.friendFinderViewModel = FriendFinderViewModel(locationService: locationService)
        self.eventsViewModel = EventsViewModel(
            modelContainer: modelContainer,
            locationService: locationService,
            notificationService: notificationService
        )
        self.profileViewModel = ProfileViewModel(
            modelContainer: modelContainer,
            keyManager: keyManager
        )
        self.storeViewModel = StoreViewModel(modelContainer: modelContainer)
        self.sosViewModel = SOSViewModel(
            modelContainer: modelContainer,
            locationService: locationService,
            messageService: msgService,
            notificationService: notificationService
        )

        // Listen for broadcast requests from ViewModels (e.g. SOSViewModel).
        setupBroadcastForwarding(coordinator: coordinator)

        // Bridge BLE peer discovery to in-memory PeerStore.
        self.modelContainer = modelContainer
        setupPeerPersistence(bleService: ble)

        // Re-check Bluetooth permission when app returns from Settings.
        setupForegroundObserver(bleService: ble)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.establishAuthSession()
        }

        // Re-sync encryption keys to server for existing users (idempotent upsert).
        // Ensures users who registered before key upload was added get their keys uploaded.
        let keyMgr = keyManager
        Task {
            do {
                let context = ModelContext(modelContainer)
                let users = try context.fetch(FetchDescriptor<User>())
                guard let user = users.min(by: { $0.createdAt < $1.createdAt }),
                      !user.emailHash.isEmpty else {
                    DebugLogger.shared.log("AUTH", "Key re-sync skipped — no local user or empty emailHash")
                    return
                }
                guard let loadedIdentity = try keyMgr.loadIdentity() else {
                    DebugLogger.shared.log("AUTH", "Key re-sync skipped — no identity in Keychain")
                    return
                }

                let noiseKeyHex = loadedIdentity.noisePublicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
                let signingKeyHex = loadedIdentity.signingPublicKey.map { String(format: "%02x", $0) }.joined()
                DebugLogger.shared.log("AUTH", "Key re-sync starting for \(DebugLogger.redact(user.username)) — noiseKey: \(DebugLogger.redactHex(String(noiseKeyHex.prefix(16))))…, signingKey: \(DebugLogger.redactHex(String(signingKeyHex.prefix(16))))…")

                try await UserSyncService().registerUser(
                    emailHash: user.emailHash,
                    username: user.username,
                    noisePublicKey: loadedIdentity.noisePublicKey.rawRepresentation,
                    signingPublicKey: loadedIdentity.signingPublicKey
                )

                DebugLogger.shared.log("AUTH", "Key upload succeeded for \(DebugLogger.redact(user.username))")
                Task { @MainActor [weak self] in
                    await self?.establishAuthSession(forceRefresh: true)
                }
            } catch {
                DebugLogger.shared.log("AUTH", "Key upload failed: \(error.localizedDescription)", isError: true)
            }
        }

        // Wire background task service for BGTaskScheduler-based mesh sync.
        let bgService = BackgroundTaskService(coordinator: self)
        bgService.scheduleNextSync()
        self.backgroundTaskService = bgService

        isReady = true
        logger.info("AppCoordinator configured — services ready")

        // Self-check: verify local user is registered on the server.
        // Catches users who slipped through all registration retries.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.verifyServerRegistration(modelContainer: modelContainer)
        }
    }

    /// Re-check Bluetooth authorization when the app returns to foreground.
    /// If the user enabled Bluetooth in Settings, BLE starts automatically.
    private func setupForegroundObserver(bleService: BLEService) {
        foregroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak bleService] _ in
            bleService?.recheckAuthorization()
        }
    }

    /// Forward `.shouldBroadcastPacket` notifications to TransportCoordinator.
    private func setupBroadcastForwarding(coordinator: TransportCoordinator) {
        broadcastObservation = NotificationCenter.default.addObserver(
            forName: .shouldBroadcastPacket,
            object: nil,
            queue: nil
        ) { [weak coordinator, logger] notification in
            guard let data = notification.userInfo?["data"] as? Data else { return }
            coordinator?.broadcast(data: data)
            logger.debug("Forwarded broadcast packet (\(data.count) bytes)")
        }
    }

    /// Re-initialize after onboarding completes and identity is stored.
    /// Returns `true` only when identity was loaded AND transports were initialized.
    @discardableResult
    func reconfigureAfterOnboarding(modelContainer: ModelContainer) -> Bool {
        needsOnboarding = false
        initError = nil
        isReady = false

        loadIdentityAndConfigure()

        if identity != nil {
            configure(modelContainer: modelContainer)
        } else {
            initError = initError ?? "Identity not available after onboarding"
        }

        return isReady
    }

    /// Reset to onboarding state (e.g. after a failed setup, user wants to restart).
    func resetToOnboarding() {
        teardownRuntimeState()
        authTokenManager.clearToken()
        isReady = false
        identity = nil
        localPeerID = nil
        initError = nil
        needsOnboarding = true
    }

    @discardableResult
    func signOut() -> Bool {
        guard let container = modelContainer else {
            logger.error("Failed to sign out: model container unavailable")
            initError = "Failed to sign out cleanly because the local data store is unavailable."
            return false
        }

        do {
            try keyManager.deleteIdentity()
            try authTokenManager.clear()
        } catch {
            logger.error("Failed to delete identity during sign out: \(error.localizedDescription)")
            initError = "Failed to clear your local identity: \(error.localizedDescription)"
            return false
        }

        teardownRuntimeState()
        clearLocalStore(in: container)

        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        resetToOnboarding()
        return true
    }

    // MARK: - Peer Persistence

    /// Observe BLE peer state changes and sync to in-memory PeerStore.
    private func setupPeerPersistence(bleService: BLEService) {
        // Sync on every connect/disconnect notification
        peerStateObservation = NotificationCenter.default.addObserver(
            forName: .meshPeerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncMeshPeers()
            }
        }

        schedulePeerSyncTimer(forConnectedPeerCount: bleService.connectedPeers.count)
    }

    /// Keep RSSI refreshes frequent when peers are connected, but make the idle path cheap.
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
            bleActive: bleService?.state == .running,
            wsConnected: webSocketTransport?.state == .running
        )
    }

    private func postTransportStateIfNeeded(_ snapshot: TransportStateSnapshot) {
        guard snapshot != lastPostedTransportState else { return }

        NotificationCenter.default.post(
            name: .meshTransportStateChanged,
            object: nil,
            userInfo: [
                "bleActive": snapshot.bleActive,
                "wsConnected": snapshot.wsConnected,
            ]
        )
        lastPostedTransportState = snapshot
    }

    /// Sync connected BLE peers into the in-memory PeerStore.
    private func syncMeshPeers() {
        guard let bleService else { return }

        let connectedPeerIDs = bleService.connectedPeers
        let localID = localPeerID

        let connectedSet = Set(connectedPeerIDs.map(\.bytes))
        let transportState = currentTransportStateSnapshot()
        let peerSetChanged = connectedSet != lastSyncedPeerIDs

        schedulePeerSyncTimer(forConnectedPeerCount: connectedPeerIDs.count)

        guard !connectedPeerIDs.isEmpty || peerSetChanged else {
            postTransportStateIfNeeded(transportState)
            return
        }

        // Upsert connected peers
        for peerID in connectedPeerIDs {
            if let localID, peerID == localID { continue }

            let peerData = peerID.bytes
            let existingPeer = peerStore.peer(for: peerData)
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
            peerStore.upsert(peer: info)
        }

        // Mark disconnected peers immediately — no delay
        peerStore.markDisconnectedExcept(activePeerIDs: connectedSet)

        // Prune stale disconnected peers (>5 min)
        peerStore.pruneStale(olderThan: 300)

        postTransportStateIfNeeded(transportState)
        lastSyncedPeerIDs = connectedSet

        if !connectedPeerIDs.isEmpty {
            DebugLogger.shared.log("SYNC", "Peer sync: \(connectedPeerIDs.count) connected")
        }
    }

    // MARK: - Server Registration Self-Check

    /// Verify that the local user exists on the auth server.
    /// If not found (404), re-register with retry to fix silent registration failures.
    private func verifyServerRegistration(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let syncService = UserSyncService()

        do {
            let users = try context.fetch(FetchDescriptor<User>())
            guard let localUser = users.min(by: { $0.createdAt < $1.createdAt }) else {
                logger.info("SELF_CHECK — no local user, skipping")
                DebugLogger.shared.log("SELF_CHECK", "No local user found, skipping")
                return
            }

            let result = try await syncService.lookupUser(username: localUser.username)

            if result != nil {
                logger.info("SELF_CHECK PASS — \(localUser.username, privacy: .private) found on server")
                DebugLogger.shared.log("SELF_CHECK", "PASS — \(DebugLogger.redact(localUser.username)) found on server")
            } else {
                logger.warning("SELF_CHECK FAIL — \(localUser.username, privacy: .private) not registered, re-registering")
                DebugLogger.shared.log("SELF_CHECK", "FAIL — not registered, re-registering", isError: true)

                await syncService.registerUserWithRetry(
                    emailHash: localUser.emailHash,
                    username: localUser.username,
                    noisePublicKey: localUser.noisePublicKey,
                    signingPublicKey: localUser.signingPublicKey
                )
            }

            await establishAuthSession(forceRefresh: true)
        } catch {
            logger.error("SELF_CHECK error: \(error.localizedDescription)")
            DebugLogger.shared.log("SELF_CHECK", "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Lifecycle

    /// Start BLE scanning and WebSocket connection.
    func start() {
        announceTimer?.invalidate() // Prevent timer stacking if start() called twice
        guard isReady else {
            logger.warning("start() called before coordinator is ready")
            return
        }
        transportCoordinator?.start()
        DebugLogger.shared.log("LIFECYCLE", "TransportCoordinator started")

        locationService.requestAuthorization()
        locationService.startUpdating(accuracy: .geohash)
        DebugLogger.shared.log("LIFECYCLE", "LocationService started (geohash accuracy)")

        // Start message retry queue processor
        messageRetryService?.start()
        DebugLogger.shared.log("LIFECYCLE", "MessageRetryService started")

        Task { @MainActor in
            // Request notification permissions
            let notifGranted = await notificationService.requestAuthorization()
            DebugLogger.shared.log("LIFECYCLE", "NotificationService authorization: \(notifGranted ? "granted" : "denied")")

            await profileViewModel?.loadProfile()

            // Set Sentry user context after profile loads
            if let user = profileViewModel?.currentUser {
                CrashReportingService.shared.setUser(
                    id: user.id.uuidString,
                    username: user.username
                )
            }

            await chatViewModel?.loadChannels()
            meshViewModel?.startMonitoring()
            locationViewModel?.startMonitoring()
            await eventsViewModel?.loadEvents()
            await eventsViewModel?.startGeofencing()
            await storeViewModel?.start()
            DebugLogger.shared.log("LIFECYCLE", "StoreViewModel started (products + transaction listener)")
            await sosViewModel?.loadResponderStatus()
            await sosViewModel?.refreshVisibleAlerts()
        }

        // Broadcast presence after a short delay to let connections establish
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            do {
                try await messageService?.broadcastPresence()
            } catch {
                DebugLogger.shared.log("PRESENCE", "Failed to broadcast presence: \(error.localizedDescription)", isError: true)
            }
        }

        // Re-broadcast presence every 30s so late-joining peers see our username
        let aTimer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await self?.messageService?.broadcastPresence()
                } catch {
                    DebugLogger.emit("PRESENCE", "Failed to re-broadcast presence: \(error.localizedDescription)", isError: true)
                }
            }
        }
        RunLoop.main.add(aTimer, forMode: .common)
        announceTimer = aTimer

        // Prune peers not seen in 2 minutes (separate from announce staleness)
        let pruneTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.peerStore.pruneStale(olderThan: 120)
            }
        }
        RunLoop.main.add(pruneTimer, forMode: .common)
        peerPruneTimer = pruneTimer

        messageCleanupService?.start()

        logger.info("Transports started")
    }

    /// Stop all transports and clean up.
    func stop() {
        transportCoordinator?.stop()
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
        messageCleanupService?.stop()
        logger.info("Transports stopped")
    }

    private func teardownRuntimeState() {
        stop()
        peerStore.removeAllSynchronously()

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

        powerTierCancellable?.cancel()
        powerTierCancellable = nil
        powerManager?.stopMonitoring()
        powerManager = nil
        messageService?.delegate = nil
        messageRetryService?.stop()
        meshViewModel?.stopMonitoring()
        locationViewModel?.stopMonitoring()
        bleService = nil
        webSocketTransport = nil
        transportCoordinator = nil
        meshRelayService = nil
        messageService = nil
        messageRetryService = nil
        chatViewModel = nil
        meshViewModel = nil
        locationViewModel = nil
        friendFinderViewModel = nil
        eventsViewModel = nil
        profileViewModel = nil
        storeViewModel = nil
        sosViewModel = nil
        locationService.stopUpdating()
        locationService.stopMonitoringAllEvents()
        locationService.delegate = nil
    }

    private func establishAuthSession(forceRefresh: Bool = false) async {
        do {
            if forceRefresh {
                if authTokenManager.currentToken == nil {
                    _ = try await authTokenManager.validToken()
                } else {
                    try await authTokenManager.refreshIfNeeded(force: true)
                }
            } else {
                _ = try await authTokenManager.validToken()
            }

            DebugLogger.shared.log("AUTH", "JWT session ready")
            scheduleAuthRefreshTimer()
        } catch {
            DebugLogger.shared.log("AUTH", "JWT session bootstrap failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func scheduleAuthRefreshTimer() {
        authRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.authTokenManager.refreshIfNeeded()
                } catch {
                    DebugLogger.shared.log("AUTH", "Scheduled JWT refresh failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        authRefreshTimer = timer
    }

    private func ensureUserPreferencesExists(in modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)

        do {
            let existingPreferences = try context.fetch(FetchDescriptor<UserPreferences>())
            guard existingPreferences.isEmpty else { return }

            context.insert(defaultPreferencesFromLegacyDefaults())
            try context.save()
        } catch {
            logger.error("Failed to ensure preferences exist: \(error.localizedDescription)")
        }
    }

    private func defaultPreferencesFromLegacyDefaults() -> UserPreferences {
        let defaults = UserDefaults.standard
        let theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? AppTheme.system.rawValue) ?? .system
        let locationPrecision = LocationPrecision(
            rawValue: defaults.string(forKey: "locationPrecision") ?? LocationPrecision.fuzzy.rawValue
        ) ?? .fuzzy
        let pttMode = PTTMode(rawValue: defaults.string(forKey: "pttMode") ?? PTTMode.holdToTalk.rawValue) ?? .holdToTalk

        return UserPreferences(
            theme: theme,
            defaultLocationSharing: locationPrecision,
            proximityAlertsEnabled: defaults.object(forKey: "proximityAlerts") as? Bool ?? true,
            breadcrumbsEnabled: defaults.object(forKey: "breadcrumbTrails") as? Bool ?? false,
            notificationsEnabled: defaults.object(forKey: "pushNotifications") as? Bool ?? true,
            pttMode: pttMode,
            autoJoinNearbyChannels: defaults.object(forKey: "autoJoinChannels") as? Bool ?? true,
            crowdPulseVisible: defaults.object(forKey: "crowdPulse") as? Bool ?? true,
            nearbyVisibilityEnabled: defaults.object(forKey: "nearbyVisibilityEnabled") as? Bool ?? false
        )
    }

    private func clearLocalStore(in modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)

        do {
            try deleteAll(Attachment.self, in: context)
            try deleteAll(MessageQueue.self, in: context)
            try deleteAll(GroupMembership.self, in: context)
            try deleteAll(GroupSenderKey.self, in: context)
            try deleteAll(NoiseSessionModel.self, in: context)
            try deleteAll(Message.self, in: context)
            try deleteAll(Channel.self, in: context)
            try deleteAll(FriendLocation.self, in: context)
            try deleteAll(MedicalResponder.self, in: context)
            try deleteAll(SOSAlert.self, in: context)
            try deleteAll(Friend.self, in: context)
            try deleteAll(MeetingPoint.self, in: context)
            try deleteAll(CrowdPulse.self, in: context)
            try deleteAll(SetTime.self, in: context)
            try deleteAll(Stage.self, in: context)
            try deleteAll(Event.self, in: context)
            try deleteAll(BreadcrumbPoint.self, in: context)
            try deleteAll(UserPreferences.self, in: context)
            try deleteAll(User.self, in: context)
            try context.save()
        } catch {
            logger.error("Failed to erase local store during sign out: \(error.localizedDescription)")
        }
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        let models = try context.fetch(FetchDescriptor<T>())
        for model in models {
            context.delete(model)
        }
    }
}

extension AppCoordinator: LocationServiceDelegate {
    nonisolated func locationService(_ service: LocationService, didUpdateLocation location: CLLocation) {}

    nonisolated func locationService(_ service: LocationService, didUpdateGeohash geohash: String) {}

    nonisolated func locationService(_ service: LocationService, didEnterEventRegion eventID: UUID) {
        Task { @MainActor [weak self] in
            guard let eventsViewModel = self?.eventsViewModel else { return }
            await eventsViewModel.handleEventEntry(eventID: eventID)
        }
    }

    nonisolated func locationService(_ service: LocationService, didExitEventRegion eventID: UUID) {
        Task { @MainActor [weak self] in
            self?.eventsViewModel?.handleEventExit(eventID: eventID)
        }
    }

    nonisolated func locationService(_ service: LocationService, didChangeAuthorization status: CLAuthorizationStatus) {
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        service.startUpdating(accuracy: .geohash)

        Task { @MainActor [weak self] in
            guard let eventsViewModel = self?.eventsViewModel else { return }
            await eventsViewModel.startGeofencing()
        }
    }

    nonisolated func locationService(_ service: LocationService, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("Location service error: \(error.localizedDescription)")
        }
    }
}
