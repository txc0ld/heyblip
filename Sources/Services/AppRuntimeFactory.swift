import Combine
import SwiftData
import BlipMesh
import BlipCrypto

/// Builds the runtime service graph for a configured local identity.
@MainActor
struct AppRuntimeFactory {
    struct Dependencies {
        let keyManager: KeyManager
        let peerStore: PeerStore
        let locationService: LocationService
        let notificationService: NotificationService
        let authTokenManager: AuthTokenManager
    }

    func makeRuntime(
        modelContainer: ModelContainer,
        identity: Identity,
        dependencies: Dependencies
    ) -> AppRuntime {
        let peerID = identity.peerID

        let ble = BLEService(localPeerID: peerID)
        ble.transportEventHandler = { category, message in
            Task { @MainActor in
                DebugLogger.shared.log(category, message)
            }
        }

        let ws = WebSocketTransport(
            localPeerID: peerID,
            pinnedCertHashes: ServerConfig.pinnedCertHashes,
            pinnedDomains: ServerConfig.pinnedDomains,
            tokenProvider: { @Sendable in
                do {
                    return try await dependencies.authTokenManager.validToken()
                } catch {
                    // JWT unavailable; fall back to legacy base64 noise key auth.
                    // The relay server accepts both JWT and raw base64(noisePublicKey).
                    guard let identity = try dependencies.keyManager.loadIdentity() else {
                        throw error
                    }
                    await DebugLogger.shared.log(
                        "AUTH",
                        "JWT unavailable, using legacy relay auth: \(error.localizedDescription)",
                        isError: true
                    )
                    return identity.noisePublicKey.rawRepresentation.base64EncodedString()
                }
            },
            tokenRefreshHandler: { @Sendable in
                try await dependencies.authTokenManager.refreshIfNeeded(force: true)
            },
            relayURL: ServerConfig.relayWebSocketURL
        )
        ws.transportEventHandler = { category, message in
            Task { @MainActor in
                DebugLogger.shared.log(category, message)
            }
        }

        let transportCoordinator = TransportCoordinator(
            bleTransport: ble,
            webSocketTransport: ws
        )

        let powerManager = PowerManager()
        powerManager.startMonitoring()
        let powerTierCancellable = powerManager.tierPublisher
            .removeDuplicates()
            .sink { [weak ble] tier in
                ble?.updatePowerTier(tier)
            }

        let messageService = MessageService(
            modelContainer: modelContainer,
            keyManager: dependencies.keyManager,
            peerStore: dependencies.peerStore,
            notificationService: dependencies.notificationService
        )
        messageService.configure(transport: transportCoordinator, identity: identity)

        let meshRelayService = MeshRelayService(transport: transportCoordinator)
        meshRelayService.delegate = messageService

        let messageRetryService = MessageRetryService(
            modelContainer: modelContainer,
            messageService: messageService
        )
        let messageCleanupService = MessageCleanupService(modelContainer: modelContainer)

        let proximityAlertService = ProximityAlertService()
        let pttAudioService = AudioService()

        let chatViewModel = ChatViewModel(
            messageService: messageService,
            notificationService: dependencies.notificationService
        )
        let meshViewModel = MeshViewModel(
            modelContainer: modelContainer,
            peerStore: dependencies.peerStore,
            notificationService: dependencies.notificationService
        )
        let locationViewModel = LocationViewModel(
            modelContainer: modelContainer,
            locationService: dependencies.locationService
        )
        let friendFinderViewModel = FriendFinderViewModel(
            locationService: dependencies.locationService,
            modelContainer: modelContainer,
            proximityAlertService: proximityAlertService
        )
        let eventsViewModel = EventsViewModel(
            modelContainer: modelContainer,
            locationService: dependencies.locationService,
            notificationService: dependencies.notificationService,
            bleService: ble
        )
        let profileViewModel = ProfileViewModel(
            modelContainer: modelContainer,
            keyManager: dependencies.keyManager
        )
        let storeViewModel = StoreViewModel(modelContainer: modelContainer)
        let sosViewModel = SOSViewModel(
            modelContainer: modelContainer,
            bleService: ble,
            locationService: dependencies.locationService,
            messageService: messageService,
            notificationService: dependencies.notificationService
        )
        let pttViewModel = PTTViewModel(
            modelContainer: modelContainer,
            audioService: pttAudioService,
            messageService: messageService
        )

        return AppRuntime(
            modelContainer: modelContainer,
            identity: identity,
            peerStore: dependencies.peerStore,
            locationService: dependencies.locationService,
            notificationService: dependencies.notificationService,
            authTokenManager: dependencies.authTokenManager,
            bleService: ble,
            webSocketTransport: ws,
            transportCoordinator: transportCoordinator,
            meshRelayService: meshRelayService,
            messageService: messageService,
            messageRetryService: messageRetryService,
            messageCleanupService: messageCleanupService,
            proximityAlertService: proximityAlertService,
            powerManager: powerManager,
            powerTierCancellable: powerTierCancellable,
            chatViewModel: chatViewModel,
            meshViewModel: meshViewModel,
            locationViewModel: locationViewModel,
            friendFinderViewModel: friendFinderViewModel,
            eventsViewModel: eventsViewModel,
            profileViewModel: profileViewModel,
            storeViewModel: storeViewModel,
            sosViewModel: sosViewModel,
            pttViewModel: pttViewModel,
            pttAudioService: pttAudioService
        )
    }
}
