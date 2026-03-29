import Foundation
@preconcurrency import CoreBluetooth

/// Protocol abstracting CBPeripheral for dependency injection in tests.
protocol BLEPeripheralProxy: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
}

extension CBPeripheral: BLEPeripheralProxy {}

/// Protocol abstracting CBCentralManager for dependency injection in tests.
protocol BLECentralManaging: AnyObject {
    var cmState: CBManagerState { get }
    func bleStartScan(services: [CBUUID]?, options: [String: Any]?)
    func bleStopScan()
    func bleConnect(_ peripheral: any BLEPeripheralProxy, options: [String: Any]?)
    func bleCancelConnection(_ peripheral: any BLEPeripheralProxy)
}

extension CBCentralManager: BLECentralManaging {
    var cmState: CBManagerState { state }

    func bleStartScan(services: [CBUUID]?, options: [String: Any]?) {
        scanForPeripherals(withServices: services, options: options)
    }

    func bleStopScan() { stopScan() }

    func bleConnect(_ peripheral: any BLEPeripheralProxy, options: [String: Any]?) {
        guard let cbp = peripheral as? CBPeripheral else { return }
        connect(cbp, options: options)
    }

    func bleCancelConnection(_ peripheral: any BLEPeripheralProxy) {
        guard let cbp = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(cbp)
    }
}

/// Protocol abstracting CBPeripheralManager for dependency injection in tests.
protocol BLEPeripheralManaging: AnyObject {
    var pmState: CBManagerState { get }
    var bleIsAdvertising: Bool { get }
    func bleStartAdvertising(_ data: [String: Any]?)
    func bleStopAdvertising()
    func bleAddService(_ service: CBMutableService)
    func bleRemoveService(_ service: CBMutableService)
    func bleUpdateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals: [CBCentral]?) -> Bool
}

extension CBPeripheralManager: BLEPeripheralManaging {
    var pmState: CBManagerState { state }
    var bleIsAdvertising: Bool { isAdvertising }

    func bleStartAdvertising(_ data: [String: Any]?) { startAdvertising(data) }
    func bleStopAdvertising() { stopAdvertising() }
    func bleAddService(_ service: CBMutableService) { add(service) }
    func bleRemoveService(_ service: CBMutableService) { remove(service) }

    func bleUpdateValue(
        _ value: Data,
        for characteristic: CBMutableCharacteristic,
        onSubscribedCentrals: [CBCentral]?
    ) -> Bool {
        updateValue(value, for: characteristic, onSubscribedCentrals: onSubscribedCentrals)
    }
}
