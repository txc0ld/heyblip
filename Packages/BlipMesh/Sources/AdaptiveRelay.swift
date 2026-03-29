import Foundation
import BlipProtocol

/// Adaptive gossip relay probability calculator (spec Section 8.3).
///
/// Computes the probability of relaying a packet based on:
/// ```
/// P(relay) = base_probability x urgency_factor x freshness_factor x congestion_factor
/// ```
///
/// Capped at 1.0, floor at 0.05. SOS always 1.0 regardless.
///
/// Jitter: 8-25ms random delay per relay to prevent synchronized flooding.
public final class AdaptiveRelay: @unchecked Sendable {

    // MARK: - Configurable state

    /// The current number of directly connected peers.
    public var connectedPeerCount: Int {
        get { lock.withLock { _connectedPeerCount } }
        set { lock.withLock { _connectedPeerCount = newValue } }
    }
    private var _connectedPeerCount: Int = 0

    /// The current outbound queue fill ratio (0.0 to 1.0).
    public var queueFillRatio: Double {
        get { lock.withLock { _queueFillRatio } }
        set { lock.withLock { _queueFillRatio = max(0, min(1, newValue)) } }
    }
    private var _queueFillRatio: Double = 0.0

    private let lock = NSLock()

    // MARK: - Init

    public init() {}

    // MARK: - Relay decision

    /// Determine whether a packet should be relayed.
    ///
    /// - Parameter packet: The packet to evaluate.
    /// - Returns: `true` if the packet should be relayed.
    public func shouldRelay(packet: Packet) -> Bool {
        // SOS always relayed (spec 8.9 rule 2).
        if packet.type.isSOS { return true }

        let probability = relayProbability(for: packet)
        return Double.random(in: 0.0 ..< 1.0) < probability
    }

    /// Calculate the relay probability for a packet.
    ///
    /// ```
    /// P = base x urgency x freshness x congestion
    /// ```
    public func relayProbability(for packet: Packet) -> Double {
        // SOS override.
        if packet.type.isSOS { return 1.0 }

        let base = baseProbability()
        let urgency = urgencyFactor(for: packet.type)
        let freshness = freshnessFactor(for: packet.timestamp)
        let congestion = congestionFactor()

        let raw = base * urgency * freshness * congestion
        return min(1.0, max(0.05, raw))
    }

    // MARK: - Component calculations

    /// Base probability based on peer count (spec 8.3).
    ///
    /// - peers < 10:  1.0
    /// - 10-30:       0.7
    /// - 30-60:       0.4
    /// - > 60:        0.2
    public func baseProbability() -> Double {
        let count = lock.withLock { _connectedPeerCount }
        switch count {
        case ..<10:   return 1.0
        case 10..<30: return 0.7
        case 30..<60: return 0.4
        default:      return 0.2
        }
    }

    /// Urgency factor based on message type (spec 8.3).
    ///
    /// - SOS:            3.0
    /// - Announcements:  2.0
    /// - DMs:            1.0
    /// - Broadcasts:     0.5
    public func urgencyFactor(for type: MessageType) -> Double {
        if type.isSOS { return 3.0 }

        switch type {
        case .orgAnnouncement:
            return 2.0
        case .noiseEncrypted, .noiseHandshake:
            return 1.0 // Likely DMs or handshakes.
        case .meshBroadcast, .channelUpdate:
            return 0.5
        case .announce, .leave:
            return 1.0
        case .syncRequest:
            return 0.3
        case .fragment:
            return 0.8
        case .fileTransfer, .pttAudio:
            return 0.3
        case .locationShare, .locationRequest, .proximityPing, .iAmHereBeacon:
            return 0.5
        default:
            return 1.0
        }
    }

    /// Freshness factor based on packet age (spec 8.3).
    ///
    /// - < 5s:   1.0
    /// - 5-30s:  0.5
    /// - > 30s:  0.1
    public func freshnessFactor(for timestamp: UInt64) -> Double {
        let packetTime = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let age = Date().timeIntervalSince(packetTime)

        switch age {
        case ..<5.0:   return 1.0
        case 5.0..<30: return 0.5
        default:       return 0.1
        }
    }

    /// Congestion factor based on outbound queue fill (spec 8.3).
    ///
    /// - queue < 50%:  1.0
    /// - 50-80%:       0.5
    /// - > 80%:        0.2
    public func congestionFactor() -> Double {
        let fill = lock.withLock { _queueFillRatio }

        switch fill {
        case ..<0.5:    return 1.0
        case 0.5..<0.8: return 0.5
        default:        return 0.2
        }
    }

    // MARK: - Jitter

    /// Calculate a random jitter delay for relay (spec: 8-25ms).
    ///
    /// - Returns: Jitter delay in seconds.
    public func jitterDelay() -> TimeInterval {
        Double.random(
            in: BLEConstants.relayJitterMin ... BLEConstants.relayJitterMax
        )
    }
}
