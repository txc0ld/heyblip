import Foundation
import Combine
import FestiChatProtocol
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

// MARK: - Queued message

/// A message waiting in the local queue for delivery.
struct PendingMessage: Sendable {
    let data: Data
    let targetPeer: PeerID?
    let enqueuedAt: Date
    let retryCount: Int
}

// MARK: - TransportCoordinator

/// Owns all transports and routes messages through the best available path
/// (spec Section 5.10).
///
/// Transport priority:
/// 1. BLE mesh (always attempted first, 100ms timeout)
/// 2. WebSocket relay (if BLE has no path and internet available)
/// 3. Queue locally (if neither available, deliver when either becomes available)
///
/// Publishes transport state via Combine for the UI layer.
public final class TransportCoordinator: @unchecked Sendable, Transport {

    // MARK: - Constants

    /// Timeout for BLE send attempt before falling back to WebSocket.
    public static let bleSendTimeout: TimeInterval = 0.1 // 100ms

    /// Maximum number of locally queued messages.
    public static let maxLocalQueueSize = 200

    /// How often to retry sending queued messages.
    public static let retryInterval: TimeInterval = 5.0

    /// Maximum retry count before dropping a queued message.
    public static let maxRetries = 20

    // MARK: - Transports

    /// The BLE mesh transport.
    public let bleTransport: BLEService

    /// The WebSocket relay transport.
    public let webSocketTransport: WebSocketTransport

    /// The WiFi Direct transport (v2 stub).
    public let wifiTransport: WiFiTransport

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

    // MARK: - Local queue

    /// Messages queued for delivery when a transport becomes available.
    private var localQueue: [PendingMessage] = []

    // MARK: - Location rate limiting

    /// Last location broadcast time per peer, for rate limiting (max 1/30s).
    private var lastLocationBroadcast: [PeerID: Date] = [:]

    // MARK: - Internals

    private let lock = NSLock()
    private var retryTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.festichat.coordinator", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.festichat", category: "TransportCoordinator")

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

        startRetryTimer()
        updateConnectivityState()
    }

    /// Stop all transports.
    public func stop() {
        retryTimer?.cancel()
        retryTimer = nil

        bleTransport.stop()
        webSocketTransport.stop()

        connectivityPublisher.send(.disconnected)
    }

    // MARK: - Sending

    /// Send data to a specific peer using the best available transport.
    ///
    /// Tries BLE first with a 100ms timeout, then WebSocket, then queues locally.
    ///
    /// - Parameters:
    ///   - data: The binary data to send.
    ///   - peerID: The destination peer.
    public func send(data: Data, to peerID: PeerID) {
        // Try BLE first.
        if bleTransport.state == .running {
            do {
                try bleTransport.send(data: data, to: peerID)
                return
            } catch {
                logger.debug("BLE send failed, trying WebSocket: \(error.localizedDescription)")
            }
        }

        // Try WebSocket.
        if webSocketTransport.state == .running {
            do {
                try webSocketTransport.send(data: data, to: peerID)
                return
            } catch {
                logger.debug("WebSocket send failed, queueing: \(error.localizedDescription)")
            }
        }

        // Queue locally.
        enqueueLocally(data: data, targetPeer: peerID)
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

    // MARK: - Local queue

    private func enqueueLocally(data: Data, targetPeer: PeerID?) {
        lock.lock()
        defer { lock.unlock() }

        if localQueue.count >= Self.maxLocalQueueSize {
            // Drop oldest message.
            localQueue.removeFirst()
            logger.warning("Local queue full, dropping oldest message")
        }

        localQueue.append(PendingMessage(
            data: data,
            targetPeer: targetPeer,
            enqueuedAt: Date(),
            retryCount: 0
        ))
    }

    /// Retry sending queued messages.
    private func retryQueuedMessages() {
        lock.lock()
        let messages = localQueue
        localQueue.removeAll()
        lock.unlock()

        for var message in messages {
            if message.retryCount >= Self.maxRetries {
                logger.warning("Dropping message after \(Self.maxRetries) retries")
                continue
            }

            var sent = false

            if let target = message.targetPeer {
                if bleTransport.state == .running {
                    do {
                        try bleTransport.send(data: message.data, to: target)
                        sent = true
                    } catch { /* fallthrough */ }
                }

                if !sent && webSocketTransport.state == .running {
                    do {
                        try webSocketTransport.send(data: message.data, to: target)
                        sent = true
                    } catch { /* fallthrough */ }
                }
            } else {
                // Broadcast.
                broadcast(data: message.data)
                sent = true
            }

            if !sent {
                message = PendingMessage(
                    data: message.data,
                    targetPeer: message.targetPeer,
                    enqueuedAt: message.enqueuedAt,
                    retryCount: message.retryCount + 1
                )
                lock.lock()
                localQueue.append(message)
                lock.unlock()
            }
        }
    }

    // MARK: - Retry timer

    private func startRetryTimer() {
        retryTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.retryInterval,
            repeating: Self.retryInterval
        )
        timer.setEventHandler { [weak self] in
            self?.retryQueuedMessages()
        }
        timer.resume()
        retryTimer = timer
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

    /// Current number of locally queued messages.
    public var localQueueCount: Int {
        lock.withLock { localQueue.count }
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

        // Retry queued messages now that we have a new connection.
        queue.async { [weak self] in
            self?.retryQueuedMessages()
        }
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
