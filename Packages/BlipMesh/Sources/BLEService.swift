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
            Array(peripheralToPeerID.values) + Array(centralToPeerID.values)
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

    /// Latest RSSI reading per connected peripheral UUID.
    var peripheralRSSI: [UUID: Int] = [:]

    /// Consecutive connection failure count per peripheral for exponential backoff.
    private var failureCounts: [UUID: Int] = [:]
    /// Timestamp when a peripheral's backoff period started, for expiry calculation.
    private var backoffUntil: [UUID: Date] = [:]

    /// Dedup CONNECTED callbacks — prevents duplicate events when both central and peripheral
    /// paths fire for the same logical connection.
    private var recentlyConnectedPeers: [PeerID: Date] = [:]
    private static let connectDedupWindow: TimeInterval = 0.5

    /// Tracks when each peer's current connection was established, for backoff reset.
    private var connectionEstablishedAt: [PeerID: Date] = [:]

    // MARK: - Concurrency

    let lock = NSLock()
    private let queue = DispatchQueue(label: "com.blip.ble", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.blip", category: "BLE")

    // MARK: - Scanning control

    var isScanning = false
    private var scanTimer: DispatchSourceTimer?
    private var rssiPollTimer: DispatchSourceTimer?

    // MARK: - Transport Event Callback

    /// Optional callback for surfacing BLE transport events to the app layer (e.g. DebugLogger).
    /// Parameters: (category: String, message: String)
    public var transportEventHandler: ((String, String) -> Void)?

    // MARK: - Authorization

    /// Whether Bluetooth permission has been denied or restricted by the user.
    public private(set) var isBluetoothDenied: Bool = false

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
        guard state == .idle || state == .stopped else {
            transportEventHandler?("BLE", "start() skipped — state is \(state)")
            return
        }

        // Pre-check Bluetooth authorization before creating managers.
        let auth = CBManager.authorization
        switch auth {
        case .denied, .restricted:
            isBluetoothDenied = true
            state = .failed("Bluetooth unauthorized")
            transportEventHandler?("BLE", "start() aborted — Bluetooth authorization: \(auth.rawValue)")
            return
        case .notDetermined, .allowedAlways:
            isBluetoothDenied = false
        @unknown default:
            isBluetoothDenied = false
        }

        state = .starting
        transportEventHandler?("BLE", "start() — creating BLE managers")

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
            transportEventHandler?("BLE", "CBCentralManager created")
        }

        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: queue,
                options: [
                    CBPeripheralManagerOptionRestoreIdentifierKey: BLEConstants.peripheralRestorationID,
                ]
            )
            transportEventHandler?("BLE", "CBPeripheralManager created")
        }
    }

    /// Re-evaluate Bluetooth authorization (e.g. after returning from Settings).
    /// If authorization changed to allowed, initializes BLE managers and starts.
    public func recheckAuthorization() {
        let auth = CBManager.authorization
        switch auth {
        case .denied, .restricted:
            isBluetoothDenied = true
            if state != .failed("Bluetooth unauthorized") {
                state = .failed("Bluetooth unauthorized")
            }
        case .allowedAlways:
            guard isBluetoothDenied else { return }
            isBluetoothDenied = false
            state = .stopped
            start()
        case .notDetermined:
            isBluetoothDenied = false
        @unknown default:
            isBluetoothDenied = false
        }
    }

    public func stop() {
        state = .stopped

        stopScanning()
        rssiPollTimer?.cancel()
        rssiPollTimer = nil

        if peripheralManager?.bleIsAdvertising == true {
            peripheralManager?.bleStopAdvertising()
        }

        let peripheralsToDisconnect: [any BLEPeripheralProxy] = lock.withLock {
            Array(connectedPeripheralRefs.values)
        }
        for peripheral in peripheralsToDisconnect {
            centralManager?.bleCancelConnection(peripheral)
        }
        resetPeerTracking()

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
            transportEventHandler?("BLE", "SEND FAILED: peer not connected \(peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined())")
            throw TransportError.peerNotConnected(peerID)
        } else {
            transportEventHandler?("BLE", "SENT \(data.count)B to \(peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined())")
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
        guard centralManager?.cmState == .poweredOn else {
            transportEventHandler?("BLE", "startScanning() skipped — central not poweredOn")
            return
        }
        guard !isScanning else { return }

        isScanning = true
        centralManager?.bleStartScan(
            services: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("BLE scanning started")
        transportEventHandler?("BLE", "Scan STARTED for service \(BLEConstants.serviceUUID.uuidString)")

        scheduleScanCycle()
        startRSSIPolling()
    }

    /// Returns the last known RSSI for a peer, or nil if unavailable.
    public func rssi(for peerID: PeerID) -> Int? {
        lock.withLock {
            // Try peripheral map first
            if let uuid = peripheralToPeerID.first(where: { $0.value == peerID })?.key {
                return peripheralRSSI[uuid]
            }
            return nil
        }
    }

    /// Returns `true` when the peer is backed by a connected `CBPeripheral` that can provide RSSI.
    public func hasConnectedPeripheral(for peerID: PeerID) -> Bool {
        lock.withLock { peerIDToPeripheral[peerID] != nil }
    }

    /// Poll RSSI for all connected peripherals every 10 seconds.
    private func startRSSIPolling() {
        rssiPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let peripherals: [any BLEPeripheralProxy] = self.lock.withLock {
                Array(self.connectedPeripheralRefs.values)
            }
            for peripheral in peripherals {
                (peripheral as? CBPeripheral)?.readRSSI()
            }
        }
        timer.resume()
        rssiPollTimer = timer
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
        guard peripheralManager?.pmState == .poweredOn else {
            transportEventHandler?("BLE", "startAdvertising() skipped — peripheral manager not poweredOn")
            return
        }

        // If service already exists (e.g. from state restoration), skip straight to advertising
        if service != nil, characteristic != nil {
            transportEventHandler?("BLE", "Service already exists (restored), skipping to beginAdvertising()")
            beginAdvertising()
            return
        }

        transportEventHandler?("BLE", "Creating service and characteristic")
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
        transportEventHandler?("BLE", "Called bleAddService — waiting for didAdd callback")
    }

    private func beginAdvertising() {
        guard peripheralManager?.pmState == .poweredOn else {
            transportEventHandler?("BLE", "beginAdvertising() skipped — peripheral manager not poweredOn")
            return
        }
        guard peripheralManager?.bleIsAdvertising == false else {
            transportEventHandler?("BLE", "beginAdvertising() skipped — already advertising")
            return
        }

        peripheralManager?.bleStartAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Blip",
        ])
        logger.info("BLE advertising started")
        transportEventHandler?("BLE", "Advertising STARTED for service \(BLEConstants.serviceUUID.uuidString)")
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

        // Exponential backoff for repeatedly failing peripherals
        if let until = backoffUntil[uuid], Date() < until {
            return false
        }

        // RSSI threshold
        let threshold = connectedPeripheralRefs.isEmpty
            ? BLEConstants.isolatedRSSIThreshold
            : BLEConstants.defaultRSSIThreshold
        if rssi < threshold { return false }

        // Connection count limit — use actual connected count, not refs (which includes connecting-in-progress)
        let currentCount = peripheralToPeerID.count + centralToPeerID.count
        let maxConnections = BLEConstants.maxCentralConnectionsNormal
        if currentCount >= maxConnections { return false }

        return true
    }

    /// Record a connection failure and compute exponential backoff.
    /// Base delay is `reconnectBackoff` (5s), doubled per failure, capped at `reconnectBackoffMax` (60s).
    /// Must be called while holding `lock`.
    private func recordConnectionFailure(for uuid: UUID) {
        let count = (failureCounts[uuid] ?? 0) + 1
        failureCounts[uuid] = count
        let base = BLEConstants.reconnectBackoff
        let backoffSeconds = min(base * pow(2.0, Double(count - 1)), BLEConstants.reconnectBackoffMax)
        backoffUntil[uuid] = Date().addingTimeInterval(backoffSeconds)
        let shortUUID = uuid.uuidString.prefix(8)
        logger.info("Backoff for \(shortUUID): \(count) failures, next attempt in \(Int(backoffSeconds))s")
        transportEventHandler?("BLE", "BACKOFF \(shortUUID) failures=\(count) wait=\(Int(backoffSeconds))s")
    }

    // MARK: - Internal handlers (testable via @testable import)

    /// Handle central manager state change.
    func handleCentralStateChange(_ newState: CBManagerState) {
        transportEventHandler?("BLE", "Central state → \(newState.debugName) (\(newState.rawValue))")
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
        transportEventHandler?("BLE", "Peripheral mgr state → \(newState.debugName) (\(newState.rawValue))")
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
        guard rssi != 127 else {
            transportEventHandler?("BLE", "Discovered peripheral \(peripheral.identifier) but RSSI unavailable (127), skipping")
            return
        }

        transportEventHandler?("BLE", "Discovered peripheral \(peripheral.identifier.uuidString.prefix(8)), RSSI: \(rssi)")

        // Always store latest RSSI for this peripheral
        lock.withLock { peripheralRSSI[peripheral.identifier] = rssi }

        pruneTimedOutPeripherals()

        guard shouldConnect(toUUID: peripheral.identifier, rssi: rssi) else {
            transportEventHandler?("BLE", "shouldConnect returned false for \(peripheral.identifier.uuidString.prefix(8))")
            return
        }

        lock.withLock {
            connectingPeripherals.insert(peripheral.identifier)
            connectedPeripheralRefs[peripheral.identifier] = peripheral
        }

        logger.info("Connecting to peripheral \(peripheral.identifier), RSSI: \(rssi)")
        transportEventHandler?("BLE", "Connecting to peripheral \(peripheral.identifier.uuidString.prefix(8))")
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
                self.transportEventHandler?("BLE", "CONNECT TIMEOUT \(peripheralUUID.uuidString.prefix(8))")
                let peripheralRef = self.lock.withLock { self.connectedPeripheralRefs[peripheralUUID] }
                if let peripheralRef = peripheralRef {
                    self.centralManager?.bleCancelConnection(peripheralRef)
                }
                self.lock.withLock {
                    self.connectingPeripherals.remove(peripheralUUID)
                    self.connectedPeripheralRefs.removeValue(forKey: peripheralUUID)
                    self.timedOutPeripherals[peripheralUUID] = Date()
                    self.recordConnectionFailure(for: peripheralUUID)
                }
            }
        }
    }

    /// Handle successful connection.
    func handleDidConnect(peripheral: any BLEPeripheralProxy) {
        logger.info("Connected to peripheral \(peripheral.identifier)")
        transportEventHandler?("BLE", "CONNECTED peripheral \(peripheral.identifier.uuidString.prefix(8))")

        lock.withLock {
            connectingPeripherals.remove(peripheral.identifier)
            connectedPeripheralRefs[peripheral.identifier] = peripheral
            failureCounts.removeValue(forKey: peripheral.identifier)
            backoffUntil.removeValue(forKey: peripheral.identifier)

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
        emitDedupedConnect(peerID)
        NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)
    }

    /// Handle failed connection.
    func handleDidFailToConnect(peripheralUUID uuid: UUID) {
        logger.error("Failed to connect to \(uuid)")
        transportEventHandler?("BLE", "CONNECT FAILED peripheral \(uuid.uuidString.prefix(8))")

        lock.withLock {
            connectingPeripherals.remove(uuid)
            connectedPeripheralRefs.removeValue(forKey: uuid)
            timedOutPeripherals[uuid] = Date()
            recordConnectionFailure(for: uuid)
        }
    }

    /// Handle disconnection.
    func handleDidDisconnect(peripheralUUID uuid: UUID) {
        let shortUUID = uuid.uuidString.prefix(8)
        logger.info("Disconnected from \(shortUUID)")
        transportEventHandler?("BLE", "DISCONNECTED peripheral \(shortUUID)")

        let peerID: PeerID? = lock.withLock {
            let pid = peripheralToPeerID.removeValue(forKey: uuid)
            if let pid = pid {
                peerIDToPeripheral.removeValue(forKey: pid)
            }
            peripheralCharacteristics.removeValue(forKey: uuid)
            connectedPeripheralRefs.removeValue(forKey: uuid)
            peripheralRSSI.removeValue(forKey: uuid)
            connectingPeripherals.remove(uuid)

            // Clear dedup entry so a genuine reconnect fires a new CONNECTED event
            if let pid = pid {
                recentlyConnectedPeers.removeValue(forKey: pid)
            }

            // If the peer was connected long enough, reset its backoff — it was stable.
            if let pid = pid,
               let connectedAt = connectionEstablishedAt[pid],
               Date().timeIntervalSince(connectedAt) >= BLEConstants.stableConnectionThreshold {
                failureCounts.removeValue(forKey: uuid)
                backoffUntil.removeValue(forKey: uuid)
                timedOutPeripherals.removeValue(forKey: uuid)
                connectionEstablishedAt.removeValue(forKey: pid)
            } else {
                // Unstable connection — apply exponential backoff
                timedOutPeripherals[uuid] = Date()
                recordConnectionFailure(for: uuid)
                if let pid = pid {
                    connectionEstablishedAt.removeValue(forKey: pid)
                }
            }

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

    /// Fire a deduplicated CONNECTED event. Suppresses duplicate callbacks when both
    /// central and peripheral paths fire for the same peer within 500ms.
    private func emitDedupedConnect(_ peerID: PeerID) {
        let now = Date()
        let shouldEmit = lock.withLock { () -> Bool in
            // Prune stale entries (>5s old)
            recentlyConnectedPeers = recentlyConnectedPeers.filter { _, date in
                now.timeIntervalSince(date) < 5.0
            }

            if let lastConnect = recentlyConnectedPeers[peerID],
               now.timeIntervalSince(lastConnect) < Self.connectDedupWindow {
                return false
            }

            recentlyConnectedPeers[peerID] = now
            connectionEstablishedAt[peerID] = now
            return true
        }

        guard shouldEmit else {
            let shortID = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            transportEventHandler?("BLE", "CONNECT deduped \(shortID)")
            return
        }

        delegate?.transport(self, didConnect: peerID)
    }

    /// Clean up stale timed-out and backoff entries.
    private func pruneTimedOutPeripherals() {
        let now = Date()
        timedOutPeripherals = timedOutPeripherals.filter { _, date in
            now.timeIntervalSince(date) < BLEConstants.reconnectBackoffMax
        }
        // Clear expired backoff entries so memory doesn't grow unbounded
        backoffUntil = backoffUntil.filter { _, until in now < until }
        for uuid in failureCounts.keys where backoffUntil[uuid] == nil {
            failureCounts.removeValue(forKey: uuid)
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

    private func resetPeerTracking() {
        lock.withLock {
            peripheralToPeerID.removeAll()
            peerIDToPeripheral.removeAll()
            peripheralCharacteristics.removeAll()
            connectingPeripherals.removeAll()
            connectedPeripheralRefs.removeAll()
            peripheralRSSI.removeAll()
            subscribedCentrals.removeAll()
            centralToPeerID.removeAll()
            timedOutPeripherals.removeAll()
            failureCounts.removeAll()
            backoffUntil.removeAll()
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
            transportEventHandler?("BLE", "WRITE FAILED → \(peripheral.identifier.uuidString.prefix(8)): \(error.localizedDescription)")
        } else {
            transportEventHandler?("BLE", "WRITE OK → \(peripheral.identifier.uuidString.prefix(8))")
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
        guard error == nil else { return }
        let rssiValue = RSSI.intValue
        guard rssiValue != 127 else { return }
        lock.withLock {
            peripheralRSSI[peripheral.identifier] = rssiValue
        }
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
        transportEventHandler?("BLE", "Peripheral manager restoring state")

        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            transportEventHandler?("BLE", "Restored \(services.count) service(s)")
            for svc in services {
                self.service = svc
                if let chars = svc.characteristics {
                    for char in chars {
                        if char.uuid == BLEConstants.characteristicUUID,
                           let mutableChar = char as? CBMutableCharacteristic {
                            self.characteristic = mutableChar
                            transportEventHandler?("BLE", "Restored characteristic \(char.uuid.uuidString)")
                        }
                    }
                }
            }
        } else {
            transportEventHandler?("BLE", "No services to restore")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error = error {
            logger.error("Failed to add service: \(error.localizedDescription)")
            transportEventHandler?("BLE", "didAdd service FAILED: \(error.localizedDescription)")
        } else {
            logger.info("Service added, beginning advertising")
            transportEventHandler?("BLE", "Service added successfully, calling beginAdvertising()")
            beginAdvertising()
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error = error {
            logger.error("Advertising failed: \(error.localizedDescription)")
            transportEventHandler?("BLE", "Advertising FAILED: \(error.localizedDescription)")
        } else {
            transportEventHandler?("BLE", "Advertising CONFIRMED started successfully")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        logger.info("Central subscribed: \(central.identifier)")
        transportEventHandler?("BLE", "Central SUBSCRIBED \(central.identifier.uuidString.prefix(8))")

        let tempPeerID = temporaryPeerID(from: central.identifier)

        lock.withLock {
            if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                subscribedCentrals.append(central)
            }
            centralToPeerID[central.identifier] = tempPeerID
        }

        emitDedupedConnect(tempPeerID)
        NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        logger.info("Central unsubscribed: \(central.identifier)")
        transportEventHandler?("BLE", "Central UNSUBSCRIBED \(central.identifier.uuidString.prefix(8))")

        let peerID: PeerID? = lock.withLock {
            subscribedCentrals.removeAll { $0.identifier == central.identifier }
            let pid = centralToPeerID.removeValue(forKey: central.identifier)
            if let pid = pid {
                recentlyConnectedPeers.removeValue(forKey: pid)
                connectionEstablishedAt.removeValue(forKey: pid)
            }
            return pid
        }

        if let peerID = peerID {
            delegate?.transport(self, didDisconnect: peerID)
            NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)
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

// MARK: - CBManagerState Debug Names

extension CBManagerState {
    var debugName: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
