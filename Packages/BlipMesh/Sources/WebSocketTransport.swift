import Foundation
import CryptoKit
import BlipProtocol
import os.log
import Security

/// WebSocket relay transport for fallback connectivity (spec Section 5.10).
///
/// Connects to `wss://relay.blip.app/ws` and sends/receives the same
/// binary protocol packets used on BLE. The relay server is zero-knowledge:
/// it forwards packets without decrypting them.
///
/// Authentication: caller-provided bearer token, typically a short-lived JWT.
/// Reconnection: exponential backoff from 1s to 60s, max 10 attempts.
public final class WebSocketTransport: NSObject, Transport, @unchecked Sendable {

    // MARK: - Constants

    /// Default WebSocket relay endpoint. Override via init parameter.
    public static let defaultRelayURL: URL = {
        guard let url = URL(string: "wss://blip-relay.john-mckean.workers.dev/ws") else {
            fatalError("Invalid default relay URL")
        }
        return url
    }()

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

    /// The relay URL for this instance.
    private let relayURL: URL

    /// SPKI hashes accepted for relay TLS pinning.
    private let pinnedCertHashes: Set<String>

    /// Domains that require relay TLS pinning.
    private let pinnedDomains: Set<String>

    /// Produces the bearer token used for relay authentication.
    private let tokenProvider: @Sendable () async throws -> String

    /// Refreshes the bearer token after an auth failure.
    private let tokenRefreshHandler: (@Sendable () async throws -> Void)?

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
    ///   - pinnedCertHashes: SPKI hashes accepted for TLS pinning.
    ///   - pinnedDomains: Domains that require TLS pinning.
    ///   - tokenProvider: Produces the bearer token used for authentication.
    ///   - tokenRefreshHandler: Refreshes the token after an auth failure.
    ///   - relayURL: WebSocket relay endpoint. Defaults to `defaultRelayURL`.
    public init(
        localPeerID: PeerID,
        pinnedCertHashes: Set<String>,
        pinnedDomains: Set<String>,
        tokenProvider: @escaping @Sendable () async throws -> String,
        tokenRefreshHandler: (@Sendable () async throws -> Void)? = nil,
        relayURL: URL? = nil
    ) {
        self.localPeerID = localPeerID
        self.pinnedCertHashes = pinnedCertHashes
        self.pinnedDomains = pinnedDomains
        self.tokenProvider = tokenProvider
        self.tokenRefreshHandler = tokenRefreshHandler
        self.relayURL = relayURL ?? Self.defaultRelayURL
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
        Task { [weak self] in
            guard let self else { return }

            do {
                let token = try await self.tokenProvider()
                self.openWebSocket(using: token)
            } catch {
                self.logger.error("WebSocket auth token unavailable: \(error.localizedDescription)")
                if self.autoReconnect {
                    self.scheduleReconnect()
                } else {
                    self.state = .failed("Authentication failed")
                }
            }
        }
    }

    private func openWebSocket(using token: String) {
        guard autoReconnect || state == .starting else { return }

        var request = URLRequest(url: self.relayURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(localPeerID.description, forHTTPHeaderField: "X-Peer-ID")

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveNextMessage()
        logger.info("WebSocket connecting to \(self.relayURL)")
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

    private func handleExpiredToken() {
        logger.info("WebSocket token expired, requesting refresh")

        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.tokenRefreshHandler?()
            } catch {
                self.logger.error("WebSocket token refresh failed: \(error.localizedDescription)")
            }

            self.lock.withLock {
                self.reconnectAttempts = 0
                self.currentReconnectDelay = Self.minReconnectDelay
                self.isConnected = false
            }

            guard self.autoReconnect else {
                self.state = .stopped
                return
            }

            self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.autoReconnect else { return }
                self.connect()
            }
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

            // Extract the actual sender PeerID from the packet header (bytes 16-23).
            // This ensures handshake sessions, sender binding, and response routing
            // use the real peer identity rather than the relay pseudo-peer.
            let senderPeerID: PeerID
            if data.count >= 24,
               let extracted = PeerID(bytes: Data(data[16 ..< 24])) {
                senderPeerID = extracted
            } else {
                senderPeerID = serverPeerID
            }
            delegate?.transport(self, didReceiveData: data, from: senderPeerID)

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

private enum WebSocketCertificatePinning {
    private static let rsaAlgorithmIdentifier = Data([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00
    ])

    private static let ecP256AlgorithmIdentifier = Data([
        0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07
    ])

    private static let ecP384AlgorithmIdentifier = Data([
        0x30, 0x10,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22
    ])

    private static let ecP521AlgorithmIdentifier = Data([
        0x30, 0x10,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23
    ])

    static func certificateHash(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let publicKey = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let subjectPublicKeyInfo = subjectPublicKeyInfo(for: key, publicKey: publicKey) else {
            return nil
        }

        let digest = SHA256.hash(data: subjectPublicKeyInfo)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func subjectPublicKeyInfo(for key: SecKey, publicKey: Data) -> Data? {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String else {
            return nil
        }

        let keySizeInBits = attributes[kSecAttrKeySizeInBits] as? Int ?? (publicKey.count * 8)

        let algorithmIdentifier: Data
        if keyType == (kSecAttrKeyTypeRSA as String) {
            algorithmIdentifier = rsaAlgorithmIdentifier
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            switch keySizeInBits {
            case 256:
                algorithmIdentifier = ecP256AlgorithmIdentifier
            case 384:
                algorithmIdentifier = ecP384AlgorithmIdentifier
            case 521:
                algorithmIdentifier = ecP521AlgorithmIdentifier
            default:
                return nil
            }
        } else {
            return nil
        }

        return derSequence([algorithmIdentifier, derBitString(publicKey)])
    }

    private static func derSequence(_ components: [Data]) -> Data {
        let payload = components.reduce(into: Data()) { result, component in
            result.append(component)
        }
        return derTagged(0x30, payload)
    }

    private static func derBitString(_ data: Data) -> Data {
        var payload = Data([0x00])
        payload.append(data)
        return derTagged(0x03, payload)
    }

    private static func derTagged(_ tag: UInt8, _ payload: Data) -> Data {
        var data = Data([tag])
        data.append(derLength(payload.count))
        data.append(payload)
        return data
    }

    private static func derLength(_ length: Int) -> Data {
        guard length >= 0 else { return Data() }

        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }

        var data = Data([0x80 | UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        return data
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              pinnedDomains.contains(challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            logger.error(
                "TLS trust evaluation failed for \(challenge.protectionSpace.host, privacy: .public): \(error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        for certificate in certificates {
            guard let hash = WebSocketCertificatePinning.certificateHash(for: certificate) else {
                continue
            }

            if pinnedCertHashes.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        logger.error("Certificate pinning failed for \(challenge.protectionSpace.host, privacy: .public)")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

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
        if closeCode.rawValue == 4001 {
            handleExpiredToken()
            return
        }
        handleConnectionLost(error: nil)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let response = task.response as? HTTPURLResponse, response.statusCode == 401 {
            handleExpiredToken()
            return
        }

        if let error = error {
            handleConnectionLost(error: error)
        }
    }
}
