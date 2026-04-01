import Foundation
import CoreLocation
import SwiftData
import BlipProtocol
import BlipMesh
import BlipCrypto
import os.log

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
    private(set) var peerStore = PeerStore.shared
    private(set) var locationService = LocationService()
    private(set) var notificationService = NotificationService()

    // MARK: - Feature View Models

    private(set) var chatViewModel: ChatViewModel?
    private(set) var meshViewModel: MeshViewModel?
    private(set) var locationViewModel: LocationViewModel?
    private(set) var friendFinderViewModel: FriendFinderViewModel?
    private(set) var festivalViewModel: FestivalViewModel?
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
    nonisolated(unsafe) private var broadcastObservation: NSObjectProtocol?
    nonisolated(unsafe) private var peerStateObservation: NSObjectProtocol?
    nonisolated(unsafe) private var peerSyncTimer: Timer?
    nonisolated(unsafe) private var announceTimer: Timer?
    nonisolated(unsafe) private var peerPruneTimer: Timer?

    // MARK: - Init

    init(keyManager: KeyManager = .shared) {
        self.keyManager = keyManager
        loadIdentityAndConfigure()
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
            noisePublicKey: identity.noisePublicKey.rawRepresentation
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
        self.festivalViewModel = FestivalViewModel(
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

        isReady = true
        logger.info("AppCoordinator configured — services ready")
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

        // Also run a periodic sync every 5 seconds to catch RSSI drift and stale peers
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncMeshPeers()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peerSyncTimer = timer
    }

    /// Sync connected BLE peers into the in-memory PeerStore.
    private func syncMeshPeers() {
        guard let bleService else { return }

        let connectedPeerIDs = bleService.connectedPeers
        let localID = localPeerID

        let connectedSet = Set(connectedPeerIDs.map(\.bytes))

        // Upsert connected peers
        for peerID in connectedPeerIDs {
            if let localID, peerID == localID { continue }

            let peerData = peerID.bytes
            let info = PeerInfo(
                peerID: peerData,
                noisePublicKey: peerStore.peer(for: peerData)?.noisePublicKey ?? peerData,
                signingPublicKey: peerStore.peer(for: peerData)?.signingPublicKey ?? Data(),
                username: peerStore.peer(for: peerData)?.username,
                rssi: bleService.rssi(for: peerID) ?? -80,
                isConnected: true,
                lastSeenAt: Date(),
                hopCount: 1
            )
            peerStore.upsert(peer: info)
        }

        // Mark disconnected peers immediately — no delay
        peerStore.markDisconnectedExcept(activePeerIDs: connectedSet)

        // Prune stale disconnected peers (>5 min)
        peerStore.pruneStale(olderThan: 300)

        // Post transport state
        NotificationCenter.default.post(
            name: .meshTransportStateChanged,
            object: nil,
            userInfo: [
                "bleActive": bleService.state == .running,
                "wsConnected": self.webSocketTransport?.state == .running,
            ]
        )

        DebugLogger.shared.log("SYNC", "Peer sync: \(connectedPeerIDs.count) connected")
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
        locationService.requestAuthorization()

        Task { @MainActor in
            await profileViewModel?.loadProfile()
            await chatViewModel?.loadChannels()
            meshViewModel?.startMonitoring()
            locationViewModel?.startMonitoring()
            await festivalViewModel?.loadFestivals()
            await festivalViewModel?.startGeofencing()
            await storeViewModel?.refreshBalance()
            await sosViewModel?.loadResponderStatus()
            await sosViewModel?.refreshVisibleAlerts()
        }

        // Broadcast presence after a short delay to let connections establish
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            try? await messageService?.broadcastPresence()
        }

        // Re-broadcast presence every 30s so late-joining peers see our username
        let aTimer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? await self?.messageService?.broadcastPresence()
            }
        }
        RunLoop.main.add(aTimer, forMode: .common)
        announceTimer = aTimer

        // Prune peers not seen in 2 minutes (separate from announce staleness)
        let pruneTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.peerStore.pruneStale(olderThan: 120)
        }
        RunLoop.main.add(pruneTimer, forMode: .common)
        peerPruneTimer = pruneTimer

        logger.info("Transports started")
    }

    /// Stop all transports and clean up.
    func stop() {
        transportCoordinator?.stop()
        peerSyncTimer?.invalidate()
        peerSyncTimer = nil
        announceTimer?.invalidate()
        announceTimer = nil
        peerPruneTimer?.invalidate()
        peerPruneTimer = nil
        logger.info("Transports stopped")
    }

    private func teardownRuntimeState() {
        stop()
        peerStore.removeAll()

        if let observation = broadcastObservation {
            NotificationCenter.default.removeObserver(observation)
            broadcastObservation = nil
        }

        if let observation = peerStateObservation {
            NotificationCenter.default.removeObserver(observation)
            peerStateObservation = nil
        }

        messageService?.delegate = nil
        meshViewModel?.stopMonitoring()
        locationViewModel?.stopMonitoring()
        bleService = nil
        webSocketTransport = nil
        transportCoordinator = nil
        meshRelayService = nil
        messageService = nil
        chatViewModel = nil
        meshViewModel = nil
        locationViewModel = nil
        friendFinderViewModel = nil
        festivalViewModel = nil
        profileViewModel = nil
        storeViewModel = nil
        sosViewModel = nil
        locationService.stopUpdating()
        locationService.stopMonitoringAllFestivals()
        locationService.delegate = nil
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
            try deleteAll(Festival.self, in: context)
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

    nonisolated func locationService(_ service: LocationService, didEnterFestivalRegion festivalID: UUID) {
        Task { @MainActor [weak self] in
            guard let festivalViewModel = self?.festivalViewModel else { return }
            await festivalViewModel.handleFestivalEntry(festivalID: festivalID)
        }
    }

    nonisolated func locationService(_ service: LocationService, didExitFestivalRegion festivalID: UUID) {
        Task { @MainActor [weak self] in
            self?.festivalViewModel?.handleFestivalExit(festivalID: festivalID)
        }
    }

    nonisolated func locationService(_ service: LocationService, didChangeAuthorization status: CLAuthorizationStatus) {
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        service.startUpdating(accuracy: .geohash)

        Task { @MainActor [weak self] in
            guard let festivalViewModel = self?.festivalViewModel else { return }
            await festivalViewModel.startGeofencing()
        }
    }

    nonisolated func locationService(_ service: LocationService, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("Location service error: \(error.localizedDescription)")
        }
    }
}
