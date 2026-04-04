import Foundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Power tier

/// Battery management tiers controlling scan/advertise/relay behavior (spec Section 8.8).
public enum PowerTier: String, Sendable, CaseIterable {
    /// > 60% or charging. Full performance.
    case performance
    /// 30-60%. Balanced.
    case balanced
    /// 10-30%. Reduced relay.
    case powerSaver
    /// < 10%. Relay disabled.
    case ultraLow

    /// Determine the power tier for a given battery level.
    ///
    /// - Parameters:
    ///   - level: Battery level (0.0 to 1.0).
    ///   - isCharging: Whether the device is charging.
    public static func tier(level: Float, isCharging: Bool) -> PowerTier {
        if isCharging || level > 0.60 { return .performance }
        if level > 0.30 { return .balanced }
        if level > 0.10 { return .powerSaver }
        return .ultraLow
    }

    /// BLE scan on duration in seconds.
    public var scanOnDuration: TimeInterval {
        switch self {
        case .performance: return 5.0
        case .balanced:    return 4.0
        case .powerSaver:  return 3.0
        case .ultraLow:    return 2.0
        }
    }

    /// BLE scan off (pause) duration in seconds.
    public var scanOffDuration: TimeInterval {
        switch self {
        case .performance: return 5.0
        case .balanced:    return 8.0
        case .powerSaver:  return 15.0
        case .ultraLow:    return 30.0
        }
    }

    /// BLE advertise interval in seconds.
    public var advertiseInterval: TimeInterval {
        switch self {
        case .performance: return 0.2
        case .balanced:    return 0.5
        case .powerSaver:  return 1.0
        case .ultraLow:    return 2.0
        }
    }

    /// Whether relay is enabled in this tier.
    public var relayEnabled: Bool {
        switch self {
        case .performance: return true
        case .balanced:    return true
        case .powerSaver:  return true  // Reduced, but enabled.
        case .ultraLow:    return false // Relay disabled.
        }
    }

    /// Whether relay is at full capacity (vs. reduced).
    public var fullRelay: Bool {
        switch self {
        case .performance: return true
        case .balanced:    return true
        case .powerSaver:  return false
        case .ultraLow:    return false
        }
    }
}

// MARK: - PowerManager

/// Manages battery-aware mesh behavior (spec Section 8.8).
///
/// Monitors `UIDevice.current.batteryLevel` and adjusts BLE scan duty cycle,
/// advertise interval, and relay behavior according to 4 power tiers:
///
/// | Tier        | Battery  | Scan on/off | Advertise | Relay    |
/// |-------------|----------|-------------|-----------|----------|
/// | Performance | >60%/chg | 5s/5s       | 200ms     | Full     |
/// | Balanced    | 30-60%   | 4s/8s       | 500ms     | Full     |
/// | Power Saver | 10-30%   | 3s/15s      | 1000ms    | Reduced  |
/// | Ultra-Low   | <10%     | 2s/30s      | 2000ms    | Disabled |
public final class PowerManager: @unchecked Sendable {

    // MARK: - Constants

    /// How often to check battery level.
    public static let checkInterval: TimeInterval = 30.0

    // MARK: - Published state

    /// Current power tier, published via Combine.
    public let tierPublisher: CurrentValueSubject<PowerTier, Never>

    /// Current power tier.
    public var currentTier: PowerTier {
        tierPublisher.value
    }

    /// Current battery level (0.0 to 1.0).
    public private(set) var batteryLevel: Float = 1.0

    /// Whether the device is currently charging.
    public private(set) var isCharging: Bool = false

    // MARK: - Internals

    private let lock = NSLock()
    private var monitorTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blip.power", qos: .utility)
    private let logger = Logger(subsystem: "com.blip", category: "PowerManager")

    #if canImport(UIKit)
    private var batteryLevelObservation: NSObjectProtocol?
    private var batteryStateObservation: NSObjectProtocol?
    #endif

    // MARK: - Init

    public init(initialTier: PowerTier = .performance) {
        self.tierPublisher = CurrentValueSubject(initialTier)
    }

    // MARK: - Monitoring

    /// Start monitoring battery level and adjusting the power tier.
    public func startMonitoring() {
        #if canImport(UIKit) && !os(macOS)
        // Enable battery monitoring on iOS.
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }

        // Observe battery level changes.
        batteryLevelObservation = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateBatteryState() }
        }

        batteryStateObservation = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateBatteryState() }
        }

        // Initial check.
        Task { @MainActor [weak self] in
            self?.updateBatteryState()
        }
        #endif

        // Periodic fallback check.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.checkInterval,
            repeating: Self.checkInterval
        )
        timer.setEventHandler { [weak self] in
            #if canImport(UIKit) && !os(macOS)
            Task { @MainActor in self?.updateBatteryState() }
            #endif
        }
        timer.resume()
        monitorTimer = timer
    }

    /// Stop monitoring.
    public func stopMonitoring() {
        monitorTimer?.cancel()
        monitorTimer = nil

        #if canImport(UIKit)
        if let obs = batteryLevelObservation {
            NotificationCenter.default.removeObserver(obs)
            batteryLevelObservation = nil
        }
        if let obs = batteryStateObservation {
            NotificationCenter.default.removeObserver(obs)
            batteryStateObservation = nil
        }
        #endif
    }

    /// Force-set the battery level (for testing or simulators).
    public func setBatteryLevel(_ level: Float, isCharging: Bool) {
        lock.lock()
        self.batteryLevel = max(0, min(1, level))
        self.isCharging = isCharging
        lock.unlock()

        let newTier = PowerTier.tier(level: self.batteryLevel, isCharging: isCharging)
        if newTier != tierPublisher.value {
            logger.info("Power tier: \(self.tierPublisher.value.rawValue) -> \(newTier.rawValue) (battery: \(Int(self.batteryLevel * 100))%)")
            tierPublisher.send(newTier)
        }
    }

    // MARK: - Internals

    @MainActor private func updateBatteryState() {
        #if canImport(UIKit) && !os(macOS)
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full

        lock.lock()
        // batteryLevel returns -1.0 if monitoring is not enabled or on simulator.
        self.batteryLevel = level >= 0 ? level : 1.0
        self.isCharging = charging
        lock.unlock()

        let newTier = PowerTier.tier(level: self.batteryLevel, isCharging: charging)
        if newTier != tierPublisher.value {
            logger.info("Power tier: \(self.tierPublisher.value.rawValue) -> \(newTier.rawValue) (battery: \(Int(self.batteryLevel * 100))%)")
            tierPublisher.send(newTier)
        }
        #endif
    }
}
