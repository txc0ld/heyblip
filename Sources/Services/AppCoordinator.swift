import Foundation
import CoreLocation
import SwiftData
import BlipProtocol
import BlipMesh
import BlipCrypto
import os.log
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

/// Destination for notification-initiated navigation.
enum NotificationDestination: Equatable {
    case conversation(channelID: UUID)
    case friendRequest(friendID: UUID)
    case sosAlert(alertID: UUID)
}

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

    /// Whether the local user has not yet been confirmed on the server.
    /// Set to `true` when registration or self-check fails; cleared when
    /// a successful verification or retry succeeds.
    private(set) var registrationSyncPending = false

    /// Navigation target set by notification taps — views observe this to route.
    var pendingNotificationNavigation: NotificationDestination?

    /// Set by immersive screens (chat conversation, full-screen media, SOS) to
    /// tell the root `MainTabView` to hide the floating tab bar. Without this
    /// the glass tab bar draws on top of pushed destinations and sits visibly
    /// "halfway in the screen" over chat content.
    var isInImmersiveView: Bool = false

    // MARK: - Services

    private(set) var runtime: AppRuntime?
    private(set) var peerStore = PeerStore.shared
    private(set) var locationService = LocationService()
    private(set) var notificationService = NotificationService()
    private(set) var backgroundTaskService: BackgroundTaskService?
    private(set) var authTokenManager = AuthTokenManager.shared

    var bleService: BLEService? { runtime?.bleService }
    var webSocketTransport: WebSocketTransport? { runtime?.webSocketTransport }
    var transportCoordinator: TransportCoordinator? { runtime?.transportCoordinator }
    var meshRelayService: MeshRelayService? { runtime?.meshRelayService }
    var messageService: MessageService? { runtime?.messageService }
    var messageRetryService: MessageRetryService? { runtime?.messageRetryService }
    var proximityAlertService: ProximityAlertService? { runtime?.proximityAlertService }

    // MARK: - Feature View Models

    var chatViewModel: ChatViewModel? { runtime?.chatViewModel }
    var meshViewModel: MeshViewModel? { runtime?.meshViewModel }
    var locationViewModel: LocationViewModel? { runtime?.locationViewModel }
    var friendFinderViewModel: FriendFinderViewModel? { runtime?.friendFinderViewModel }
    var eventsViewModel: EventsViewModel? { runtime?.eventsViewModel }
    var profileViewModel: ProfileViewModel? { runtime?.profileViewModel }
    var storeViewModel: StoreViewModel? { runtime?.storeViewModel }
    var sosViewModel: SOSViewModel? { runtime?.sosViewModel }
    var pttViewModel: PTTViewModel? { runtime?.pttViewModel }
    var powerManager: PowerManager? { runtime?.powerManager }
    var messageCleanupService: MessageCleanupService? { runtime?.messageCleanupService }

    // MARK: - Identity

    private(set) var identity: Identity?
    private(set) var localPeerID: PeerID?

    // MARK: - Dependencies

    private let keyManager: KeyManager
    private let logger = Logger(subsystem: "com.blip", category: "AppCoordinator")
    private var modelContainer: ModelContainer?
    private var lifecycleController: AppLifecycleController?
    private var registrationRecoveryService: RegistrationRecoveryService?
    private var notificationRouter: NotificationActionRouter?
    @ObservationIgnored nonisolated(unsafe) private var transportDelegateBridge: (any TransportDelegate)?

    // MARK: - Init

    init(keyManager: KeyManager = .shared) {
        self.keyManager = keyManager

        // Configure Sentry crash reporting early, before any other setup
        if let dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String, !dsn.isEmpty, !dsn.hasPrefix("$(") {
            CrashReportingService.shared.configure(dsn: dsn)
        }

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
        notificationService.delegate = self

        let runtime = AppRuntimeFactory().makeRuntime(
            modelContainer: modelContainer,
            identity: identity,
            dependencies: .init(
                keyManager: keyManager,
                peerStore: peerStore,
                locationService: locationService,
                notificationService: notificationService,
                authTokenManager: authTokenManager
            )
        )
        self.runtime = runtime
        self.lifecycleController = AppLifecycleController(runtime: runtime)
        self.registrationRecoveryService = RegistrationRecoveryService(
            modelContainer: modelContainer,
            keyManager: keyManager,
            refreshAuthSession: { [weak self] forceRefresh in
                await self?.establishAuthSession(forceRefresh: forceRefresh)
            }
        )
        self.notificationRouter = NotificationActionRouter(
            modelContainer: modelContainer,
            runtime: runtime
        )

        // Notify app layer when a transport-level send fails so MessageRetryService
        // can pick up persisted messages. The message is already enqueued in SwiftData
        // by MessageService; this callback triggers an immediate retry scan.
        let retryService = runtime.messageRetryService
        runtime.transportCoordinator.onSendFailed = { data, targetPeer in
            let peerHex = targetPeer?.bytes.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "broadcast"
            DebugLogger.emit("TX", "Transport send failed (\(data.count)B → \(peerHex)) — queued for retry")
            Task { @MainActor in
                await retryService.triggerScan()
            }
        }
        runtime.transportCoordinator.delegate = self
        transportDelegateBridge = runtime.meshRelayService

        // Bridge BLE peer discovery to in-memory PeerStore.
        self.modelContainer = modelContainer

        // Clean up duplicate DM channels from prior builds with PeerID instability.
        do {
            let cleanupContext = ModelContext(modelContainer)
            let removed = try DuplicateChannelCleaner.cleanDuplicateDMChannels(context: cleanupContext)
            if removed > 0 {
                DebugLogger.shared.log("APP", "Cleaned \(removed) duplicate DM channels from prior builds")
            }
        } catch {
            DebugLogger.shared.log("APP", "Duplicate channel cleanup failed: \(error)", isError: true)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.establishAuthSession()
        }

        Task { [weak registrationRecoveryService] in
            await registrationRecoveryService?.resyncKeysIfNeeded()
        }

        // Wire background task service for BGTaskScheduler-based mesh sync.
        let bgService = BackgroundTaskService(coordinator: self)
        bgService.scheduleNextSync()
        self.backgroundTaskService = bgService

        isReady = true
        logger.info("AppCoordinator configured — services ready")

        // Self-check: verify local user is registered on the server.
        // Catches users who slipped through all registration retries.
        Task { @MainActor [weak self, weak registrationRecoveryService] in
            guard let self, let registrationRecoveryService else { return }
            self.registrationSyncPending = await registrationRecoveryService.verifyServerRegistration()
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

        Task { await PushTokenManager.shared.clearToken() }
        teardownRuntimeState()
        guard clearLocalStore(in: container) else {
            initError = "Failed to erase local data from this device."
            return false
        }

        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        resetToOnboarding()
        return true
    }

    // MARK: - Server Registration Self-Check

    /// Verify that the local user exists on the auth server.
    /// If not found (404), re-register with retry to fix silent registration failures.
    /// Retry server registration from the UI (e.g. the sync-pending banner).
    func retryRegistration() async {
        guard let registrationRecoveryService else { return }
        registrationSyncPending = await registrationRecoveryService.retryRegistration()
    }

    // MARK: - Lifecycle

    /// Start BLE scanning and WebSocket connection.
    func start() {
        guard isReady else {
            logger.warning("start() called before coordinator is ready")
            return
        }
        lifecycleController?.start()
    }

    /// Stop all transports and clean up.
    func stop() {
        lifecycleController?.stop()
    }

    private func teardownRuntimeState() {
        lifecycleController?.tearDown()
        lifecycleController = nil
        registrationRecoveryService = nil
        notificationRouter = nil
        peerStore.removeAllSynchronously()

        runtime?.powerManager.stopMonitoring()
        transportDelegateBridge = nil
        runtime?.messageService.delegate = nil
        runtime?.messageRetryService.stop()
        runtime?.meshViewModel.stopMonitoring()
        runtime?.locationViewModel.stopMonitoring()
        runtime?.pttViewModel.reset()
        locationService.stopUpdating()
        locationService.stopMonitoringAllEvents()
        locationService.delegate = nil
        runtime = nil
    }

    private func establishAuthSession(forceRefresh: Bool = false) async {
        await lifecycleController?.establishAuthSession(forceRefresh: forceRefresh)
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

    private func clearLocalStore(in modelContainer: ModelContainer) -> Bool {
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
            try deleteAll(JoinedEvent.self, in: context)
            try deleteAll(BreadcrumbPoint.self, in: context)
            try deleteAll(UserPreferences.self, in: context)
            try deleteAll(User.self, in: context)
            try context.save()
            return true
        } catch {
            logger.error("Failed to erase local store during sign out: \(error.localizedDescription)")
            return false
        }
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        let models = try context.fetch(FetchDescriptor<T>())
        for model in models {
            context.delete(model)
        }
    }
}

extension Notification.Name {
    static let didFailMessageDelivery = Notification.Name("com.blip.didFailMessageDelivery")
}

extension AppCoordinator: TransportDelegate {
    nonisolated func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID) {
        transportDelegateBridge?.transport(transport, didReceiveData: data, from: peerID)
    }

    nonisolated func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        transportDelegateBridge?.transport(transport, didConnect: peerID)
    }

    nonisolated func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        transportDelegateBridge?.transport(transport, didDisconnect: peerID)
    }

    nonisolated func transport(_ transport: any Transport, didChangeState state: TransportState) {
        transportDelegateBridge?.transport(transport, didChangeState: state)
    }

    nonisolated func transport(_ transport: any Transport, didFailDelivery data: Data, to peerID: PeerID?) {
        var userInfo: [AnyHashable: Any] = ["data": data]
        if let peerID {
            userInfo["peerID"] = peerID.bytes
        }
        NotificationCenter.default.post(name: .didFailMessageDelivery, object: nil, userInfo: userInfo)
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

// MARK: - NotificationServiceDelegate

extension AppCoordinator: NotificationServiceDelegate {
    nonisolated func notificationService(_ service: NotificationService, didReceiveAction action: BlipNotificationAction, with userInfo: [String: Any]) {
        let payload = userInfo.compactMapValues { $0 as? String }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingNotificationNavigation = await self.notificationRouter?.handleAction(action, userInfo: payload)
                ?? self.pendingNotificationNavigation
        }
    }

    nonisolated func notificationService(_ service: NotificationService, didReceiveReplyText text: String, with userInfo: [String: Any]) {
        let payload = userInfo.compactMapValues { $0 as? String }
        Task { @MainActor [weak self] in
            await self?.notificationRouter?.handleReply(text: text, userInfo: payload)
        }
    }

    /// Open (or create) a DM thread with the user behind `username` and route the UI to
    /// the Chats tab so the conversation is on screen. This is the navigation primitive
    /// surfaces like the Nearby tab use to deliver "tap on a friend, land in their DM"
    /// without needing direct access to ChatViewModel internals.
    func openDM(withUsername username: String) async {
        guard let destination = await notificationRouter?.openDM(withUsername: username) else { return }
        pendingNotificationNavigation = destination
    }
}
