import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import BlipMesh
import BlipProtocol

// MARK: - Helpers

private func makePeerID(_ byte: UInt8) -> PeerID {
    PeerID(bytes: Data([byte, byte, byte, byte, byte, byte, byte, byte]))!
}

// MARK: - MockBLECentralManager

final class MockBLECentralManager: BLECentralManaging, @unchecked Sendable {
    var cmState: CBManagerState = .unknown

    struct ScanCall {
        let services: [CBUUID]?
        let options: [String: Any]?
    }

    var scanCalls: [ScanCall] = []
    var stopScanCallCount = 0
    var connectCalls: [(identifier: UUID, options: [String: Any]?)] = []
    var cancelConnectionCalls: [UUID] = []

    func bleStartScan(services: [CBUUID]?, options: [String: Any]?) {
        scanCalls.append(ScanCall(services: services, options: options))
    }

    func bleStopScan() {
        stopScanCallCount += 1
    }

    func bleConnect(_ peripheral: any BLEPeripheralProxy, options: [String: Any]?) {
        connectCalls.append((peripheral.identifier, options))
    }

    func bleCancelConnection(_ peripheral: any BLEPeripheralProxy) {
        cancelConnectionCalls.append(peripheral.identifier)
    }
}

// MARK: - MockBLEPeripheralManager

final class MockBLEPeripheralManager: BLEPeripheralManaging, @unchecked Sendable {
    var pmState: CBManagerState = .unknown
    var bleIsAdvertising: Bool = false

    var startAdvertisingCalls: [[String: Any]?] = []
    var stopAdvertisingCallCount = 0
    var addServiceCalls: [CBMutableService] = []
    var removeServiceCalls: [CBMutableService] = []
    var updateValueCalls: [(data: Data, characteristic: CBMutableCharacteristic)] = []

    func bleStartAdvertising(_ data: [String: Any]?) {
        startAdvertisingCalls.append(data)
        bleIsAdvertising = true
    }

    func bleStopAdvertising() {
        stopAdvertisingCallCount += 1
        bleIsAdvertising = false
    }

    func bleAddService(_ service: CBMutableService) {
        addServiceCalls.append(service)
    }

    func bleRemoveService(_ service: CBMutableService) {
        removeServiceCalls.append(service)
    }

    func bleUpdateValue(
        _ value: Data,
        for characteristic: CBMutableCharacteristic,
        onSubscribedCentrals: [CBCentral]?
    ) -> Bool {
        updateValueCalls.append((value, characteristic))
        return true
    }
}

// MARK: - MockPeripheral

final class MockPeripheral: BLEPeripheralProxy, @unchecked Sendable {
    let identifier: UUID
    let name: String?

    var discoverServicesCalls: [[CBUUID]?] = []
    var discoverCharacteristicsCalls: [([CBUUID]?, CBService)] = []
    var writeValueCalls: [(data: Data, characteristic: CBCharacteristic, type: CBCharacteristicWriteType)] = []
    var setNotifyValueCalls: [(enabled: Bool, characteristic: CBCharacteristic)] = []

    init(identifier: UUID = UUID(), name: String? = nil) {
        self.identifier = identifier
        self.name = name
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        discoverServicesCalls.append(serviceUUIDs)
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        discoverCharacteristicsCalls.append((characteristicUUIDs, service))
    }

    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writeValueCalls.append((data, characteristic, type))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        setNotifyValueCalls.append((enabled, characteristic))
    }
}

// MARK: - MockTransportDelegate

final class MockTransportDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()

    private var _stateChanges: [TransportState] = []
    private var _connectEvents: [PeerID] = []
    private var _disconnectEvents: [PeerID] = []
    private var _receivedData: [(data: Data, from: PeerID)] = []

    var stateChanges: [TransportState] {
        lock.withLock { _stateChanges }
    }

    var connectEvents: [PeerID] {
        lock.withLock { _connectEvents }
    }

    var disconnectEvents: [PeerID] {
        lock.withLock { _disconnectEvents }
    }

    var receivedData: [(data: Data, from: PeerID)] {
        lock.withLock { _receivedData }
    }

    func transport(_ transport: any Transport, didChangeState state: TransportState) {
        lock.withLock { _stateChanges.append(state) }
    }

    func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        lock.withLock { _connectEvents.append(peerID) }
    }

    func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        lock.withLock { _disconnectEvents.append(peerID) }
    }

    func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID) {
        lock.withLock { _receivedData.append((data, peerID)) }
    }
}

// MARK: - Test Factory

private func makeBLEService() -> (
    service: BLEService,
    central: MockBLECentralManager,
    peripheral: MockBLEPeripheralManager,
    delegate: MockTransportDelegate
) {
    let mockCentral = MockBLECentralManager()
    let mockPeripheral = MockBLEPeripheralManager()
    let mockDelegate = MockTransportDelegate()

    let service = BLEService(
        localPeerID: makePeerID(0xAA),
        centralManager: mockCentral,
        peripheralManager: mockPeripheral
    )
    service.delegate = mockDelegate

    return (service, mockCentral, mockPeripheral, mockDelegate)
}

/// Start the service and power on both managers.
private func makeRunningBLEService() -> (
    service: BLEService,
    central: MockBLECentralManager,
    peripheral: MockBLEPeripheralManager,
    delegate: MockTransportDelegate
) {
    let (service, central, peripheral, delegate) = makeBLEService()
    central.cmState = .poweredOn
    peripheral.pmState = .poweredOn
    service.start()
    service.handleCentralStateChange(.poweredOn)
    return (service, central, peripheral, delegate)
}

// ============================================================
// Suite 1: Lifecycle
// ============================================================

@Suite("BLE Lifecycle")
struct BLELifecycleTests {

    @Test("start() transitions state idle → starting")
    func startTransitionsToStarting() {
        let (service, _, _, delegate) = makeBLEService()

        #expect(service.state == .idle)
        service.start()
        #expect(service.state == .starting)
        #expect(delegate.stateChanges.contains(.starting))
    }

    @Test("Central poweredOn transitions state starting → running")
    func centralPoweredOnTransitionsToRunning() {
        let (service, central, _, delegate) = makeBLEService()
        central.cmState = .poweredOn

        service.start()
        #expect(service.state == .starting)

        service.handleCentralStateChange(.poweredOn)
        #expect(service.state == .running)
        #expect(delegate.stateChanges.contains(.running))
    }

    @Test("Peripheral poweredOn also transitions to running")
    func peripheralPoweredOnTransitionsToRunning() {
        let (service, _, peripheral, delegate) = makeBLEService()
        peripheral.pmState = .poweredOn

        service.start()
        service.handlePeripheralManagerStateChange(.poweredOn)

        #expect(service.state == .running)
        #expect(delegate.stateChanges.contains(.running))
    }

    @Test("stop() transitions to stopped and clears state")
    func stopTransitionsToStopped() {
        let (service, central, peripheral, delegate) = makeRunningBLEService()

        // Add a connected peripheral to verify cleanup.
        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        #expect(service.connectedPeers.count == 1)

        service.stop()
        #expect(service.state == .stopped)
        #expect(delegate.stateChanges.last == .stopped)
        #expect(service.connectedPeers.isEmpty)
        // Verify cancel was called for the connected peripheral.
        #expect(central.cancelConnectionCalls.contains(mockPeer.identifier))
    }

    @Test("stop() stops scanning and advertising")
    func stopStopsScanningAndAdvertising() {
        let (service, central, peripheral, _) = makeRunningBLEService()
        peripheral.bleIsAdvertising = true

        service.stop()
        #expect(central.stopScanCallCount > 0)
        #expect(peripheral.stopAdvertisingCallCount > 0)
        #expect(service.isScanning == false)
    }

    @Test("start() after stop() restarts correctly")
    func startAfterStopRestarts() {
        let (service, central, _, delegate) = makeRunningBLEService()

        service.stop()
        #expect(service.state == .stopped)

        central.cmState = .poweredOn
        service.start()
        #expect(service.state == .starting)

        service.handleCentralStateChange(.poweredOn)
        #expect(service.state == .running)
    }

    @Test("Central unauthorized transitions to failed")
    func centralUnauthorizedFails() {
        let (service, _, _, delegate) = makeBLEService()
        service.start()

        service.handleCentralStateChange(.unauthorized)
        #expect(service.state == .failed("Bluetooth unauthorized"))
    }

    @Test("Central unsupported transitions to failed")
    func centralUnsupportedFails() {
        let (service, _, _, _) = makeBLEService()
        service.start()

        service.handleCentralStateChange(.unsupported)
        #expect(service.state == .failed("Bluetooth unsupported"))
    }

    @Test("Central poweredOff transitions to failed")
    func centralPoweredOffFails() {
        let (service, _, _, _) = makeBLEService()
        service.start()

        service.handleCentralStateChange(.poweredOff)
        #expect(service.state == .failed("Bluetooth powered off"))
    }
}

// ============================================================
// Suite 2: Peer Discovery
// ============================================================

@Suite("BLE Peer Discovery")
struct BLEPeerDiscoveryTests {

    @Test("Powering on central triggers scan with correct service UUID")
    func scanStartsWithCorrectUUID() {
        let (service, central, _, _) = makeBLEService()
        central.cmState = .poweredOn
        service.start()

        service.handleCentralStateChange(.poweredOn)

        #expect(central.scanCalls.count == 1)
        #expect(central.scanCalls[0].services == [BLEConstants.serviceUUID])
    }

    @Test("RSSI below threshold is rejected")
    func rssiBelowThresholdRejected() {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        // Default threshold is -90 (or -92 when isolated).
        // With no peers connected, threshold is -92 (isolated).
        service.handleDidDiscover(peripheral: mockPeer, rssi: -95)

        // Should not have triggered a connect.
        #expect(service.connectingPeripherals.isEmpty)
    }

    @Test("RSSI above threshold is accepted")
    func rssiAboveThresholdAccepted() {
        let (service, central, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidDiscover(peripheral: mockPeer, rssi: -60)

        #expect(central.connectCalls.count == 1)
        #expect(central.connectCalls[0].identifier == mockPeer.identifier)
    }

    @Test("RSSI 127 (unavailable) is ignored")
    func rssiUnavailableIgnored() {
        let (service, central, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidDiscover(peripheral: mockPeer, rssi: 127)

        #expect(central.connectCalls.isEmpty)
    }

    @Test("Duplicate discoveries of same UUID are not re-connected")
    func duplicateDiscoveryIgnored() {
        let (service, central, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidDiscover(peripheral: mockPeer, rssi: -60)
        service.handleDidDiscover(peripheral: mockPeer, rssi: -60)

        // Only one connect call — second discovery sees it in connectingPeripherals.
        #expect(central.connectCalls.count == 1)
    }

    @Test("shouldConnect returns false when already connected")
    func shouldConnectFalseWhenConnected() {
        let (service, _, _, _) = makeRunningBLEService()

        let uuid = UUID()
        let mockPeer = MockPeripheral(identifier: uuid)
        service.handleDidConnect(peripheral: mockPeer)

        #expect(service.shouldConnect(toUUID: uuid, rssi: -60) == false)
    }
}

// ============================================================
// Suite 3: Connection Management
// ============================================================

@Suite("BLE Connection Management")
struct BLEConnectionManagementTests {

    @Test("Successful connection triggers service discovery")
    func connectTriggersServiceDiscovery() {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)

        #expect(mockPeer.discoverServicesCalls.count == 1)
        #expect(mockPeer.discoverServicesCalls[0] == [BLEConstants.serviceUUID])
    }

    @Test("Successful connection notifies delegate")
    func connectNotifiesDelegate() {
        let (service, _, _, delegate) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)

        #expect(delegate.connectEvents.count == 1)
    }

    @Test("Successful connection tracks peer in maps")
    func connectTracksPeer() {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)

        #expect(service.connectedPeers.count == 1)
        #expect(service.peripheralToPeerID[mockPeer.identifier] != nil)
        #expect(service.connectedPeripheralRefs[mockPeer.identifier] != nil)
    }

    @Test("Failed connection triggers backoff tracking")
    func failedConnectionTracksBackoff() {
        let (service, _, _, _) = makeRunningBLEService()

        let uuid = UUID()
        // Simulate a peripheral that was in connecting state.
        service.connectingPeripherals.insert(uuid)

        service.handleDidFailToConnect(peripheralUUID: uuid)

        // UUID should be in timedOutPeripherals.
        #expect(service.timedOutPeripherals[uuid] != nil)
        #expect(service.connectingPeripherals.isEmpty)
    }

    @Test("Timed out peripheral is rejected by shouldConnect")
    func timedOutPeripheralRejected() {
        let (service, _, _, _) = makeRunningBLEService()

        let uuid = UUID()
        service.timedOutPeripherals[uuid] = Date()

        #expect(service.shouldConnect(toUUID: uuid, rssi: -60) == false)
    }

    @Test("Connection limit enforcement (max 6 normal)")
    func connectionLimitEnforced() {
        let (service, _, _, _) = makeRunningBLEService()

        // Connect 6 peripherals.
        for _ in 0..<6 {
            let mockPeer = MockPeripheral()
            service.handleDidConnect(peripheral: mockPeer)
        }

        #expect(service.connectedPeers.count == 6)

        // 7th should be rejected.
        let extraUUID = UUID()
        #expect(service.shouldConnect(toUUID: extraUUID, rssi: -60) == false)
    }

    @Test("Disconnect cleans up all mappings")
    func disconnectCleansUpMappings() {
        let (service, _, _, delegate) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let peerID = service.peripheralToPeerID[mockPeer.identifier]!

        // Set up a characteristic mapping too.
        let char = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        service.peripheralCharacteristics[mockPeer.identifier] = char

        service.handleDidDisconnect(peripheralUUID: mockPeer.identifier)

        #expect(service.peripheralToPeerID[mockPeer.identifier] == nil)
        #expect(service.peripheralCharacteristics[mockPeer.identifier] == nil)
        #expect(service.connectedPeripheralRefs[mockPeer.identifier] == nil)
        #expect(service.connectedPeers.isEmpty)
        #expect(delegate.disconnectEvents.count == 1)
        #expect(delegate.disconnectEvents[0] == peerID)
    }

    @Test("Reconnection after disconnect works")
    func reconnectionAfterDisconnect() {
        let (service, central, _, delegate) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let firstPeerID = service.peripheralToPeerID[mockPeer.identifier]!

        service.handleDidDisconnect(peripheralUUID: mockPeer.identifier)
        #expect(service.connectedPeers.isEmpty)

        // Re-discover and reconnect.
        service.handleDidDiscover(peripheral: mockPeer, rssi: -60)
        service.handleDidConnect(peripheral: mockPeer)

        #expect(service.connectedPeers.count == 1)
        #expect(delegate.connectEvents.count == 2)
    }
}

// ============================================================
// Suite 4: Data Transfer
// ============================================================

@Suite("BLE Data Transfer")
struct BLEDataTransferTests {

    @Test("send() writes to correct peripheral's characteristic")
    func sendWritesToCorrectPeripheral() throws {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let peerID = service.connectedPeers[0]

        // Set up a characteristic for the peripheral.
        let char = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        service.peripheralCharacteristics[mockPeer.identifier] = char

        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try service.send(data: testData, to: peerID)

        #expect(mockPeer.writeValueCalls.count == 1)
        #expect(mockPeer.writeValueCalls[0].data == testData)
        #expect(mockPeer.writeValueCalls[0].type == .withResponse)
    }

    @Test("send() throws peerNotConnected for unknown peer")
    func sendThrowsPeerNotConnected() {
        let (service, _, _, _) = makeRunningBLEService()

        let unknownPeerID = makePeerID(0xFF)
        #expect(throws: TransportError.peerNotConnected(unknownPeerID)) {
            try service.send(data: Data([0x01]), to: unknownPeerID)
        }
    }

    @Test("send() throws notStarted when not running")
    func sendThrowsNotStarted() {
        let (service, _, _, _) = makeBLEService()
        // Service is in .idle state — not started.
        #expect(throws: TransportError.notStarted) {
            try service.send(data: Data([0x01]), to: makePeerID(0x01))
        }
    }

    @Test("broadcast() writes to all connected peripherals")
    func broadcastWritesToAll() {
        let (service, _, _, _) = makeRunningBLEService()

        // Connect two peripherals with characteristics.
        let peer1 = MockPeripheral()
        let peer2 = MockPeripheral()
        service.handleDidConnect(peripheral: peer1)
        service.handleDidConnect(peripheral: peer2)

        let char1 = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let char2 = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        service.peripheralCharacteristics[peer1.identifier] = char1
        service.peripheralCharacteristics[peer2.identifier] = char2

        let testData = Data([0xCA, 0xFE])
        service.broadcast(data: testData)

        #expect(peer1.writeValueCalls.count == 1)
        #expect(peer1.writeValueCalls[0].data == testData)
        #expect(peer1.writeValueCalls[0].type == .withoutResponse)

        #expect(peer2.writeValueCalls.count == 1)
        #expect(peer2.writeValueCalls[0].data == testData)
    }

    @Test("Received data triggers delegate callback")
    func receivedDataTriggersDelegate() {
        let (service, _, _, delegate) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let peerID = service.connectedPeers[0]

        let testData = Data([0x01, 0x02, 0x03, 0x04])
        service.handleDidReceiveValue(data: testData, fromPeripheralUUID: mockPeer.identifier)

        #expect(delegate.receivedData.count == 1)
        #expect(delegate.receivedData[0].data == testData)
        #expect(delegate.receivedData[0].from == peerID)
    }

    @Test("Binary data preserved exactly through send path")
    func binaryDataPreserved() throws {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let peerID = service.connectedPeers[0]

        let char = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        service.peripheralCharacteristics[mockPeer.identifier] = char

        // Send all possible byte values.
        var testData = Data()
        for byte: UInt8 in 0...255 {
            testData.append(byte)
        }

        try service.send(data: testData, to: peerID)

        #expect(mockPeer.writeValueCalls[0].data == testData)
        // Verify byte-by-byte.
        let sent = mockPeer.writeValueCalls[0].data
        for i in 0..<256 {
            #expect(sent[i] == UInt8(i))
        }
    }

    @Test("broadcast() is no-op when not running")
    func broadcastNoOpWhenNotRunning() {
        let (service, _, _, _) = makeBLEService()

        let mockPeer = MockPeripheral()
        // Manually add a peer (without starting service).
        service.connectedPeripheralRefs[mockPeer.identifier] = mockPeer

        service.broadcast(data: Data([0x01]))
        #expect(mockPeer.writeValueCalls.isEmpty)
    }
}

// ============================================================
// Suite 5: Dual-Role Operation
// ============================================================

@Suite("BLE Dual-Role Operation")
struct BLEDualRoleTests {

    @Test("start() uses both central and peripheral managers")
    func startUsesBothManagers() {
        let (service, central, peripheral, _) = makeBLEService()
        central.cmState = .poweredOn
        peripheral.pmState = .poweredOn

        service.start()

        // Simulate both powering on.
        service.handleCentralStateChange(.poweredOn)
        service.handlePeripheralManagerStateChange(.poweredOn)

        #expect(service.state == .running)
        // Central should have started scanning.
        #expect(central.scanCalls.count >= 1)
        // Peripheral manager characteristic should be set up.
        #expect(service.characteristic != nil)
    }

    @Test("Can receive data while sending")
    func simultaneousSendAndReceive() throws {
        let (service, _, _, delegate) = makeRunningBLEService()

        // Set up a connected peripheral for sending.
        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)
        let peerID = service.connectedPeers[0]

        let char = CBMutableCharacteristic(
            type: BLEConstants.characteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        service.peripheralCharacteristics[mockPeer.identifier] = char

        // Send data.
        let sendData = Data([0x01, 0x02])
        try service.send(data: sendData, to: peerID)

        // Receive data at the same time.
        let receiveData = Data([0x03, 0x04])
        service.handleDidReceiveValue(data: receiveData, fromPeripheralUUID: mockPeer.identifier)

        #expect(mockPeer.writeValueCalls.count == 1)
        #expect(delegate.receivedData.count == 1)
        #expect(delegate.receivedData[0].data == receiveData)
    }

    @Test("Peripheral manager state change triggers advertising setup")
    func peripheralPoweredOnStartsAdvertising() {
        let (service, _, peripheral, _) = makeBLEService()
        peripheral.pmState = .poweredOn

        service.start()
        service.handlePeripheralManagerStateChange(.poweredOn)

        // Service and characteristic should be created, and addService called.
        #expect(service.service != nil)
        #expect(service.characteristic != nil)
        #expect(peripheral.addServiceCalls.count == 1)
    }
}

// ============================================================
// Suite 6: PeerID Mapping
// ============================================================

@Suite("BLE PeerID Mapping")
struct BLEPeerIDMappingTests {

    @Test("temporaryPeerID is deterministic for same UUID")
    func temporaryPeerIDDeterministic() {
        let (service, _, _, _) = makeBLEService()
        let uuid = UUID()

        let id1 = service.temporaryPeerID(from: uuid)
        let id2 = service.temporaryPeerID(from: uuid)

        #expect(id1 == id2)
    }

    @Test("Different UUIDs produce different temporary PeerIDs")
    func differentUUIDsDifferentPeerIDs() {
        let (service, _, _, _) = makeBLEService()

        let id1 = service.temporaryPeerID(from: UUID())
        let id2 = service.temporaryPeerID(from: UUID())

        #expect(id1 != id2)
    }

    @Test("updatePeerID replaces temporary PeerID")
    func updatePeerIDReplacesTemporary() {
        let (service, _, _, _) = makeRunningBLEService()

        let mockPeer = MockPeripheral()
        service.handleDidConnect(peripheral: mockPeer)

        let tempPeerID = service.peripheralToPeerID[mockPeer.identifier]!
        let realPeerID = makePeerID(0xBB)

        service.updatePeerID(realPeerID, forPeripheralUUID: mockPeer.identifier)

        #expect(service.peripheralToPeerID[mockPeer.identifier] == realPeerID)
        // Old temp ID should be removed from reverse map.
        #expect(service.peerIDToPeripheral[tempPeerID] == nil)
        // New ID should be in reverse map.
        #expect(service.peerIDToPeripheral[realPeerID] != nil)
    }

    @Test("Multiple connected peers tracked independently")
    func multiplePeersTrackedIndependently() {
        let (service, _, _, _) = makeRunningBLEService()

        let peer1 = MockPeripheral()
        let peer2 = MockPeripheral()
        let peer3 = MockPeripheral()

        service.handleDidConnect(peripheral: peer1)
        service.handleDidConnect(peripheral: peer2)
        service.handleDidConnect(peripheral: peer3)

        #expect(service.connectedPeers.count == 3)

        // Disconnect only peer2.
        service.handleDidDisconnect(peripheralUUID: peer2.identifier)
        #expect(service.connectedPeers.count == 2)

        // peer1 and peer3 still tracked.
        #expect(service.peripheralToPeerID[peer1.identifier] != nil)
        #expect(service.peripheralToPeerID[peer3.identifier] != nil)
        #expect(service.peripheralToPeerID[peer2.identifier] == nil)
    }
}
