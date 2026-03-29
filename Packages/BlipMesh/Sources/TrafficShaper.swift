import Foundation
import BlipProtocol
import os.log

// MARK: - Traffic lane

/// Priority lanes for the traffic shaper (spec Section 8.6).
public enum TrafficLane: Int, Sendable, Comparable, CaseIterable {
    /// Lane 0: SOS, medical emergency -- always first.
    case critical = 0
    /// Lane 1: DMs, friend requests -- 60% of remaining bandwidth.
    case high = 1
    /// Lane 2: Groups, channels -- 30%.
    case normal = 2
    /// Lane 3: Sync, profiles -- 10%.
    case low = 3

    public static func < (lhs: TrafficLane, rhs: TrafficLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Bandwidth share for this lane (as a fraction of remaining bandwidth after critical).
    public var bandwidthShare: Double {
        switch self {
        case .critical: return 1.0 // Gets all it needs.
        case .high:     return 0.6
        case .normal:   return 0.3
        case .low:      return 0.1
        }
    }

    /// Determine the traffic lane for a packet.
    public static func lane(for packet: Packet) -> TrafficLane {
        if packet.type.isSOS { return .critical }

        switch packet.type {
        case .orgAnnouncement:
            return packet.flags.contains(.isPriority) ? .critical : .high
        case .noiseEncrypted:
            return packet.flags.contains(.hasRecipient) ? .high : .normal
        case .noiseHandshake:
            return .high
        case .meshBroadcast, .channelUpdate:
            return .normal
        case .announce, .leave:
            return .normal
        case .syncRequest:
            return .low
        case .fragment:
            return .normal
        case .fileTransfer, .pttAudio:
            return .low
        case .locationShare, .locationRequest, .proximityPing, .iAmHereBeacon:
            return .normal
        default:
            return .normal
        }
    }
}

// MARK: - Queued packet

/// A packet waiting in the traffic shaper queue.
struct QueuedPacket: Sendable {
    let packet: Packet
    let lane: TrafficLane
    let enqueuedAt: Date
    let targetPeer: PeerID? // nil for broadcast
}

// MARK: - TrafficShaper

/// 4-lane priority queue with rate limiting and backpressure (spec Section 8.6).
///
/// - Lane 0 (Critical): SOS, emergency -- always first.
/// - Lane 1 (High): DMs, friend requests -- 60% of remaining bandwidth.
/// - Lane 2 (Normal): Groups, channels -- 30%.
/// - Lane 3 (Low): Sync, profiles -- 10%.
///
/// Rate limiting: 20 packets/s inbound per peer, 15 packets/s outbound.
/// Burst: 2x for 3 seconds.
/// Backpressure: queue > 80% stops relay traffic; queue > 95% drops Lane 3 entirely.
public final class TrafficShaper: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum inbound packets per second per peer.
    public static let maxInboundPPS: Double = 20.0

    /// Maximum outbound packets per second.
    public static let maxOutboundPPS: Double = 15.0

    /// Burst multiplier.
    public static let burstMultiplier: Double = 2.0

    /// Burst duration in seconds.
    public static let burstDuration: TimeInterval = 3.0

    /// Maximum total queue capacity (number of packets across all lanes).
    public static let maxQueueCapacity = 500

    /// Backpressure threshold: relay traffic stops at this fill level.
    public static let relayBackpressureThreshold: Double = 0.80

    /// Backpressure threshold: Lane 3 dropped entirely at this fill level.
    public static let lane3DropThreshold: Double = 0.95

    // MARK: - Queues

    /// Per-lane packet queues.
    private var lanes: [TrafficLane: [QueuedPacket]] = [
        .critical: [],
        .high: [],
        .normal: [],
        .low: [],
    ]

    // MARK: - Rate limiting

    /// Per-peer inbound packet timestamps for rate limiting.
    private var inboundTimestamps: [PeerID: [Date]] = [:]

    /// Outbound packet timestamps for rate limiting.
    private var outboundTimestamps: [Date] = []

    /// When burst mode was last activated.
    private var burstStartedAt: Date?

    // MARK: - Metrics

    /// Total packets enqueued.
    public private(set) var totalEnqueued: UInt64 = 0

    /// Total packets dequeued and sent.
    public private(set) var totalDequeued: UInt64 = 0

    /// Total packets dropped due to rate limiting or backpressure.
    public private(set) var totalDropped: UInt64 = 0

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.blip", category: "TrafficShaper")

    /// Callback invoked when a packet is ready to be sent.
    public var onSend: ((Packet, PeerID?) -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - Queue status

    /// Total number of packets in all queues.
    public var totalQueuedCount: Int {
        lock.withLock {
            lanes.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Queue fill ratio (0.0 to 1.0).
    public var queueFillRatio: Double {
        Double(totalQueuedCount) / Double(Self.maxQueueCapacity)
    }

    /// Whether relay traffic should be stopped due to backpressure.
    public var isRelayBackpressured: Bool {
        queueFillRatio >= Self.relayBackpressureThreshold
    }

    /// Whether Lane 3 (low priority) is dropped due to backpressure.
    public var isLane3Dropped: Bool {
        queueFillRatio >= Self.lane3DropThreshold
    }

    // MARK: - Inbound rate limiting

    /// Check if an inbound packet from a peer should be accepted or rate-limited.
    ///
    /// - Parameters:
    ///   - peerID: The sending peer.
    ///   - packet: The packet to check.
    /// - Returns: `true` if accepted, `false` if rate-limited.
    public func acceptInbound(from peerID: PeerID, packet: Packet) -> Bool {
        // SOS is never rate-limited.
        if packet.type.isSOS { return true }

        let now = Date()
        let maxPPS = currentInboundLimit()

        lock.lock()

        // Clean old timestamps (keep last 1 second).
        let cutoff = now.addingTimeInterval(-1.0)
        var timestamps = inboundTimestamps[peerID] ?? []
        timestamps.removeAll { $0 < cutoff }

        if Double(timestamps.count) >= maxPPS {
            totalDropped += 1
            lock.unlock()
            logger.debug("Inbound rate limited from \(peerID)")
            return false
        }

        timestamps.append(now)
        inboundTimestamps[peerID] = timestamps
        lock.unlock()

        return true
    }

    // MARK: - Enqueue

    /// Enqueue a packet for outbound sending.
    ///
    /// - Parameters:
    ///   - packet: The packet to send.
    ///   - targetPeer: The destination peer, or `nil` for broadcast.
    /// - Returns: `true` if enqueued, `false` if dropped.
    @discardableResult
    public func enqueue(packet: Packet, targetPeer: PeerID? = nil) -> Bool {
        let lane = TrafficLane.lane(for: packet)

        // Backpressure: drop Lane 3 at 95% fill.
        if lane == .low && isLane3Dropped {
            lock.lock()
            totalDropped += 1
            lock.unlock()
            logger.debug("Lane 3 packet dropped (backpressure)")
            return false
        }

        lock.lock()

        // Check total queue capacity.
        let total = lanes.values.reduce(0) { $0 + $1.count }
        if total >= Self.maxQueueCapacity && lane != .critical {
            totalDropped += 1
            lock.unlock()
            logger.debug("Queue full, packet dropped (lane \(lane.rawValue))")
            return false
        }

        let queued = QueuedPacket(
            packet: packet,
            lane: lane,
            enqueuedAt: Date(),
            targetPeer: targetPeer
        )

        lanes[lane, default: []].append(queued)
        totalEnqueued += 1
        lock.unlock()

        return true
    }

    // MARK: - Dequeue

    /// Dequeue the next packet to send, respecting priority lanes and rate limits.
    ///
    /// Returns `nil` if no packets are ready (queue empty or rate-limited).
    public func dequeue() -> (packet: Packet, targetPeer: PeerID?)? {
        let now = Date()

        lock.lock()

        // Check outbound rate limit.
        let maxPPS = currentOutboundLimit()
        let cutoff = now.addingTimeInterval(-1.0)
        outboundTimestamps.removeAll { $0 < cutoff }

        if Double(outboundTimestamps.count) >= maxPPS {
            // Check if critical lane has packets (SOS bypasses rate limits).
            if let critical = lanes[.critical], !critical.isEmpty {
                let queued = lanes[.critical]!.removeFirst()
                totalDequeued += 1
                outboundTimestamps.append(now)
                lock.unlock()
                return (queued.packet, queued.targetPeer)
            }
            lock.unlock()
            return nil
        }

        // Dequeue by priority: critical first, then high, normal, low.
        for lane in TrafficLane.allCases {
            if var queue = lanes[lane], !queue.isEmpty {
                let queued = queue.removeFirst()
                lanes[lane] = queue
                totalDequeued += 1
                outboundTimestamps.append(now)
                lock.unlock()
                return (queued.packet, queued.targetPeer)
            }
        }

        lock.unlock()
        return nil
    }

    /// Drain the queue by sending all ready packets via the `onSend` callback.
    ///
    /// Sends up to `maxBatch` packets per call.
    public func drainQueue(maxBatch: Int = 10) {
        var sent = 0
        while sent < maxBatch, let item = dequeue() {
            onSend?(item.packet, item.targetPeer)
            sent += 1
        }
    }

    // MARK: - Burst mode

    /// Activate burst mode (2x rate for 3 seconds).
    public func activateBurst() {
        lock.withLock {
            burstStartedAt = Date()
        }
    }

    /// Whether burst mode is currently active.
    public var isBurstActive: Bool {
        lock.withLock {
            guard let start = burstStartedAt else { return false }
            return Date().timeIntervalSince(start) < Self.burstDuration
        }
    }

    // MARK: - Rate limit helpers

    private func currentInboundLimit() -> Double {
        let base = Self.maxInboundPPS
        return isBurstActive ? base * Self.burstMultiplier : base
    }

    private func currentOutboundLimit() -> Double {
        let base = Self.maxOutboundPPS
        return isBurstActive ? base * Self.burstMultiplier : base
    }

    // MARK: - Cleanup

    /// Clear all queues and reset metrics.
    public func reset() {
        lock.withLock {
            for lane in TrafficLane.allCases {
                lanes[lane] = []
            }
            inboundTimestamps.removeAll()
            outboundTimestamps.removeAll()
            burstStartedAt = nil
            totalEnqueued = 0
            totalDequeued = 0
            totalDropped = 0
        }
    }

    /// Clean up stale rate-limiting data for disconnected peers.
    public func cleanupPeer(_ peerID: PeerID) {
        lock.lock()
        inboundTimestamps.removeValue(forKey: peerID)
        lock.unlock()
    }
}
