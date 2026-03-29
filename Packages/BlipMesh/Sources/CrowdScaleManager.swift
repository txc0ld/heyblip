import Foundation
import Combine
import BlipProtocol
import os.log

// MARK: - Crowd-scale mode

/// Crowd density modes that control the mesh operating profile (spec Section 8.1).
public enum CrowdScaleMode: String, Sendable, CaseIterable {
    /// < 500 peers. Full features, relaxed relay, all media types.
    case gather
    /// 500 - 5,000 peers. Moderate throttle, text + compressed voice.
    case festival
    /// 5,000 - 25,000 peers. Text-first, tight relay, text only.
    case mega
    /// 25,000 - 100,000+ peers. Text-only, aggressive clustering, all media internet-only.
    case massive

    /// Peer estimate range for this mode.
    public var peerRange: ClosedRange<Int> {
        switch self {
        case .gather:   return 0...499
        case .festival: return 500...4_999
        case .mega:     return 5_000...24_999
        case .massive:  return 25_000...Int.max
        }
    }

    /// Determine the mode for a given peer count.
    public static func mode(forPeerCount count: Int) -> CrowdScaleMode {
        switch count {
        case ..<500:       return .gather
        case 500..<5_000:  return .festival
        case 5_000..<25_000: return .mega
        default:           return .massive
        }
    }

    /// Dynamic TTL for SOS (always 7).
    public var sosTTL: UInt8 { 7 }

    /// Dynamic TTL for DMs per crowd mode (spec Section 8.3).
    public var dmTTL: UInt8 {
        switch self {
        case .gather:   return 7
        case .festival: return 5
        case .mega:     return 4
        case .massive:  return 3
        }
    }

    /// Dynamic TTL for group messages per crowd mode.
    public var groupTTL: UInt8 {
        switch self {
        case .gather:   return 5
        case .festival: return 4
        case .mega:     return 3
        case .massive:  return 2
        }
    }

    /// Dynamic TTL for broadcasts per crowd mode.
    public var broadcastTTL: UInt8 {
        switch self {
        case .gather:   return 5
        case .festival: return 3
        case .mega:     return 2
        case .massive:  return 0 // Suppressed
        }
    }

    /// Dynamic TTL for announcements per crowd mode.
    public var announcementTTL: UInt8 {
        switch self {
        case .gather:   return 7
        case .festival: return 6
        case .mega:     return 5
        case .massive:  return 5
        }
    }

    /// Whether media is allowed on mesh in this mode.
    public var allowsMediaOnMesh: Bool {
        switch self {
        case .gather:   return true
        case .festival: return true // Text + compressed voice only.
        case .mega:     return false
        case .massive:  return false
        }
    }

    /// Whether voice is allowed on mesh in this mode.
    public var allowsVoiceOnMesh: Bool {
        switch self {
        case .gather:   return true
        case .festival: return true
        case .mega:     return false
        case .massive:  return false
        }
    }
}

// MARK: - CrowdScaleManager

/// Manages crowd density detection and mode switching (spec Section 8.1).
///
/// Detection: Count unique peers seen in last 5 minutes (direct + announced neighbors).
/// Smoothed with exponential moving average. 60-second hysteresis before mode switch.
/// Publishes current mode via Combine.
public final class CrowdScaleManager: @unchecked Sendable {

    // MARK: - Constants

    /// The time window for counting unique peers (5 minutes).
    public static let peerCountWindow: TimeInterval = 5 * 60

    /// EMA smoothing factor (alpha). Higher = more responsive. 0.3 balances responsiveness/stability.
    public static let emaSmoothingFactor: Double = 0.3

    /// Hysteresis duration: mode must be sustained for 60 seconds before switching.
    public static let hysteresisDuration: TimeInterval = 60.0

    /// How often to re-evaluate the mode.
    public static let evaluationInterval: TimeInterval = 10.0

    // MARK: - Published state

    /// The current crowd-scale mode, published via Combine.
    public let modePublisher: CurrentValueSubject<CrowdScaleMode, Never>

    /// The current crowd-scale mode.
    public var currentMode: CrowdScaleMode {
        modePublisher.value
    }

    /// The current smoothed peer count estimate.
    public private(set) var smoothedPeerCount: Double = 0

    /// The raw (unsmoothed) peer count from the last evaluation.
    public private(set) var rawPeerCount: Int = 0

    // MARK: - Internal state

    /// Pending mode: the mode we would switch to, waiting for hysteresis.
    private var pendingMode: CrowdScaleMode?

    /// When the pending mode was first detected.
    private var pendingModeStartedAt: Date?

    /// Peer sightings within the window: PeerID -> last seen timestamp.
    private var peerSightings: [PeerID: Date] = [:]

    private let lock = NSLock()
    private var evaluationTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.blip.crowdScale", qos: .utility)
    private let logger = Logger(subsystem: "com.blip", category: "CrowdScale")

    // MARK: - Init

    public init(initialMode: CrowdScaleMode = .gather) {
        self.modePublisher = CurrentValueSubject(initialMode)
    }

    // MARK: - Peer reporting

    /// Report that a peer was seen (either directly connected or announced by a neighbor).
    public func reportPeerSeen(_ peerID: PeerID) {
        lock.withLock {
            peerSightings[peerID] = Date()
        }
    }

    /// Report multiple peers seen at once (e.g., from an announcement's neighbor list).
    public func reportPeersSeen(_ peerIDs: [PeerID]) {
        let now = Date()
        lock.withLock {
            for peerID in peerIDs {
                peerSightings[peerID] = now
            }
        }
    }

    // MARK: - Evaluation

    /// Start the periodic evaluation timer.
    public func startMonitoring() {
        evaluationTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.evaluationInterval,
            repeating: Self.evaluationInterval
        )
        timer.setEventHandler { [weak self] in
            self?.evaluate()
        }
        timer.resume()
        evaluationTimer = timer
    }

    /// Stop the evaluation timer.
    public func stopMonitoring() {
        evaluationTimer?.cancel()
        evaluationTimer = nil
    }

    /// Perform a crowd-scale evaluation.
    ///
    /// Counts unique peers in the window, applies EMA smoothing,
    /// and determines if a mode switch is warranted (with hysteresis).
    public func evaluate() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.peerCountWindow)

        lock.lock()

        // Prune old sightings outside the window.
        peerSightings = peerSightings.filter { $0.value >= windowStart }

        // Raw count of unique peers in the window.
        let rawCount = peerSightings.count
        rawPeerCount = rawCount

        // EMA smoothing: smoothed = alpha * raw + (1 - alpha) * previous.
        let alpha = Self.emaSmoothingFactor
        if smoothedPeerCount == 0 {
            smoothedPeerCount = Double(rawCount)
        } else {
            smoothedPeerCount = alpha * Double(rawCount) + (1.0 - alpha) * smoothedPeerCount
        }

        let targetMode = CrowdScaleMode.mode(forPeerCount: Int(smoothedPeerCount))
        let current = modePublisher.value

        if targetMode != current {
            // Check hysteresis: has this target mode been pending for long enough?
            if pendingMode == targetMode, let started = pendingModeStartedAt {
                if now.timeIntervalSince(started) >= Self.hysteresisDuration {
                    // Hysteresis met, switch mode.
                    lock.unlock()
                    logger.info("Crowd scale mode: \(current.rawValue) -> \(targetMode.rawValue) (peers: \(Int(self.smoothedPeerCount)))")
                    modePublisher.send(targetMode)
                    lock.lock()
                    pendingMode = nil
                    pendingModeStartedAt = nil
                }
            } else {
                // Start hysteresis timer for new pending mode.
                pendingMode = targetMode
                pendingModeStartedAt = now
            }
        } else {
            // Current mode matches, clear any pending switch.
            pendingMode = nil
            pendingModeStartedAt = nil
        }

        lock.unlock()
    }

    /// Force a mode change (bypasses hysteresis, for testing or emergency).
    public func forceMode(_ mode: CrowdScaleMode) {
        lock.withLock {
            pendingMode = nil
            pendingModeStartedAt = nil
        }
        modePublisher.send(mode)
    }

    /// Reset all state.
    public func reset() {
        lock.withLock {
            peerSightings.removeAll()
            smoothedPeerCount = 0
            rawPeerCount = 0
            pendingMode = nil
            pendingModeStartedAt = nil
        }
        modePublisher.send(.gather)
    }
}
