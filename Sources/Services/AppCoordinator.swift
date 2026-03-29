import Foundation
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
    private(set) var messageService: MessageService?

    // MARK: - Identity

    private(set) var identity: Identity?
    private(set) var localPeerID: PeerID?

    // MARK: - Dependencies

    private let keyManager: KeyManager
    private let logger = Logger(subsystem: "com.blip", category: "AppCoordinator")
    nonisolated(unsafe) private var broadcastObservation: NSObjectProtocol?

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

        self.bleService = ble
        self.webSocketTransport = ws
        self.transportCoordinator = coordinator

        // Create and configure MessageService with TransportCoordinator
        // so messages route through the full BLE → WebSocket → local queue chain.
        let msgService = MessageService(modelContainer: modelContainer, keyManager: keyManager)
        msgService.configure(transport: coordinator, identity: identity)
        coordinator.delegate = msgService
        self.messageService = msgService

        // Listen for broadcast requests from ViewModels (e.g. SOSViewModel).
        setupBroadcastForwarding(coordinator: coordinator)

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
        isReady = false
        identity = nil
        localPeerID = nil
        initError = nil
        needsOnboarding = true
    }

    // MARK: - Lifecycle

    /// Start BLE scanning and WebSocket connection.
    func start() {
        guard isReady else {
            logger.warning("start() called before coordinator is ready")
            return
        }
        transportCoordinator?.start()
        logger.info("Transports started")
    }

    /// Stop all transports and clean up.
    func stop() {
        transportCoordinator?.stop()
        logger.info("Transports stopped")
    }
}
