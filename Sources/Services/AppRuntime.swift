import Combine
import SwiftData
import BlipMesh
import BlipCrypto

/// Fully assembled app runtime graph for one authenticated local identity.
///
/// `AppCoordinator` owns the lifecycle and observable state, while `AppRuntime`
/// owns the instantiated service graph that powers the running app.
@MainActor
final class AppRuntime {
    let modelContainer: ModelContainer
    let identity: Identity
    let peerStore: PeerStore
    let locationService: LocationService
    let notificationService: NotificationService
    let authTokenManager: AuthTokenManager

    let bleService: BLEService
    let webSocketTransport: WebSocketTransport
    let transportCoordinator: TransportCoordinator
    let meshRelayService: MeshRelayService
    let messageService: MessageService
    let messageRetryService: MessageRetryService
    let messageCleanupService: MessageCleanupService
    let proximityAlertService: ProximityAlertService
    let powerManager: PowerManager
    let powerTierCancellable: AnyCancellable

    let chatViewModel: ChatViewModel
    let meshViewModel: MeshViewModel
    let locationViewModel: LocationViewModel
    let friendFinderViewModel: FriendFinderViewModel
    let eventsViewModel: EventsViewModel
    let profileViewModel: ProfileViewModel
    let storeViewModel: StoreViewModel
    let sosViewModel: SOSViewModel
    let pttViewModel: PTTViewModel
    let pttAudioService: AudioService

    init(
        modelContainer: ModelContainer,
        identity: Identity,
        peerStore: PeerStore,
        locationService: LocationService,
        notificationService: NotificationService,
        authTokenManager: AuthTokenManager,
        bleService: BLEService,
        webSocketTransport: WebSocketTransport,
        transportCoordinator: TransportCoordinator,
        meshRelayService: MeshRelayService,
        messageService: MessageService,
        messageRetryService: MessageRetryService,
        messageCleanupService: MessageCleanupService,
        proximityAlertService: ProximityAlertService,
        powerManager: PowerManager,
        powerTierCancellable: AnyCancellable,
        chatViewModel: ChatViewModel,
        meshViewModel: MeshViewModel,
        locationViewModel: LocationViewModel,
        friendFinderViewModel: FriendFinderViewModel,
        eventsViewModel: EventsViewModel,
        profileViewModel: ProfileViewModel,
        storeViewModel: StoreViewModel,
        sosViewModel: SOSViewModel,
        pttViewModel: PTTViewModel,
        pttAudioService: AudioService
    ) {
        self.modelContainer = modelContainer
        self.identity = identity
        self.peerStore = peerStore
        self.locationService = locationService
        self.notificationService = notificationService
        self.authTokenManager = authTokenManager
        self.bleService = bleService
        self.webSocketTransport = webSocketTransport
        self.transportCoordinator = transportCoordinator
        self.meshRelayService = meshRelayService
        self.messageService = messageService
        self.messageRetryService = messageRetryService
        self.messageCleanupService = messageCleanupService
        self.proximityAlertService = proximityAlertService
        self.powerManager = powerManager
        self.powerTierCancellable = powerTierCancellable
        self.chatViewModel = chatViewModel
        self.meshViewModel = meshViewModel
        self.locationViewModel = locationViewModel
        self.friendFinderViewModel = friendFinderViewModel
        self.eventsViewModel = eventsViewModel
        self.profileViewModel = profileViewModel
        self.storeViewModel = storeViewModel
        self.sosViewModel = sosViewModel
        self.pttViewModel = pttViewModel
        self.pttAudioService = pttAudioService
    }
}
