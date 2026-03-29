import Foundation
import BlipProtocol
import os.log

/// WebSocket relay transport for fallback connectivity (spec Section 5.10).
///
/// Connects to `wss://relay.blip.app/ws` and sends/receives the same
/// binary protocol packets used on BLE. The relay server is zero-knowledge:
/// it forwards packets without decrypting them.
///
/// Authentication: Noise static public key sent as bearer token.
/// Reconnection: exponential backoff from 1s to 60s, max 10 attempts.
public final class WebSocketTransport: NSObject, Transport, @unchecked Sendable {

    // MARK: - Constants

    /// WebSocket relay endpoint.
    public static let relayURL = URL(string: "wss://blip-relay.john-mckean.workers.dev/ws")!

    /// Minimum reconnect delay in seconds.
    public static let minReconnectDelay: TimeInterval = 1.0

    /// Maximum reconnect delay in seconds.
    public static let maxReconnectDelay: TimeInterval = 60.0

    /// Maximum number of reconnection attempts.
    public static let maxReconnectAttempts = 10

    // MARK: - Transport conformance

    public weak var delegate: (any TransportDelegate)?

    public private(set) var state: TransportState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.transport(self, didChangeState: state)
        }
    }

    public var connectedPeers: [PeerID] {
        // WebSocket relay doesn't expose individual peer connections.
        // The server is the single "peer" we're connected to.
        lock.withLock {
            isConnected ? [serverPeerID] : []
        }
    }

    // MARK: - Properties

    /// The Noise public key used for authentication.
    private let noisePublicKey: Data

    /// The local peer ID.
    public let localPeerID: PeerID

    /// Pseudo PeerID for the relay server.
    private let serverPeerID: PeerID

    /// The URL session for WebSocket connections.
    private var urlSession: URLSession!

    /// The active WebSocket task.
    private var webSocketTask: URLSessionWebSocketTask?

    /// Whether we are currently connected.
    private var isConnected = false

    /// Current reconnection delay (exponential backoff).
    private var currentReconnectDelay: TimeInterval = 1.0

    /// Number of reconnect attempts so far.
    private var reconnectAttempts = 0

    /// Whether auto-reconnect is enabled.
    private var autoReconnect = false

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.blip.websocket", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.blip", category: "WebSocket")

    // MARK: - Init

    /// Create a WebSocket transport.
    ///
    /// - Parameters:
    ///   - localPeerID: This device's PeerID.
    ///   - noisePublicKey: The Noise static public key for authentication.
    public init(localPeerID: PeerID, noisePublicKey: Data) {
        self.localPeerID = localPeerID
        self.noisePublicKey = noisePublicKey
        self.serverPeerID = PeerID(noisePublicKey: Data("relay.blip.app".utf8))

        super.init()

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - Transport lifecycle

    public func start() {
        guard state == .idle || state == .stopped else { return }
        autoReconnect = true
        connect()
    }

    public func stop() {
        autoReconnect = false
        disconnect()
        state = .stopped
    }

    public func send(data: Data, to peerID: PeerID) throws {
        guard state == .running else {
            throw TransportError.notStarted
        }

        guard let task = webSocketTask else {
            throw TransportError.unavailable("WebSocket not connected")
        }

        // Wrap as binary frame.
        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error = error {
                self?.logger.error("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    public func broadcast(data: Data) {
        guard state == .running, let task = webSocketTask else { return }

        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error = error {
                self?.logger.error("WebSocket broadcast error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Connection management

    private func connect() {
        state = .starting

        // Build the request with authentication header.
        var request = URLRequest(url: Self.relayURL)
        let token = noisePublicKey.base64EncodedString()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(localPeerID.description, forHTTPHeaderField: "X-Peer-ID")

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // Start receiving messages.
        receiveNextMessage()

        logger.info("WebSocket connecting to \(Self.relayURL)")
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        lock.withLock {
            isConnected = false
        }
    }

    private func handleConnectionEstablished() {
        lock.withLock {
            isConnected = true
            reconnectAttempts = 0
            currentReconnectDelay = Self.minReconnectDelay
        }

        state = .running
        delegate?.transport(self, didConnect: serverPeerID)
        logger.info("WebSocket connected")
    }

    private func handleConnectionLost(error: Error?) {
        let wasConnected: Bool = lock.withLock {
            let was = isConnected
            isConnected = false
            return was
        }

        if wasConnected {
            delegate?.transport(self, didDisconnect: serverPeerID)
        }

        if let error = error {
            logger.warning("WebSocket disconnected: \(error.localizedDescription)")
        }

        // Attempt reconnection with exponential backoff.
        if autoReconnect {
            scheduleReconnect()
        } else {
            state = .stopped
        }
    }

    private func scheduleReconnect() {
        let (delay, shouldRetry): (TimeInterval, Bool) = lock.withLock {
            reconnectAttempts += 1
            guard reconnectAttempts <= Self.maxReconnectAttempts else {
                return (0, false)
            }
            let d = currentReconnectDelay
            currentReconnectDelay = min(currentReconnectDelay * 2, Self.maxReconnectDelay)
            return (d, true)
        }

        guard shouldRetry else {
            logger.error("WebSocket max reconnect attempts reached")
            state = .failed("Max reconnect attempts reached")
            return
        }

        logger.info("WebSocket reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
        state = .starting

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.autoReconnect else { return }
            self.connect()
        }
    }

    // MARK: - Message receiving

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveNextMessage() // Continue receiving.

            case .failure(let error):
                self.handleConnectionLost(error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // First connection response confirms we're connected.
            let connected: Bool = lock.withLock { isConnected }
            if !connected {
                handleConnectionEstablished()
            }

            // Forward binary data to delegate.
            // The server may include a source peer ID in a header, but for now
            // we use the server pseudo-peer ID.
            delegate?.transport(self, didReceiveData: data, from: serverPeerID)

        case .string(let text):
            // The relay may send text control messages.
            if text == "connected" {
                handleConnectionEstablished()
            } else {
                logger.debug("WebSocket text message: \(text)")
            }

        @unknown default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketTransport: URLSessionWebSocketDelegate {

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        handleConnectionEstablished()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        logger.info("WebSocket closed: \(closeCode.rawValue) reason: \(reasonString ?? "none")")
        handleConnectionLost(error: nil)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            handleConnectionLost(error: error)
        }
    }
}
