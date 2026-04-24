import Foundation
import Network
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

    /// Relay keep-alive interval.
    private static let pingInterval: TimeInterval = 20.0

    // MARK: - Transport conformance

    public weak var delegate: (any TransportDelegate)?

    /// The transport's current operational state.
    ///
    /// Reads acquire `lock` and return the authoritative `_state`. This matters
    /// in practice: `WebSocketTransport` writes state from URLSession's delegate
    /// queue, the path-monitor queue, and Tasks spun up from `connect()`, while
    /// the foreground handler and `TransportCoordinator` read it from the main
    /// thread. Prior to serializing access, a stale read from another thread
    /// could cause the foreground handler to see `.starting` while the transport
    /// was actually `.running` (HEY1304).
    public var state: TransportState {
        lock.withLock { _state }
    }

    /// Lock-protected backing store for `state`. Never mutate directly — go
    /// through `setState(_:)` so cross-thread readers see a coherent value and
    /// the delegate is notified exactly once per real transition.
    private var _state: TransportState = .idle

    private func setState(_ newState: TransportState) {
        let didChange: Bool = lock.withLock {
            guard _state != newState else { return false }
            _state = newState
            return true
        }
        if didChange {
            delegate?.transport(self, didChangeState: newState)
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

    /// Keep-alive timer for the active WebSocket task.
    private var pingTimer: DispatchSourceTimer?

    /// Whether we are currently connected.
    private var isConnected = false

    /// Current reconnection delay (exponential backoff).
    private var currentReconnectDelay: TimeInterval = 1.0

    /// Number of reconnect attempts so far.
    private var reconnectAttempts = 0

    /// Whether auto-reconnect is enabled.
    private var autoReconnect = false

    /// Monotonic counter incremented each time a new WebSocket task is created.
    /// Used to detect and silently drop stale receive callbacks from old tasks.
    private var taskGeneration: UInt64 = 0

    /// Whether a reconnection is currently scheduled. Prevents duplicate
    /// reconnections when both didCloseWith and receiveNextMessage fire.
    private var isReconnectScheduled = false

    /// True from the moment a reconnect cycle is claimed until the transport
    /// either reaches `.running`, is explicitly stopped, or exhausts retries.
    /// This coalesces foreground/path/ping overlap into one reconnect cycle.
    private var reconnectInFlight = false

    /// Network path monitor — triggers immediate disconnect/reconnect on path changes
    /// (WiFi→LTE, flight mode, etc.) rather than waiting up to 20s for ping failure.
    private var pathMonitor: NWPathMonitor?
    private var lastKnownPathStatus: NWPath.Status = .requiresConnection

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
        // Prevent URLSession from killing the WebSocket after 60s of no data frames.
        // WebSocket PING control frames do not reset URLSession's idle timer — only
        // binary/text data messages do. Without this override the connection drops
        // at exactly timeoutIntervalForRequest (default 60s) regardless of ping cadence.
        config.timeoutIntervalForRequest = 300
        self.urlSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - Transport lifecycle

    public func start() {
        autoReconnect = true
        startPathMonitor()
        guard beginReconnectCycleIfNeeded(reason: "start()") else { return }
        connect()
    }

    public func stop() {
        autoReconnect = false
        lock.withLock {
            isReconnectScheduled = false
            reconnectInFlight = false
        }
        stopPathMonitor()
        disconnect()
        setState(.stopped)
    }

    public func reconnect(reason: String) {
        autoReconnect = true
        startPathMonitor()
        guard beginReconnectCycleIfNeeded(reason: reason) else { return }
        disconnect()
        connect()
    }

    public func send(data: Data, to peerID: PeerID) throws {
        // State and task capture must happen inside the same lock acquisition
        // to prevent a TOCTOU race where a disconnect lands between the two
        // checks. That window caused addressed DMs to throw `.unavailable` and
        // the mesh layer would catch the throw and silently fall back to
        // broadcast — privacy leak *and* symptom generator.
        let task: URLSessionWebSocketTask = try lock.withLock {
            guard isConnected, _state == .running else {
                if _state != .running {
                    throw TransportError.notStarted
                }
                throw TransportError.unavailable("WebSocket not connected")
            }
            guard let task = webSocketTask else {
                throw TransportError.unavailable("WebSocket task missing")
            }
            return task
        }

        // Wrap as binary frame.
        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            guard let self, let error else { return }
            self.logger.error("WebSocket send error: \(error.localizedDescription)")
            // Surface the failure to the delegate so the mesh layer can
            // re-route the packet instead of assuming success. Without this,
            // send errors during the reconnect window were silently dropped.
            self.delegate?.transport(self, didFailDelivery: data, to: peerID)
        }
    }

    public func broadcast(data: Data) {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard isConnected, _state == .running else { return nil }
            return webSocketTask
        }
        guard let task else { return }

        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            guard let self, let error else { return }
            self.logger.error("WebSocket broadcast error: \(error.localizedDescription)")
            // Broadcast has no specific recipient; we signal `to: nil` so the
            // mesh layer can log and, if desired, re-queue.
            self.delegate?.transport(self, didFailDelivery: data, to: nil)
        }
    }

    // MARK: - Network path monitoring

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previousStatus = self.lastKnownPathStatus
            self.lastKnownPathStatus = path.status
            // Only react to transitions to a satisfiable path or outright loss.
            // Ignore redundant updates (same status) and the initial satisfied→satisfied
            // delivery that fires immediately after start().
            guard path.status != previousStatus else { return }
            if path.status == .unsatisfied {
                self.logger.info("Network path lost — triggering relay disconnect")
                self.handleConnectionLost(error: nil)
            } else if path.status == .satisfied, self.autoReconnect, self.state != .running {
                self.logger.info("Network path restored — reconnecting relay")
                guard self.beginReconnectCycleIfNeeded(reason: "pathUpdateHandler") else { return }
                self.scheduleReconnect()
            }
        }
        monitor.start(queue: queue)
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Connection management

    private func connect() {
        lock.withLock {
            isReconnectScheduled = false
        }
        setState(.starting)
        Task { [weak self] in
            guard let self else { return }

            do {
                let token = try await self.tokenProvider()
                self.openWebSocket(using: token)
            } catch {
                self.logger.error("WebSocket auth token unavailable: \(error.localizedDescription)")
                if self.autoReconnect {
                    self.scheduleReconnect()
                } else if self.state != .stopped {
                    // A concurrent stop() has the final word — don't stomp .stopped
                    // with a late .failed from the detached tokenProvider Task.
                    self.clearReconnectCycle()
                    self.setState(.failed("Authentication failed"))
                }
            }
        }
    }

    private func openWebSocket(using token: String) {
        guard autoReconnect || state == .starting else { return }

        // Cancel any old task to prevent ghost receive callbacks. If the old
        // task was live (e.g. a stale `state` read on the path-monitor queue
        // tripped `scheduleReconnect` while the connection was fine), the new
        // task's handleConnectionEstablished will short-circuit on
        // `!isConnected` and `state` will never transition back to `.running`
        // — leaving the foreground handler staring at a stale `.starting`
        // for the lifetime of the process. Tear the bookkeeping down here so
        // the new task can cleanly report connected. HEY1304.
        stopPingTimer()
        let previousTask = webSocketTask
        webSocketTask = nil
        previousTask?.cancel(with: .goingAway, reason: nil)

        // Increment the generation counter so stale callbacks from the old
        // task are silently dropped, and reset `isConnected` so
        // handleConnectionEstablished fires cleanly on the new task.
        lock.withLock {
            taskGeneration += 1
            isConnected = false
        }

        var request = URLRequest(url: self.relayURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(localPeerID.description, forHTTPHeaderField: "X-Peer-ID")

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // NOTE: receiveNextMessage() is NOT called here. It is started from
        // handleConnectionEstablished() after the relay confirms registration.
        // Calling it before the handshake completes causes a race where the
        // receive callback fires with failure before the connection opens.
        logger.info("WebSocket connecting to \(self.relayURL)")
    }

    private func disconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        lock.withLock {
            isConnected = false
            taskGeneration += 1
        }
    }

    private func handleConnectionEstablished() {
        let generation: UInt64? = lock.withLock {
            guard !isConnected else { return nil }
            isConnected = true
            reconnectAttempts = 0
            currentReconnectDelay = Self.minReconnectDelay
            isReconnectScheduled = false
            reconnectInFlight = false
            return taskGeneration
        }
        guard let generation else { return }

        setState(.running)
        delegate?.transport(self, didConnect: serverPeerID)

        startPingTimer(generation: generation)

        // Start the receive loop now that the relay has confirmed registration.
        receiveNextMessage(generation: generation)
        logger.info("WebSocket connected")
    }

    private func handleConnectionLost(error: Error?) {
        stopPingTimer()
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
            markReconnectCycleActive()
            scheduleReconnect()
        } else {
            clearReconnectCycle()
            setState(.stopped)
        }
    }

    private func handleExpiredToken() {
        logger.info("WebSocket token expired, requesting refresh")
        stopPingTimer()

        // Cancel the old task to prevent ghost receive callbacks from
        // triggering a parallel handleConnectionLost.
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        lock.withLock {
            isConnected = false
            taskGeneration += 1
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.tokenRefreshHandler?()
                self.logger.info("WebSocket token refresh succeeded")
            } catch {
                self.logger.error("WebSocket token refresh failed: \(error.localizedDescription)")
            }

            guard self.autoReconnect else {
                self.clearReconnectCycle()
                self.setState(.stopped)
                return
            }

            // Use the same exponential backoff as normal reconnections.
            // Do NOT reset reconnectAttempts — only handleConnectionEstablished
            // resets the backoff counter (when a connection actually succeeds).
            self.markReconnectCycleActive()
            self.scheduleReconnect()
        }
    }

    private func scheduleReconnect(delayOverride: TimeInterval? = nil) {
        let (delay, shouldRetry): (TimeInterval, Bool) = lock.withLock {
            // Prevent duplicate reconnections from racing callbacks.
            guard !isReconnectScheduled else { return (0, false) }
            reconnectAttempts += 1
            guard reconnectAttempts <= Self.maxReconnectAttempts else {
                return (0, false)
            }
            isReconnectScheduled = true
            let d = delayOverride ?? currentReconnectDelay
            if delayOverride == nil {
                currentReconnectDelay = min(currentReconnectDelay * 2, Self.maxReconnectDelay)
            }
            return (d, true)
        }

        guard shouldRetry else {
            let attempts = lock.withLock { reconnectAttempts }
            if attempts > Self.maxReconnectAttempts {
                logger.error("WebSocket max reconnect attempts reached")
                clearReconnectCycle()
                setState(.failed("Max reconnect attempts reached"))
            }
            return
        }

        logger.info("WebSocket reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
        setState(.starting)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.autoReconnect else { return }
            self.connect()
        }
    }

    private func beginReconnectCycleIfNeeded(reason: String) -> Bool {
        enum Decision {
            case skip(log: String)
            case begin
        }

        let decision: Decision = lock.withLock {
            if reconnectInFlight {
                return .skip(log: "reconnect already in flight, skipping (\(reason))")
            }

            switch _state {
            case .idle, .stopped, .failed:
                reconnectInFlight = true
                isReconnectScheduled = false
                return .begin
            case .starting:
                reconnectInFlight = true
                return .skip(log: "reconnect already starting, skipping (\(reason))")
            case .running, .unauthorized:
                return .skip(log: "reconnect not needed from state \(_state) (\(reason))")
            }
        }

        switch decision {
        case .begin:
            return true
        case .skip(let message):
            logger.debug("\(message)")
            return false
        }
    }

    private func markReconnectCycleActive() {
        lock.withLock {
            reconnectInFlight = true
        }
    }

    private func clearReconnectCycle() {
        lock.withLock {
            reconnectInFlight = false
            isReconnectScheduled = false
        }
    }

    // MARK: - Message receiving

    private func receiveRegistrationMessage(generation: UInt64) {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            let current = self.lock.withLock { self.taskGeneration }
            guard generation == current else { return }

            switch result {
            case .success(let message):
                if case .string(let text) = message, text == "connected" {
                    self.handleConnectionEstablished()
                } else {
                    self.logger.debug("WebSocket registration message ignored before relay connected")
                    self.receiveRegistrationMessage(generation: generation)
                }

            case .failure(let error):
                self.handleConnectionLost(error: error)
            }
        }
    }

    private func receiveNextMessage(generation: UInt64) {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            // Drop stale callbacks from old WebSocket tasks.
            let current = self.lock.withLock { self.taskGeneration }
            guard generation == current else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveNextMessage(generation: generation)

            case .failure(let error):
                self.handleConnectionLost(error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Extract the actual sender PeerID from the packet header (bytes 16-23).
            // This ensures handshake sessions, sender binding, and response routing
            // use the real peer identity rather than the relay pseudo-peer.
            //
            // A malformed <24-byte frame must *not* be attributed to the relay
            // pseudo-peer. Previous behaviour let forged/undersized frames look
            // like authenticated relay traffic; instead, drop them outright.
            guard data.count >= 24,
                  let senderPeerID = PeerID(bytes: Data(data[16 ..< 24]))
            else {
                logger.warning("WS dropping undersized/malformed frame (\(data.count)B)")
                return
            }
            logger.debug("WS received \(data.count)B from \(senderPeerID)")
            delegate?.transport(self, didReceiveData: data, from: senderPeerID)

        case .string(let text):
            // The relay sends "connected" after registering the peer in the
            // Durable Object (relay-room.ts). This is the authoritative signal
            // that the relay is ready to route packets.
            if text == "connected" {
                let alreadyConnected: Bool = lock.withLock { isConnected }
                if !alreadyConnected {
                    handleConnectionEstablished()
                }
            } else {
                logger.debug("WebSocket text message: \(text)")
            }

        @unknown default:
            break
        }
    }

    // MARK: - Keep-alive

    private func startPingTimer(generation: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let task = self.currentWebSocketTask(for: generation) else { return }

            task.sendPing { [weak self] error in
                guard let self else { return }
                guard self.currentWebSocketTask(for: generation) != nil else { return }
                guard let error else { return }

                self.logger.warning("WebSocket ping failed: \(error.localizedDescription)")
                self.handleConnectionLost(error: error)
            }
        }

        let oldTimer = lock.withLock {
            let old = pingTimer
            pingTimer = timer
            return old
        }
        oldTimer?.cancel()
        timer.resume()
    }

    private func stopPingTimer() {
        let timer = lock.withLock {
            let timer = pingTimer
            pingTimer = nil
            return timer
        }
        timer?.cancel()
    }

    private func currentWebSocketTask(for generation: UInt64) -> URLSessionWebSocketTask? {
        lock.withLock {
            guard taskGeneration == generation, isConnected else { return nil }
            return webSocketTask
        }
    }

    private func isCurrentWebSocketTask(_ task: URLSessionTask) -> Bool {
        lock.withLock {
            guard let webSocketTask else { return false }
            return webSocketTask === task
        }
    }
}

// MARK: - Internal test hooks
//
// These helpers let the unit-test suite exercise state-machine invariants
// (notably the HEY1304 reconnect-while-connected race) without running a real
// WebSocket handshake. They are deliberately non-public; production code must
// not call them. Extensions in the same source file can reach `private`
// members, so each hook simply forwards to the underlying private method.
extension WebSocketTransport {
    func __testing_simulateRelayConnected() {
        handleConnectionEstablished()
    }

    func __testing_openWebSocket(token: String = "test-token") {
        openWebSocket(using: token)
    }

    /// TEST ONLY. Drives `state` to `.starting` the same way `scheduleReconnect`
    /// does in production. Lets tests simulate a scheduled reconnect without
    /// waiting for the asyncAfter backoff to fire.
    func __testing_markReconnecting() {
        setState(.starting)
    }

    func __testing_triggerForegroundReconnect() {
        reconnect(reason: "test-foreground")
    }

    func __testing_triggerPathReconnect() {
        guard beginReconnectCycleIfNeeded(reason: "test-path") else { return }
        scheduleReconnect(delayOverride: 0)
    }

    func __testing_triggerPingReconnect() {
        guard beginReconnectCycleIfNeeded(reason: "test-ping") else { return }
        scheduleReconnect(delayOverride: 0)
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
        guard isCurrentWebSocketTask(webSocketTask) else { return }

        // TLS handshake is complete but the relay Durable Object hasn't
        // confirmed registration yet. Wait for the "connected" text frame
        // as the authoritative signal.
        logger.info("WebSocket TLS handshake complete, waiting for relay registration")
        let gen = lock.withLock { taskGeneration }
        receiveRegistrationMessage(generation: gen)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard isCurrentWebSocketTask(webSocketTask) else { return }

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
        guard isCurrentWebSocketTask(task) else { return }

        if let response = task.response as? HTTPURLResponse, response.statusCode == 401 {
            handleExpiredToken()
            return
        }

        if let error = error {
            handleConnectionLost(error: error)
        }
    }
}
