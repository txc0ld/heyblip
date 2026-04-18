import UIKit
import CoreBluetooth

// MARK: - AppDelegate

/// Handles BLE state restoration for background operation.
/// When iOS relaunches the app after suspension/termination due to a BLE event,
/// the delegate receives restoration state and rebuilds the peer table.
final class AppDelegate: NSObject, UIApplicationDelegate {

    // MARK: - State restoration keys

    /// Restoration identifier for the BLE central manager.
    static let centralRestorationID = "app.blip.central"

    /// Restoration identifier for the BLE peripheral manager.
    static let peripheralRestorationID = "app.blip.peripheral"

    // MARK: - Restored state

    /// Peripherals restored by iOS after background relaunch.
    private(set) var restoredPeripherals: [CBPeripheral] = []

    /// Central scan services restored by iOS after background relaunch.
    private(set) var restoredScanServices: [CBUUID] = []

    /// Peripheral advertising state restored by iOS after background relaunch.
    private(set) var restoredAdvertisementData: [String: Any] = [:]

    // MARK: - UIApplicationDelegate

    /// Background task service — registered once at launch.
    let backgroundTaskService = BackgroundTaskService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGTaskScheduler handlers before any tasks can fire.
        backgroundTaskService.registerTasks()

        // Check if launched due to BLE event
        if let bleOptions = launchOptions?[.bluetoothCentrals] as? [String] {
            handleCentralRestoration(identifiers: bleOptions)
        }
        if let blePeripherals = launchOptions?[.bluetoothPeripherals] as? [String] {
            handlePeripheralRestoration(identifiers: blePeripherals)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    // MARK: - Remote Notifications

    /// Stored completion handler from the most recent silent push.
    /// AppCoordinator consumes this via `consumePushCompletion()` once transports
    /// are running. A 25-second fallback fires if nobody consumes it in time.
    private var pendingPushCompletion: ((UIBackgroundFetchResult) -> Void)?

    /// Returns and clears the pending push completion handler.
    /// Called by AppCoordinator after it reconnects the relay.
    func consumePushCompletion() -> ((UIBackgroundFetchResult) -> Void)? {
        let handler = pendingPushCompletion
        pendingPushCompletion = nil
        return handler
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushTokenManager.shared.didRegisterToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushTokenManager.shared.didFailToRegister(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Store so AppCoordinator can hold it open while the relay drains.
        // The notification wakes an already-running coordinator; for a killed-app
        // relaunch the coordinator picks up pendingPushCompletion inside start().
        pendingPushCompletion = completionHandler
        NotificationCenter.default.post(name: .remotePushReceived, object: nil, userInfo: userInfo)

        // Safety net: iOS requires the handler within ~30 seconds.
        // AppCoordinator calls it after relay drain; this fires only if it never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, let handler = self.pendingPushCompletion else { return }
            self.pendingPushCompletion = nil
            DebugLogger.emit("PUSH", "Push completion handler timed out — calling fallback")
            handler(.newData)
        }
    }

    // MARK: - BLE State Restoration

    /// Handles central manager state restoration.
    /// Called when iOS relaunches the app after a BLE central event in background.
    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Restore connected/connecting peripherals
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            restoredPeripherals = peripherals
        }

        // Restore scan services
        if let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            restoredScanServices = services
        }

        // Post notification so the mesh layer can rebuild peer table
        NotificationCenter.default.post(
            name: .bleCentralStateRestored,
            object: nil,
            userInfo: [
                "peripherals": restoredPeripherals,
                "scanServices": restoredScanServices
            ]
        )
    }

    /// Handles peripheral manager state restoration.
    /// Called when iOS relaunches the app after a BLE peripheral event in background.
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Restore advertisement data
        if let advertisementData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            restoredAdvertisementData = advertisementData
        }

        // Restore services
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            NotificationCenter.default.post(
                name: .blePeripheralStateRestored,
                object: nil,
                userInfo: [
                    "advertisementData": restoredAdvertisementData,
                    "services": services
                ]
            )
        }
    }

    // MARK: - Private

    private func handleCentralRestoration(identifiers: [String]) {
        guard identifiers.contains(Self.centralRestorationID) else { return }
        // Central manager will be re-created with the same restoration ID
        // by the mesh service layer, triggering willRestoreState
    }

    private func handlePeripheralRestoration(identifiers: [String]) {
        guard identifiers.contains(Self.peripheralRestorationID) else { return }
        // Peripheral manager will be re-created with the same restoration ID
        // by the mesh service layer, triggering willRestoreState
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted when BLE central manager state is restored from background.
    static let bleCentralStateRestored = Notification.Name("Blip.bleCentralStateRestored")

    /// Posted when BLE peripheral manager state is restored from background.
    static let blePeripheralStateRestored = Notification.Name("Blip.blePeripheralStateRestored")

    /// Posted when a remote push notification is received in the foreground or background.
    static let remotePushReceived = Notification.Name("Blip.remotePushReceived")
}
