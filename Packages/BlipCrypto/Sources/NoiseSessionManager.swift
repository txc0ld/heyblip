import Foundation
import CryptoKit
import BlipProtocol

// MARK: - Errors

public enum NoiseSessionError: Error, Sendable {
    case sessionNotFound(PeerID)
    case handshakeInProgress(PeerID)
    case sessionExpired(PeerID)
    case rekeyFailed
}

// MARK: - NoiseSession

/// A completed Noise session with a remote peer.
///
/// Encapsulates the bidirectional cipher states, the remote peer's authenticated
/// static key, and session metadata for cache management and rekey scheduling.
public final class NoiseSession: @unchecked Sendable {

    /// The remote peer's identifier.
    public let peerID: PeerID

    /// The remote peer's authenticated static public key.
    public let remoteStaticKey: Curve25519.KeyAgreement.PublicKey

    /// Cipher state for encrypting outgoing messages.
    public let sendCipher: NoiseCipherState

    /// Cipher state for decrypting incoming messages.
    public let receiveCipher: NoiseCipherState

    /// The handshake hash that uniquely identifies this session.
    public let handshakeHash: Data

    /// When this session was established.
    public let establishedAt: Date

    /// When this session expires (4 hours after establishment).
    public let expiresAt: Date

    /// Whether the peer's static key is known (enables IK pattern upgrade on reconnect).
    public let peerStaticKeyKnown: Bool

    /// Replay protection for incoming messages.
    public let replayProtection: ReplayProtection

    /// Timestamp of the last rekey operation.
    private var lastRekeyTime: Date

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Constants

    /// Session TTL: 4 hours.
    public static let sessionTTL: TimeInterval = 4 * 60 * 60

    /// Rekey after this many messages.
    public static let rekeyMessageThreshold: UInt64 = 1000

    /// Rekey after this time interval.
    public static let rekeyTimeInterval: TimeInterval = 60 * 60 // 1 hour

    // MARK: - Init

    public init(
        peerID: PeerID,
        result: NoiseHandshakeResult,
        now: Date = Date()
    ) {
        self.peerID = peerID
        self.remoteStaticKey = result.remoteStaticKey
        self.sendCipher = result.sendCipher
        self.receiveCipher = result.receiveCipher
        self.handshakeHash = result.handshakeHash
        self.establishedAt = now
        self.expiresAt = now.addingTimeInterval(Self.sessionTTL)
        self.peerStaticKeyKnown = true
        self.replayProtection = ReplayProtection()
        self.lastRekeyTime = now
    }

    // MARK: - Expiry

    /// Whether this session has expired.
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext message for sending to this peer.
    ///
    /// Automatically triggers rekey if the message or time threshold is exceeded.
    public func encrypt(plaintext: Data, ad: Data = Data()) throws -> Data {
        lock.lock()
        let needsRekey = shouldRekey()
        lock.unlock()

        if needsRekey {
            try rekey()
        }

        return try sendCipher.encrypt(plaintext: plaintext, ad: ad)
    }

    // MARK: - Decrypt

    /// Decrypt a ciphertext message received from this peer.
    ///
    /// Validates the nonce against the replay protection window.
    public func decrypt(ciphertext: Data, ad: Data = Data()) throws -> Data {
        let plaintext = try receiveCipher.decrypt(ciphertext: ciphertext, ad: ad)
        return plaintext
    }

    // MARK: - Rekey

    /// Check whether a rekey is needed based on message count or time.
    private func shouldRekey() -> Bool {
        if sendCipher.messageCount >= Self.rekeyMessageThreshold {
            return true
        }
        if Date().timeIntervalSince(lastRekeyTime) >= Self.rekeyTimeInterval {
            return true
        }
        return false
    }

    /// Perform a rekey on both cipher states.
    public func rekey() throws {
        lock.lock()
        defer { lock.unlock() }

        try sendCipher.rekey()
        try receiveCipher.rekey()
        lastRekeyTime = Date()
    }
}

// MARK: - PendingHandshake

/// Tracks an in-progress handshake with a remote peer.
public final class PendingHandshake: @unchecked Sendable {
    public let peerID: PeerID
    public let handshake: NoiseHandshake
    public let startedAt: Date

    /// Timeout for handshakes (30 seconds).
    public static let timeout: TimeInterval = 30

    public init(peerID: PeerID, handshake: NoiseHandshake, now: Date = Date()) {
        self.peerID = peerID
        self.handshake = handshake
        self.startedAt = now
    }

    public func isTimedOut(now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= Self.timeout
    }
}

// MARK: - NoiseSessionManager

/// Manages active Noise sessions and in-progress handshakes.
///
/// Sessions are cached for 4 hours, keyed by PeerID. If a peer reconnects
/// within the cache window, the existing cipher states resume without a new
/// handshake. For peers whose static key is already known from a prior XX
/// handshake, subsequent connections can use the IK pattern (2 messages
/// instead of 3).
///
/// Automatic rekey occurs every 1000 messages or 1 hour, whichever comes first.
public final class NoiseSessionManager: @unchecked Sendable {

    // MARK: - State

    /// Active sessions keyed by PeerID.
    private var sessions: [PeerID: NoiseSession] = [:]

    /// In-progress handshakes keyed by PeerID.
    private var pendingHandshakes: [PeerID: PendingHandshake] = [:]

    /// Known static keys for peers (enables IK pattern upgrade).
    private var knownStaticKeys: [PeerID: Curve25519.KeyAgreement.PublicKey] = [:]

    /// Our local static keypair.
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Init

    /// Create a session manager with the local party's static key.
    public init(localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.localStaticKey = localStaticKey
    }

    // MARK: - Session lookup

    /// Get an existing active session for a peer, if one exists and hasn't expired.
    public func getSession(for peerID: PeerID) -> NoiseSession? {
        lock.lock()
        defer { lock.unlock() }

        guard let session = sessions[peerID] else { return nil }

        if session.isExpired() {
            sessions.removeValue(forKey: peerID)
            return nil
        }

        return session
    }

    /// Check whether we have an active (non-expired) session for a peer.
    public func hasSession(for peerID: PeerID) -> Bool {
        getSession(for: peerID) != nil
    }

    /// Whether there is an in-progress handshake (any role) with the given peer.
    public func hasPendingHandshake(for peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingHandshakes[peerID] != nil
    }

    /// Returns true if there's a pending handshake in the initiator role for this peer.
    public func hasPendingInitiatorHandshake(for peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = pendingHandshakes[peerID] else { return false }
        return pending.handshake.role == .initiator
    }

    /// Returns true if there's a pending handshake in the responder role for this peer.
    public func hasPendingResponderHandshake(for peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = pendingHandshakes[peerID] else { return false }
        return pending.handshake.role == .responder
    }

    /// Find an active session where the remote static key matches the given public key.
    /// Handles PeerID rotation — the session was established under an old PeerID but
    /// the remote Noise key is stable.
    public func getSession(byRemoteKey key: Curve25519.KeyAgreement.PublicKey) -> (PeerID, NoiseSession)? {
        lock.lock()
        defer { lock.unlock() }
        for (peerID, session) in sessions {
            if session.remoteStaticKey.rawRepresentation == key.rawRepresentation {
                if session.isExpired() {
                    continue
                }
                return (peerID, session)
            }
        }
        return nil
    }

    /// Migrate a session from an old PeerID to a new one (after BLE address rotation).
    @discardableResult
    public func migrateSession(from oldPeerID: PeerID, to newPeerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: oldPeerID) else { return false }
        sessions[newPeerID] = session
        if let pending = pendingHandshakes.removeValue(forKey: oldPeerID) {
            pendingHandshakes[newPeerID] = pending
        }
        return true
    }

    // MARK: - Handshake initiation

    /// Begin a new XX handshake as the initiator.
    ///
    /// Returns the first handshake message to send to the peer.
    public func initiateHandshake(with peerID: PeerID, payload: Data = Data()) throws -> (PendingHandshake, Data) {
        lock.lock()
        defer { lock.unlock() }

        let handshake = NoiseHandshake(
            role: .initiator,
            staticKey: localStaticKey
        )

        let message = try handshake.writeMessage(payload: payload)
        let pending = PendingHandshake(peerID: peerID, handshake: handshake)
        pendingHandshakes[peerID] = pending

        return (pending, message)
    }

    /// Begin a new XX handshake as the responder after receiving message 1.
    ///
    /// Returns the pending handshake state and payload, or `nil` if a simultaneous
    /// initiation tiebreaker determined we should keep our initiator role.
    ///
    /// **Tiebreaker rule:** When both peers initiate simultaneously, the peer with
    /// the lexicographically lower PeerID becomes the responder. The higher PeerID
    /// peer keeps its initiator role and the incoming msg1 is discarded.
    public func receiveHandshakeInit(
        from peerID: PeerID,
        message: Data
    ) throws -> (PendingHandshake, Data)? {
        lock.lock()
        defer { lock.unlock() }

        // Simultaneous initiation: we have a pending outbound handshake as initiator
        if let existing = pendingHandshakes[peerID], existing.handshake.role == .initiator {
            let localPeerID = PeerID(noisePublicKey: localStaticKey.publicKey)
            if !localPeerID.bytes.lexicographicallyPrecedes(peerID.bytes) {
                // Our PeerID >= remote → we keep initiator role, discard incoming msg1
                return nil
            }
            // Our PeerID < remote → we yield initiator role
            // Explicitly remove the old initiator handshake before creating responder
            pendingHandshakes.removeValue(forKey: peerID)
        }

        let handshake = NoiseHandshake(
            role: .responder,
            staticKey: localStaticKey
        )

        // Read message 1
        let payload = try handshake.readMessage(message)
        let pending = PendingHandshake(peerID: peerID, handshake: handshake)
        pendingHandshakes[peerID] = pending

        _ = payload  // Message 1 payload (usually empty)
        return (pending, payload)
    }

    /// As responder, generate message 2 of the handshake.
    public func respondToHandshake(for peerID: PeerID, payload: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingHandshakes[peerID] else {
            throw NoiseSessionError.sessionNotFound(peerID)
        }

        return try pending.handshake.writeMessage(payload: payload)
    }

    /// Process an incoming handshake message (message 2 or 3).
    ///
    /// If this completes the handshake, creates and caches the session.
    ///
    /// - Returns: The payload from the message, and optionally the completed session.
    public func processHandshakeMessage(
        from peerID: PeerID,
        message: Data
    ) throws -> (payload: Data, session: NoiseSession?) {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingHandshakes[peerID] else {
            throw NoiseSessionError.sessionNotFound(peerID)
        }

        let payload = try pending.handshake.readMessage(message)

        if pending.handshake.isComplete {
            let result = try pending.handshake.finalize()
            let session = NoiseSession(peerID: peerID, result: result)

            // Cache the session and the peer's static key
            sessions[peerID] = session
            knownStaticKeys[peerID] = result.remoteStaticKey
            pendingHandshakes.removeValue(forKey: peerID)

            return (payload, session)
        }

        return (payload, nil)
    }

    /// As initiator, generate message 3 to complete the handshake.
    ///
    /// Returns the message bytes and the completed session.
    public func completeHandshake(
        with peerID: PeerID,
        payload: Data = Data()
    ) throws -> (Data, NoiseSession) {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingHandshakes[peerID] else {
            throw NoiseSessionError.sessionNotFound(peerID)
        }

        let message = try pending.handshake.writeMessage(payload: payload)
        let result = try pending.handshake.finalize()
        let session = NoiseSession(peerID: peerID, result: result)

        sessions[peerID] = session
        knownStaticKeys[peerID] = result.remoteStaticKey
        pendingHandshakes.removeValue(forKey: peerID)

        return (message, session)
    }

    // MARK: - IK Pattern Upgrade

    /// Whether we can use the faster IK pattern (2-message handshake) for a peer.
    ///
    /// Returns `true` if we have a cached static key from a prior XX handshake.
    public func canUseIKPattern(for peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return knownStaticKeys[peerID] != nil
    }

    /// Get the known static key for a peer (from a prior handshake).
    public func knownStaticKey(for peerID: PeerID) -> Curve25519.KeyAgreement.PublicKey? {
        lock.lock()
        defer { lock.unlock() }
        return knownStaticKeys[peerID]
    }

    // MARK: - Session management

    /// Destroy the session for a specific peer.
    public func destroySession(for peerID: PeerID) {
        lock.lock()
        defer { lock.unlock() }

        sessions.removeValue(forKey: peerID)
        pendingHandshakes.removeValue(forKey: peerID)
    }

    /// Remove all expired sessions.
    ///
    /// Call this periodically (e.g., every minute) to clean up stale sessions.
    public func pruneExpiredSessions() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        sessions = sessions.filter { !$0.value.isExpired(now: now) }

        pendingHandshakes = pendingHandshakes.filter { !$0.value.isTimedOut(now: now) }
    }

    /// Destroy all sessions and pending handshakes.
    ///
    /// Called when entering ultra-low battery mode or on explicit user action.
    public func destroyAllSessions() {
        lock.lock()
        defer { lock.unlock() }

        sessions.removeAll()
        pendingHandshakes.removeAll()
    }

    /// Number of active sessions.
    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    /// Number of pending handshakes.
    public var pendingHandshakeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingHandshakes.count
    }

    /// All peer IDs with active sessions.
    public var activePeerIDs: [PeerID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.keys)
    }

    /// Register a known static key for a peer (e.g., from a previous session or announcement).
    public func registerStaticKey(_ key: Curve25519.KeyAgreement.PublicKey, for peerID: PeerID) {
        lock.lock()
        defer { lock.unlock() }
        knownStaticKeys[peerID] = key
    }
}
