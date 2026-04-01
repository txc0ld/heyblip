import Foundation
@preconcurrency import CoreBluetooth

/// BLE constants for the Blip mesh network (spec Section 5.1).
public enum BLEConstants: Sendable {

    // MARK: - Service & Characteristic UUIDs

    /// Primary Blip BLE service UUID.
    public static let serviceUUID = CBUUID(string: "FC000001-0000-1000-8000-00805F9B34FB")

    /// Primary Blip BLE characteristic UUID for data exchange.
    public static let characteristicUUID = CBUUID(string: "FC000002-0000-1000-8000-00805F9B34FB")

    /// Debug service UUID (for development/testing builds).
    public static let debugServiceUUID = CBUUID(string: "FC000001-0000-1000-8000-00805F9B34FA")

    // MARK: - MTU

    /// Requested MTU size in bytes.
    public static let requestedMTU = 517

    /// Effective MTU after ATT overhead.
    public static let effectiveMTU = 512

    /// Fragmentation threshold (worst-case: addressed + signed).
    public static let fragmentationThreshold = 416

    // MARK: - Timeouts

    /// Connection timeout in seconds.
    public static let connectionTimeout: TimeInterval = 10.0

    /// Minimum backoff before reconnecting to a disconnected peripheral.
    public static let reconnectBackoff: TimeInterval = 5.0

    /// Maximum backoff ceiling for exponential reconnect delay.
    public static let reconnectBackoffMax: TimeInterval = 60.0

    /// Peer stale threshold: a peer not heard from in this interval is considered gone.
    public static let peerStaleTimeout: TimeInterval = 60.0

    /// Peer evaluation interval for connection management (spec: 30s).
    public static let peerEvaluationInterval: TimeInterval = 30.0

    /// Scan duration in foreground.
    public static let foregroundScanDuration: TimeInterval = 5.0

    /// Scan pause between cycles in foreground.
    public static let foregroundScanPause: TimeInterval = 5.0

    // MARK: - Connection limits

    /// Maximum central connections in normal mode.
    public static let maxCentralConnectionsNormal = 6

    /// Maximum central connections for bridge nodes.
    public static let maxCentralConnectionsBridge = 8

    /// Maximum central connections for medical responders.
    public static let maxCentralConnectionsMedical = 10

    /// Maximum peripheral connections mirrors central limits.
    public static let maxPeripheralConnectionsNormal = 6
    public static let maxPeripheralConnectionsBridge = 8
    public static let maxPeripheralConnectionsMedical = 10

    // MARK: - RSSI

    /// Default minimum RSSI threshold for connection.
    public static let defaultRSSIThreshold: Int = -90

    /// Relaxed RSSI threshold when isolated (few/no peers).
    public static let isolatedRSSIThreshold: Int = -92

    /// RSSI sweet-spot range for optimal peer selection scoring.
    public static let rssiSweetSpotRange: ClosedRange<Int> = -70 ... -60

    // MARK: - State restoration

    /// CBCentralManager state restoration identifier.
    public static let centralRestorationID = "com.blip.ble.central"

    /// CBPeripheralManager state restoration identifier.
    public static let peripheralRestorationID = "com.blip.ble.peripheral"

    // MARK: - Advertising

    /// Default advertise interval (ms) -- maps to PowerManager tier.
    public static let defaultAdvertiseInterval: TimeInterval = 0.2

    // MARK: - Relay jitter

    /// Minimum relay jitter in seconds.
    public static let relayJitterMin: TimeInterval = 0.008

    /// Maximum relay jitter in seconds.
    public static let relayJitterMax: TimeInterval = 0.025
}
