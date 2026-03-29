import Foundation
@preconcurrency import CoreBluetooth
import BlipProtocol
import os.log

/// Dual-role BLE transport for the Blip mesh network (spec Section 5.2).
///
/// Operates simultaneously as a `CBCentralManager` (scanner/client) and
/// `CBPeripheralManager` (advertiser/server). Supports state restoration
/// for background BLE operation on iOS.
public final class BLEService: NSObject, Transport, @unchecked Sendable {

    // MARK: - Transport conformance

    public weak var delegate: (any TransportDelegate)?

    public private(set) var state: TransportState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.transport(self, didChangeState: state)
        }
    }

    public var connectedPeers: [PeerID] {
        lock.withLock {
            Array(peripheralToPeerID.values)
        }
    }

    // MARK: - Core Bluetooth managers (protocol-typed for testability)

    var centralManager: (any BLECentralManaging)?
    var peripheralManager: (any BLEPeripheralManaging)?

    // MARK: - BLE service & characteristic

    var service: CBMutableService?
    var characteristic: CBMutableCharacteristic?

    // MARK: - Peer tracking

    /// Maps discovered CBPeripheral identifiers to their peer IDs.
    var peripheralToPeerID: [UUID: PeerID] = [:]

    /// Reverse mapping: PeerID -> peripheral proxy for sending.
    var peerIDToPeripheral: [PeerID: any BLEPeripheralProxy] = [:]

    /// Maps peripheral UUID to the writable characteristic discovered on that peripheral.
    var peripheralCharacteristics: [UUID: CBCharacteristic] = [:]

    /// Set of peripheral UUIDs currently being connected to (to avoid duplicates).
    var connectingPeripherals: Set<UUID> = []

    /// Peripherals that recently timed out, with the timestamp of the timeout.
    var timedOutPeripherals: [UUID: Date] = [:]

    /// Centrals subscribed to our characteristic (for notify).
    var subscribedCentrals: [CBCentral] = []

    /// Maps subscribed CBCentral identifiers to peer IDs.
    var centralToPeerID: [UUID: PeerID] = [:]

    /// Strong references to connected peripherals to prevent deallocation.
    var connectedPeripheralRefs: [UUID: any BLEPeripheralProxy] = [:]

    // MARK: - Concurrency

    let lock = NSLock()
    private let queue = DispatchQueue(label: "com.blip.ble", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.blip", category: "BLE")

    // MARK: - Scanning control

    var isScanning = false
    private var scanTimer: DispatchSourceTimer?

    // MARK: - Local peer ID

    /// The local device's PeerID, derived from its Noise public key.
    public let localPeerID: PeerID

    // MARK: - Init

    /// Create a BLE service with the local device's peer ID.
    ///
    /// - Parameter localPeerID: This device's PeerID (derived from Noise public key).
    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
        super.init()
    }

    /// Create a BLE service with injected managers for testing.
    init(
        localPeerID: PeerID,
        centralManager: any BLECentralManaging,
        peripheralManager: any BLEPeripheralManaging
    ) {
        self.localPeerID = localPeerID
        super.init()
        self.centralManager = centralManager
        self.peripheralManager = peripheralManager
    }

    // MARK: - Transport lifecycle

    public func start() {
        guard state == .idle || state == .stopped else { return }
        state = .starting

        // Only create real CB managers if not already injected (test mode).
        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: BLEConstants.centralRestorationID,
                    CBCentralManagerOptionShowPowerAlertKey: true,
                ]
            )
        }

        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: queue,
                options: [
                    CBPeripheralManagerOptionRestoreIdentifierKey: BLEConstants.peripheralRestorationID,
                ]
            )
        }
    }

    public func stop() {
        state = .stopped

        stopScanning()

        if peripheralManager?.bleIsAdvertising == true {
            peripheralManager?.bleStopAdvertising()
        }

        lock.withLock {
            for (_, peripheral) in connectedPeripheralRefs {
                centralManager?.bleCancelConnection(peripheral)
            }
            peripheralToPeerID.removeAll()
            peerIDToPeripheral.removeAll()
            peripheralCharacteristics.removeAll()
            connectingPeripherals.removeAll()
            connectedPeripheralRefs.removeAll()
            subscribedCentrals.removeAll()
            centralToPeerID.removeAll()
        }

        if let service = service {
            peripheralManager?.bleRemoveService(service)
        }
    }

    public func send(data: Data, to peerID: PeerID) throws {
        guard state == .running else {
            throw TransportError.notStarted
        }
        guard data.count <= BLEConstants.effectiveMTU else {
            throw TransportError.payloadTooLarge(size: data.count, max: BLEConstants.effectiveMTU)
        }

        var sent = false

        // Try sending via central connection (write to peripheral's characteristic)
        lock.lock()
        if let peripheral = peerIDToPeripheral[peerID],
           let char = peripheralCharacteristics[peripheral.identifier] {
            lock.unlock()
            peripheral.writeValue(data, for: char, type: .withResponse)
            sent = true
        } else {
            lock.unlock()
        }

        // Try sending via peripheral manager (notify subscribed central)
        if !sent {
            lock.lock()
            let matchingCentral = centralToPeerID.first(where: { $0.value == peerID })?.key
            let central = subscribedCentrals.first(where: { $0.identifier == matchingCentral })
            lock.unlock()

            if let central = central, let char = characteristic {
                _ = peripheralManager?.bleUpdateValue(data, for: char, onSubscribedCentrals: [central])
                sent = true
            }
        }

        if !sent {
            throw TransportError.peerNotConnected(peerID)
        }
    }

    public func broadcast(data: Data) {
        guard state == .running else { return }

        // Notify all subscribed centrals via peripheral manager
        if let char = characteristic, !subscribedCentrals.isEmpty {
            _ = peripheralManager?.bleUpdateValue(data, for: char, onSubscribedCentrals: subscribedCentrals)
        }

        // Write to all connected peripherals via central manager
        lock.lock()
        let peripherals = Array(connectedPeripheralRefs.values)
        let chars = peripheralCharacteristics
        lock.unlock()

        for peripheral in peripherals {
            if let char = chars[peripheral.identifier] {
                peripheral.writeValue(data, for: char, type: .withoutResponse)
            }
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        guard centralManager?.cmState == .poweredOn else { return }
        guard !isScanning else { return }

        isScanning = true
        centralManager?.bleStartScan(
            services: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("BLE scanning started")

        scheduleScanCycle()
    }

    private func stopScanning() {
        isScanning = false
        scanTimer?.cancel()
        scanTimer = nil
        centralManager?.bleStopScan()
    }

    /// Alternate between scanning and pausing to conserve power.
    private func scheduleScanCycle() {
        scanTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + BLEConstants.foregroundScanDuration,
            repeating: .never
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.centralManager?.bleStopScan()
                // Pause, then resume
                let resumeTimer = DispatchSource.makeTimerSource(queue: self.queue)
                resumeTimer.schedule(
                    deadline: .now() + BLEConstants.foregroundScanPause,
                    repeating: .never
                )
                resumeTimer.setEventHandler { [weak self] in
                    guard let self = self, self.isScanning else { return }
                    self.centralManager?.bleStartScan(
                        services: [BLEConstants.serviceUUID],
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                    self.scheduleScanCycle()
                }
                resumeTimer.resume()
                self.scanTimer = resumeTimer
            }
        }
        timer.resume()
        scanTimer = timer
    }

    // MARK: - Advertising

    private func startAdvertising() {
        guard peripheralManager?.pmState == .poweredOn else { return }

        let mutableCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write, .writeWithoutResponse, .notify, .read],
            value: nil,
            permissions: [.writeable, .readable]
        )
        self.characteristic = mutableCharacteristic

        let mutableService = CBMutableService(
            type: BLEConstants.serviceUUID,
            primary: true
        )
        mutableService.characteristics = [mutableCharacteristic]
        self.service = mutableService

        peripheralManager?.bleAddService(mutableService)
    }

    private func beginAdvertising() {
        guard peripheralManager?.pmState == .poweredOn else { return }
        guard peripheralManager?.bleIsAdvertising == false else { return }

        peripheralManager?.bleStartAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Blip",
        ])
        logger.info("BLE advertising started")
    }

    // MARK: - Connection management

    func shouldConnect(toUUID uuid: UUID, rssi: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Already connected or connecting
        if connectedPeripheralRefs[uuid] != nil { return false }
        if connectingPeripherals.contains(uuid) { return false }

        // Recently timed out — backoff
        if let timeoutDate = timedOutPeripherals[uuid],
           Date().timeIntervalSince(timeoutDate) < BLEConstants.reconnectBackoff {
            return false
        }

        // RSSI threshold
        let threshold = connectedPeripheralRefs.isEmpty
            ? BLEConstants.isolatedRSSIThreshold
            : BLEConstants.defaultRSSIThreshold
        if rssi < threshold { return false }

        // Connection count limit
        let currentCount = connectedPeripheralRefs.count
        let maxConnections = BLEConstants.maxCentralConnectionsNormal
        if currentCount >= maxConnections { return false }

        return true
    }

    // MARK: - Internal handlers (testable via @testable import)

    /// Handle central manager state change.
    func handleCentralStateChange(_ newState: CBManagerState) {
        switch newState {
        case .poweredOn:
            logger.info("Central powered on")
            updateRunningState()
            startScanning()
        case .poweredOff:
            logger.warning("Central powered off")
            state = .failed("Bluetooth powered off")
        case .unauthorized:
            logger.error("Central unauthorized")
            state = .failed("Bluetooth unauthorized")
        case .unsupported:
            logger.error("Central unsupported")
            state = .failed("Bluetooth unsupported")
        case .resetting:
            logger.warning("Central resetting")
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Handle peripheral manager state change.
    func handlePeripheralManagerStateChange(_ newState: CBManagerState) {
        switch newState {
        case .poweredOn:
            logger.info("Peripheral manager powered on")
            updateRunningState()
            startAdvertising()
        case .poweredOff:
            logger.warning("Peripheral manager powered off")
        case .unauthorized:
            logger.error("Peripheral manager unauthorized")
        case .unsupported:
            logger.error("Peripheral manager unsupported")
        case .resetting:
            logger.warning("Peripheral manager resetting")
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Handle peripheral discovery.
    func handleDidDiscover(peripheral: any BLEPeripheralProxy, rssi: Int) {
        guard rssi != 127 else { return } // 127 means RSSI unavailable.

        pruneTimedOutPeripherals()

        guard shouldConnect(toUUID: peripheral.identifier, rssi: rssi) else { return }

        lock.withLock {
            connectingPeripherals.insert(peripheral.identifier)
            connectedPeripheralRefs[peripheral.identifier] = peripheral
        }

        logger.info("Connecting to peripheral \(peripheral.identifier), RSSI: \(rssi)")
        (peripheral as? CBPeripheral)?.delegate = self
        centralManager?.bleConnect(peripheral, options: nil)

        // Connection timeout — capture UUID to avoid Sendable issues with protocol existential.
        let peripheralUUID = peripheral.identifier
        queue.asyncAfter(deadline: .now() + BLEConstants.connectionTimeout) { [weak self] in
            guard let self = self else { return }
            let isStillConnecting = self.lock.withLock {
                self.connectingPeripherals.contains(peripheralUUID)
            }
            if isStillConnecting {
                self.logger.warning("Connection timeout for \(peripheralUUID)")
                let peripheralRef = self.lock.withLock { self.connectedPeripheralRefs[peripheralUUID] }
                if let peripheralRef = peripheralRef {
                    self.centralManager?.bleCancelConnection(peripheralRef)
                }
                self.lock.withLock {
                    self.connectingPeripherals.remove(peripheralUUID)
                    self.connectedPeripheralRefs.removeValue(forKey: peripheralUUID)
                    self.timedOutPeripherals[peripheralUUID] = Date()
                }
            }
        }
    }

    /// Handle successful connection.
    func handleDidConnect(peripheral: any BLEPeripheralProxy) {
        logger.info("Connected to peripheral \(peripheral.identifier)")

        lock.withLock {
            connectingPeripherals.remove(peripheral.identifier)
            connectedPeripheralRefs[peripheral.identifier] = peripheral

            let peerID = temporaryPeerID(from: peripheral.identifier)
            peripheralToPeerID[peripheral.identifier] = peerID
            peerIDToPeripheral[peerID] = peripheral
        }

        // Request larger MTU on iOS 16+.
        if #available(iOS 16.0, macOS 13.0, *) {
            (peripheral as? CBPeripheral)?.delegate = self
        }

        peripheral.discoverServices([BLEConstants.serviceUUID])

        guard let peerID = lock.withLock({ peripheralToPeerID[peripheral.identifier] }) else {
            return
        }
        delegate?.transport(self, didConnect: peerID)
        NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)
    }

    /// Handle failed connection.
    func handleDidFailToConnect(peripheralUUID uuid: UUID) {
        logger.error("Failed to connect to \(uuid)")

        lock.withLock {
            connectingPeripherals.remove(uuid)
            connectedPeripheralRefs.removeValue(forKey: uuid)
            timedOutPeripherals[uuid] = Date()
        }
    }

    /// Handle disconnection.
    func handleDidDisconnect(peripheralUUID uuid: UUID) {
        logger.info("Disconnected from \(uuid)")

        let peerID: PeerID? = lock.withLock {
            let pid = peripheralToPeerID.removeValue(forKey: uuid)
            if let pid = pid {
                peerIDToPeripheral.removeValue(forKey: pid)
            }
            peripheralCharacteristics.removeValue(forKey: uuid)
            connectedPeripheralRefs.removeValue(forKey: uuid)
            connectingPeripherals.remove(uuid)
            return pid
        }

        if let peerID = peerID {
            delegate?.transport(self, didDisconnect: peerID)
            NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)
        }
    }

    /// Handle received data from a connected peripheral.
    func handleDidReceiveValue(data: Data, fromPeripheralUUID uuid: UUID) {
        let peerID: PeerID = lock.withLock {
            peripheralToPeerID[uuid] ?? temporaryPeerID(from: uuid)
        }
        delegate?.transport(self, didReceiveData: data, from: peerID)
    }

    // MARK: - Helpers

    /// Derive a temporary PeerID from a peripheral identifier until the real one is exchanged.
    func temporaryPeerID(from uuid: UUID) -> PeerID {
        let data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        return PeerID(noisePublicKey: data)
    }

    /// Clean up stale timed-out entries.
    private func pruneTimedOutPeripherals() {
        let now = Date()
        timedOutPeripherals = timedOutPeripherals.filter { _, date in
            now.timeIntervalSince(date) < BLEConstants.reconnectBackoff
        }
    }

    /// Update the peer ID mapping once the real announcement is received.
    public func updatePeerID(_ peerID: PeerID, forPeripheralUUID uuid: UUID) {
        lock.withLock {
            let oldPeerID = peripheralToPeerID[uuid]
            peripheralToPeerID[uuid] = peerID

            if let peripheral = connectedPeripheralRefs[uuid] {
                if let old = oldPeerID {
                    peerIDToPeripheral.removeValue(forKey: old)
                }
                peerIDToPeripheral[peerID] = peripheral
            }
        }
    }

    /// Update the peer ID mapping for a subscribed central.
    public func updatePeerID(_ peerID: PeerID, forCentralUUID uuid: UUID) {
        lock.withLock {
            centralToPeerID[uuid] = peerID
        }
    }

    private func updateRunningState() {
        if centralManager?.cmState == .poweredOn || peripheralManager?.pmState == .poweredOn {
            if state != .running {
                state = .running
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleCentralStateChange(central.state)
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        logger.info("Central restoring state")

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                peripheral.delegate = self
                lock.withLock {
                    connectedPeripheralRefs[peripheral.identifier] = peripheral
                    let tempID = temporaryPeerID(from: peripheral.identifier)
                    peripheralToPeerID[peripheral.identifier] = tempID
                    peerIDToPeripheral[tempID] = peripheral
                }
                peripheral.discoverServices([BLEConstants.serviceUUID])
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        handleDidDiscover(peripheral: peripheral, rssi: RSSI.intValue)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        handleDidConnect(peripheral: peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        handleDidFailToConnect(peripheralUUID: peripheral.identifier)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handleDidDisconnect(peripheralUUID: peripheral.identifier)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error = error {
            logger.error("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics(
                [BLEConstants.characteristicUUID],
                for: service
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            logger.error("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }
        for char in characteristics where char.uuid == BLEConstants.characteristicUUID {
            lock.withLock {
                peripheralCharacteristics[peripheral.identifier] = char
            }

            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            logger.error("Value update error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        handleDidReceiveValue(data: data, fromPeripheralUUID: peripheral.identifier)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            logger.error("Write error to \(peripheral.identifier): \(error.localizedDescription)")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            logger.error("Notification state error: \(error.localizedDescription)")
        } else {
            logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") on \(peripheral.identifier)")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        // RSSI updates handled by PeerManager.
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEService: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        handlePeripheralManagerStateChange(peripheral.state)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        logger.info("Peripheral manager restoring state")

        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for svc in services {
                self.service = svc
                if let chars = svc.characteristics {
                    for char in chars {
                        if char.uuid == BLEConstants.characteristicUUID,
                           let mutableChar = char as? CBMutableCharacteristic {
                            self.characteristic = mutableChar
                        }
                    }
                }
            }
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error = error {
            logger.error("Failed to add service: \(error.localizedDescription)")
        } else {
            logger.info("Service added, beginning advertising")
            beginAdvertising()
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error = error {
            logger.error("Advertising failed: \(error.localizedDescription)")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        logger.info("Central subscribed: \(central.identifier)")

        let tempPeerID = temporaryPeerID(from: central.identifier)

        lock.withLock {
            if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                subscribedCentrals.append(central)
            }
            centralToPeerID[central.identifier] = tempPeerID
        }

        delegate?.transport(self, didConnect: tempPeerID)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        logger.info("Central unsubscribed: \(central.identifier)")

        let peerID: PeerID? = lock.withLock {
            subscribedCentrals.removeAll { $0.identifier == central.identifier }
            return centralToPeerID.removeValue(forKey: central.identifier)
        }

        if let peerID = peerID {
            delegate?.transport(self, didDisconnect: peerID)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            if let data = request.value, !data.isEmpty {
                let peerID: PeerID = lock.withLock {
                    centralToPeerID[request.central.identifier]
                        ?? temporaryPeerID(from: request.central.identifier)
                }
                delegate?.transport(self, didReceiveData: data, from: peerID)
            }

            peripheral.respond(to: request, withResult: .success)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        request.value = localPeerID.bytes
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        logger.debug("Peripheral manager ready to update subscribers")
    }
}

// MARK: - Mesh Notification Names

public extension Notification.Name {
    /// Posted when a BLE mesh peer connects or disconnects.
    static let meshPeerStateChanged = Notification.Name("com.blip.meshPeerStateChanged")
    /// Posted when transport connectivity state changes.
    static let meshTransportStateChanged = Notification.Name("com.blip.meshTransportStateChanged")
}
