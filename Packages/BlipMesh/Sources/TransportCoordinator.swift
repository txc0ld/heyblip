import Foundation
import Combine
import BlipProtocol
import os.log

// MARK: - Connectivity state

/// The current connectivity state of the transport coordinator.
public enum ConnectivityState: Sendable, Equatable {
    /// No transports are active.
    case disconnected
    /// BLE mesh is active.
    case meshOnly
    /// WebSocket relay is active.
    case webSocketOnly
    /// Both BLE mesh and WebSocket are active.
    case meshAndWebSocket
}

// MARK: - TransportCoordinator

/// Owns all transports and routes messages through the best available path
/// (spec Section 5.10).
///
/// Transport priority:
/// 1. BLE mesh (always attempted first, 100ms timeout)
/// 2. WebSocket relay (if BLE has no path and internet available)
/// 3. Notify via `onSendFailed` (app layer persists to SwiftData for retry)
///
/// Publishes transport state via Combine for the UI layer.
public final class TransportCoordinator: @unchecked Sendable, Transport {

    // MARK: - Constants

    /// Timeout for BLE send attempt before falling back to WebSocket.
    public static let bleSendTimeout: TimeInterval = 0.1 // 100ms

    // MARK: - Transports

    /// The BLE mesh transport.
    public let bleTransport: BLEService

    /// The WebSocket relay transport.
    public let webSocketTransport: WebSocketTransport

    /// The WiFi Direct transport (v2 stub).
    public let wifiTransport: WiFiTransport

    // MARK: - Callbacks

    /// Called when a send fails and no transport is available.
    /// The app layer uses this to trigger SwiftData-backed retry via MessageRetryService.
    public var onSendFailed: ((Data, PeerID?) -> Void)?

    // MARK: - Published state

    /// Current connectivity state, published via Combine.
    public let connectivityPublisher: CurrentValueSubject<ConnectivityState, Never>

    /// Current connectivity state.
    public var connectivity: ConnectivityState {
        connectivityPublisher.value
    }

    /// Derived transport state based on whether any transport is running.
    public var state: TransportState {
        if bleTransport.state == .running || webSocketTransport.state == .running {
            return .running
        }
        if bleTransport.state == .starting || webSocketTransport.state == .starting {
            return .starting
        }
        return .idle
    }

    // MARK: - Location rate limiting

    /// Last location broadcast time per peer, for rate limiting (max 1/30s).
    private var lastLocationBroadcast: [PeerID: Date] = [:]

    // MARK: - Internals

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.blip.coordinator", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.blip", category: "TransportCoordinator")

    /// Delegate to forward received data.
    public weak var delegate: (any TransportDelegate)?

    // MARK: - Init

    /// Create a transport coordinator with the given transports.
    ///
    /// - Parameters:
    ///   - bleTransport: The BLE mesh transport.
    ///   - webSocketTransport: The WebSocket relay transport.
    ///   - wifiTransport: The WiFi Direct transport (v2 stub).
    public init(
        bleTransport: BLEService,
        webSocketTransport: WebSocketTransport,
        wifiTransport: WiFiTransport = WiFiTransport()
    ) {
        self.bleTransport = bleTransport
        self.webSocketTransport = webSocketTransport
        self.wifiTransport = wifiTransport
        self.connectivityPublisher = CurrentValueSubject(.disconnected)

        bleTransport.delegate = self
        webSocketTransport.delegate = self
    }

    // MARK: - Lifecycle

    /// Start all transports.
    public func start() {
        bleTransport.start()
        webSocketTransport.start()

        updateConnectivityState()
    }

    /// Stop all transports.
    public func stop() {
        bleTransport.stop()
        webSocketTransport.stop()

        connectivityPublisher.send(.disconnected)
    }

    // MARK: - Sending

    /// Send data to a specific peer using the best available transport.
    ///
    /// Tries BLE first, then WebSocket. If both fail, calls `onSendFailed`.
    ///
    /// - Parameters:
    ///   - data: The binary data to send.
    ///   - peerID: The destination peer.
    public func send(data: Data, to peerID: PeerID) {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        // Try BLE first.
        if bleTransport.state == .running {
            do {
                try bleTransport.send(data: data, to: peerID)
                return
            } catch {
                logger.debug("BLE send failed for \(peerHex), trying WebSocket: \(error.localizedDescription)")
            }
        }

        // Try WebSocket.
        if webSocketTransport.state == .running {
            do {
                try webSocketTransport.send(data: data, to: peerID)
                bleTransport.transportEventHandler?("RELAY", "SENT \(data.count)B → \(peerHex) via WebSocket relay")
                return
            } catch {
                logger.debug("WebSocket send failed for \(peerHex), queueing: \(error.localizedDescription)")
            }
        }

        // Notify app layer so SwiftData-backed retry can handle persistence.
        bleTransport.transportEventHandler?("TX", "SEND FAILED \(data.count)B → \(peerHex) (no transport available)")
        onSendFailed?(data, peerID)
    }

    /// Broadcast data to all connected peers across all transports.
    ///
    /// - Parameter data: The binary data to broadcast.
    public func broadcast(data: Data) {
        if bleTransport.state == .running {
            bleTransport.broadcast(data: data)
        }
        if webSocketTransport.state == .running {
            webSocketTransport.broadcast(data: data)
        }
    }

    /// Broadcast data to all connected peers except the specified one.
    ///
    /// Used by gossip relay to forward packets without sending back to the source.
    ///
    /// - Parameters:
    ///   - data: The binary data to broadcast.
    ///   - excludedPeer: The peer to exclude (typically the original sender).
    public func broadcastExcluding(data: Data, excludedPeer: PeerID) {
        let peers = connectedPeers.filter { $0 != excludedPeer }
        for peer in peers {
            do {
                try bleTransport.send(data: data, to: peer)
            } catch {
                // BLE send failed for this peer — try WebSocket fallback.
                do {
                    try webSocketTransport.send(data: data, to: peer)
                } catch {
                    logger.debug("Relay send failed to \(peer): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - K-of-N Relay

    /// Relay data to a K-of-N subset of connected peers, excluding the source.
    ///
    /// K is determined by `fanoutCount(totalPeers:)` — small meshes relay to all,
    /// larger meshes select a subset to reduce bandwidth while maintaining coverage.
    ///
    /// Peers are selected deterministically using a seed derived from the packet data
    /// so that the same message picks the same subset on retransmission.
    public func relayToSubset(data: Data, excludedPeer: PeerID, seed: UInt64) {
        let eligible = connectedPeers.filter { $0 != excludedPeer }
        guard !eligible.isEmpty else { return }

        let k = fanoutCount(totalPeers: eligible.count)
        let selected = deterministicSelect(from: eligible, count: k, seed: seed)

        for peer in selected {
            do {
                try bleTransport.send(data: data, to: peer)
            } catch {
                do {
                    try webSocketTransport.send(data: data, to: peer)
                } catch {
                    logger.debug("Relay send failed to \(peer): \(error.localizedDescription)")
                }
            }
        }
    }

    /// How many peers to relay to, given the total eligible count.
    public func fanoutCount(totalPeers: Int) -> Int {
        switch totalPeers {
        case ...3:    return totalPeers
        case 4...10:  return 3
        case 11...30: return max(3, totalPeers / 3)
        case 31...60: return max(3, totalPeers / 5)
        default:      return max(3, totalPeers / 8)
        }
    }

    /// Select `count` peers deterministically using a seeded Fisher-Yates shuffle.
    private func deterministicSelect(from peers: [PeerID], count: Int, seed: UInt64) -> [PeerID] {
        guard count < peers.count else { return peers }

        var array = peers
        var rng = seed
        for i in 0..<count {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            let j = i + Int(rng % UInt64(array.count - i))
            array.swapAt(i, j)
        }
        return Array(array.prefix(count))
    }

    /// Send a location update, rate-limited to 1 per 30 seconds per peer.
    /// Returns `false` if rate limited (caller should skip this update).
    public func sendLocationUpdate(data: Data, to peerID: PeerID) -> Bool {
        let now = Date()
        let allowed: Bool = lock.withLock {
            if let last = lastLocationBroadcast[peerID],
               now.timeIntervalSince(last) < LocationPayload.updateInterval {
                return false
            }
            lastLocationBroadcast[peerID] = now
            return true
        }

        guard allowed else {
            logger.debug("Location update to \(peerID) rate limited")
            return false
        }

        send(data: data, to: peerID)
        return true
    }

    /// Broadcast a location update to all peers, rate-limited.
    public func broadcastLocationUpdate(data: Data, localPeerID: PeerID) -> Bool {
        let now = Date()
        let allowed: Bool = lock.withLock {
            if let last = lastLocationBroadcast[localPeerID],
               now.timeIntervalSince(last) < LocationPayload.updateInterval {
                return false
            }
            lastLocationBroadcast[localPeerID] = now
            return true
        }

        guard allowed else {
            logger.debug("Location broadcast rate limited")
            return false
        }

        broadcast(data: data)
        return true
    }

    /// All connected peers across all transports.
    public var connectedPeers: [PeerID] {
        var peers = Set<PeerID>()
        peers.formUnion(bleTransport.connectedPeers)
        peers.formUnion(webSocketTransport.connectedPeers)
        return Array(peers)
    }

    // MARK: - State tracking

    private func updateConnectivityState() {
        let bleRunning = bleTransport.state == .running
        let wsRunning = webSocketTransport.state == .running

        let newState: ConnectivityState
        switch (bleRunning, wsRunning) {
        case (true, true):   newState = .meshAndWebSocket
        case (true, false):  newState = .meshOnly
        case (false, true):  newState = .webSocketOnly
        case (false, false): newState = .disconnected
        }

        if newState != connectivityPublisher.value {
            connectivityPublisher.send(newState)
        }
    }

}

// MARK: - TransportDelegate

extension TransportCoordinator: TransportDelegate {

    public func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID) {
        delegate?.transport(transport, didReceiveData: data, from: peerID)
    }

    public func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        updateConnectivityState()
        delegate?.transport(transport, didConnect: peerID)
    }

    public func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        updateConnectivityState()
        delegate?.transport(transport, didDisconnect: peerID)
    }

    public func transport(_ transport: any Transport, didChangeState state: TransportState) {
        updateConnectivityState()
        delegate?.transport(transport, didChangeState: state)
    }
}
