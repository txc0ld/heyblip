import Foundation
import SwiftData
import os.log
import BlipProtocol
import BlipMesh
import BlipCrypto

// MARK: - Message Service Error

enum MessageServiceError: Error, Sendable {
    case channelNotFound
    case senderNotFound
    case encryptionFailed(String)
    case serializationFailed(String)
    case noTransportAvailable
    case payloadTooLarge(Int)
    case invalidRecipient
    case sessionNotEstablished(PeerID)
    case decryptionFailed(String)
    case deserializationFailed(String)
    case messageExpired
    case duplicateMessage(UUID)
}

// MARK: - Message Service Delegate

protocol MessageServiceDelegate: AnyObject, Sendable {
    func messageService(_ service: MessageService, didReceiveMessage message: Message, in channel: Channel)
    func messageService(_ service: MessageService, didUpdateStatus status: MessageStatus, for messageID: UUID)
    func messageService(_ service: MessageService, didReceiveTypingIndicatorFrom peerID: PeerID, in channelID: UUID)
    func messageService(_ service: MessageService, didReceiveDeliveryAck messageID: UUID)
    func messageService(_ service: MessageService, didReceiveReadReceipt messageID: UUID)
}

// MARK: - Message Service

/// Orchestrates message send/receive: encrypt, serialize, transport, decrypt, store, notify.
///
/// Integrates with:
/// - `BlipCrypto.KeyManager` for identity and encryption
/// - `BlipProtocol.PacketSerializer` for wire format
/// - `BlipMesh.Transport` for BLE/WebSocket delivery
/// - SwiftData for persistence
/// - MessageQueue for retry tracking
final class MessageService: @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "MessageService")

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let keyManager: KeyManager
    private let bloomFilter: MultiTierBloomFilter
    private let peerStore: PeerStore
    weak var delegate: (any MessageServiceDelegate)?

    // Transport reference (set externally after initialization)
    private var transport: (any Transport)?

    // MARK: - Noise Sessions

    /// Manages Noise XX handshakes and active encrypted sessions.
    private var noiseSessionManager: NoiseSessionManager?

    /// Messages queued while waiting for a Noise handshake to complete.
    private var pendingHandshakeMessages: [Data: [PendingEncryptedMessage]] = [:]

    /// A message waiting for a Noise session to be established before it can be encrypted.
    private struct PendingEncryptedMessage {
        let payload: Data
        let subType: EncryptedSubType
        let channel: Channel
        let identity: Identity
        let messageID: UUID?
    }

    // MARK: - State

    private let lock = NSLock()
    private var localIdentity: Identity?

    // Typing indicator debounce tracking: channelID -> last sent timestamp
    private var lastTypingIndicatorSent: [UUID: Date] = [:]
    private let typingIndicatorInterval: TimeInterval = 3.0

    // MARK: - Constants

    /// Maximum text payload size in bytes (UTF-8).
    private static let maxTextPayloadSize = 4096

    /// Free action types that don't consume message balance.
    private static let freeSubTypes: Set<EncryptedSubType> = [
        .deliveryAck, .readReceipt, .typingIndicator, .friendRequest, .friendAccept
    ]

    // MARK: - Init

    init(modelContainer: ModelContainer, keyManager: KeyManager = .shared, peerStore: PeerStore = .shared) {
        self.modelContainer = modelContainer
        self.keyManager = keyManager
        self.peerStore = peerStore
        self.bloomFilter = MultiTierBloomFilter()
    }

    // MARK: - Configuration

    func configure(transport: any Transport, identity: Identity) {
        lock.lock()
        defer { lock.unlock() }
        self.transport = transport
        self.localIdentity = identity
        self.noiseSessionManager = NoiseSessionManager(localStaticKey: identity.noisePrivateKey)
    }

    // MARK: - Send Message

    /// Send a text message to a channel.
    ///
    /// Flow: validate balance -> create Message model -> encrypt -> serialize -> transport
    @MainActor
    func sendTextMessage(
        content: String,
        to channel: Channel,
        replyTo: Message? = nil
    ) async throws -> Message {
        guard let identity = getIdentity() else {
            DebugLogger.shared.log("TX", "sendTextMessage FAILED: no local identity", isError: true)
            throw MessageServiceError.senderNotFound
        }

        let channelShort = String(channel.id.uuidString.prefix(8))
        DebugLogger.shared.log("DM", "sendTextMessage: text=\(content.utf8.count) channel=\(channelShort) type=\(channel.type)")

        let context = ModelContext(modelContainer)

        // Create the message model
        let message = Message(
            sender: nil, // Local user, resolved via identity
            channel: channel,
            type: .text,
            encryptedPayload: content.data(using: .utf8) ?? Data(),
            status: .queued,
            replyTo: replyTo,
            createdAt: Date()
        )
        context.insert(message)
        do {
            try context.save()
            DebugLogger.shared.log("DM", "sendTextMessage: queued msgID=\(message.id)")
        } catch {
            DebugLogger.shared.log("DM", "sendTextMessage: FAILED at save: \(error)", isError: true)
            throw error
        }

        // Encrypt and send
        let payload = buildTextPayload(content: content, messageID: message.id, replyToID: replyTo?.id)
        do {
            try await encryptAndSend(
                payload: payload,
                subType: channel.isGroup ? .groupMessage : .privateMessage,
                channel: channel,
                identity: identity,
                messageID: message.id
            )
        } catch {
            DebugLogger.shared.log("DM", "sendTextMessage: FAILED at encryptAndSend: \(error)", isError: true)
            throw error
        }

        // Update status
        message.status = .sent
        try context.save()

        DebugLogger.shared.log("DM", "sendTextMessage: COMPLETE msgID=\(message.id)")
        return message
    }

    /// Send a voice note message.
    @MainActor
    func sendVoiceNote(
        audioData: Data,
        duration: TimeInterval,
        to channel: Channel
    ) async throws -> Message {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }

        let context = ModelContext(modelContainer)

        let message = Message(
            channel: channel,
            type: .voiceNote,
            encryptedPayload: Data(),
            status: .queued,
            createdAt: Date()
        )

        let attachment = Attachment(
            message: message,
            type: .voiceNote,
            fullData: audioData,
            sizeBytes: audioData.count,
            mimeType: "audio/opus",
            duration: duration
        )
        context.insert(message)
        context.insert(attachment)
        try context.save()

        let payload = buildMediaPayload(data: audioData, messageID: message.id, mediaMeta: VoiceNoteMeta(duration: duration))
        try await encryptAndSend(
            payload: payload,
            subType: .voiceNote,
            channel: channel,
            identity: identity,
            messageID: message.id
        )

        message.status = .sent
        try context.save()

        return message
    }

    /// Send an image message.
    @MainActor
    func sendImage(
        imageData: Data,
        thumbnail: Data,
        to channel: Channel
    ) async throws -> Message {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }

        guard imageData.count <= 500_000 else {
            throw MessageServiceError.payloadTooLarge(imageData.count)
        }

        let context = ModelContext(modelContainer)

        let message = Message(
            channel: channel,
            type: .image,
            encryptedPayload: Data(),
            status: .queued,
            createdAt: Date()
        )

        let attachment = Attachment(
            message: message,
            type: .image,
            thumbnail: thumbnail,
            fullData: imageData,
            sizeBytes: imageData.count,
            mimeType: "image/jpeg"
        )
        context.insert(message)
        context.insert(attachment)
        try context.save()

        let payload = buildMediaPayload(data: imageData, messageID: message.id, mediaMeta: nil)
        try await encryptAndSend(
            payload: payload,
            subType: .imageMessage,
            channel: channel,
            identity: identity,
            messageID: message.id
        )

        message.status = .sent
        try context.save()

        return message
    }

    /// Send a typing indicator to a channel.
    func sendTypingIndicator(to channel: Channel) async throws {
        guard let identity = getIdentity() else { return }

        // Debounce: only send every 3 seconds
        lock.lock()
        let lastSent = lastTypingIndicatorSent[channel.id]
        let now = Date()
        if let lastSent, now.timeIntervalSince(lastSent) < typingIndicatorInterval {
            lock.unlock()
            return
        }
        lastTypingIndicatorSent[channel.id] = now
        lock.unlock()

        var payload = Data()
        payload.append(channel.id.uuidString.data(using: .utf8) ?? Data())

        try await encryptAndSend(
            payload: payload,
            subType: .typingIndicator,
            channel: channel,
            identity: identity,
            messageID: nil
        )
    }

    /// Send a delivery acknowledgement for a received message.
    func sendDeliveryAck(for messageID: UUID, to peerID: PeerID) async throws {
        guard let identity = getIdentity() else { return }

        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())

        let packet = buildPacket(
            type: .noiseEncrypted,
            payload: prependSubType(.deliveryAck, to: payload),
            flags: [.hasRecipient, .hasSignature, .isReliable],
            senderID: identity.peerID,
            recipientID: peerID
        )

        try sendPacket(packet)
    }

    /// Send a read receipt for a message.
    func sendReadReceipt(for messageID: UUID, to peerID: PeerID) async throws {
        guard let identity = getIdentity() else { return }

        var payload = Data()
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())

        let packet = buildPacket(
            type: .noiseEncrypted,
            payload: prependSubType(.readReceipt, to: payload),
            flags: [.hasRecipient, .hasSignature],
            senderID: identity.peerID,
            recipientID: peerID
        )

        try sendPacket(packet)
    }

    // MARK: - Friend Requests

    /// Send a friend request to a nearby peer identified by their 8-byte PeerID data.
    ///
    /// Convenience wrapper for views that don't import BlipProtocol.
    @MainActor
    func sendFriendRequest(toPeerData peerData: Data) async throws {
        guard let peerID = PeerID(bytes: peerData) else {
            throw MessageServiceError.invalidRecipient
        }
        try await sendFriendRequest(to: peerID)
    }

    /// Send a friend request to a nearby peer.
    ///
    /// Payload format: username (UTF-8) + 0x00 + displayName (UTF-8)
    /// Creates a local Friend record with `.pending` status.
    @MainActor
    func sendFriendRequest(to peerID: PeerID) async throws {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }

        let context = ModelContext(modelContainer)

        // Get local user
        let userDescriptor = FetchDescriptor<User>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        guard let localUser = try context.fetch(userDescriptor).first else {
            throw MessageServiceError.senderNotFound
        }

        // Build payload: username + 0x00 + displayName
        var payload = Data()
        payload.append(localUser.username.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(localUser.resolvedDisplayName.data(using: .utf8) ?? Data())

        let packet = buildPacket(
            type: .noiseEncrypted,
            payload: prependSubType(.friendRequest, to: payload),
            flags: [.hasRecipient, .hasSignature, .isReliable],
            senderID: identity.peerID,
            recipientID: peerID
        )

        try sendPacket(packet)

        // Create or update local Friend record for the remote peer
        let peerData = peerID.bytes
        if let peerInfo = peerStore.findPeer(byPeerIDBytes: peerData) {
            let remoteUser = try resolveOrCreateUser(for: peerInfo, context: context)
            try createOrUpdateFriend(user: remoteUser, status: .pending, context: context)
        }

        let shortID = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("TX", "FRIEND_REQ → \(shortID)")
        logger.info("Sent friend request to peer \(peerID)")
    }

    /// Accept a pending friend request and notify the sender.
    ///
    /// Updates the local Friend record to `.accepted`, creates a DM channel, and
    /// sends a `.friendAccept` packet back to the requester.
    @MainActor
    func acceptFriendRequest(from friend: Friend) async throws {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }
        guard let friendUser = friend.user else {
            throw MessageServiceError.invalidRecipient
        }

        let context = ModelContext(modelContainer)

        // Update friend status
        let friendID = friend.id
        let friendDesc = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        if let existingFriend = try context.fetch(friendDesc).first {
            existingFriend.statusRaw = FriendStatus.accepted.rawValue
            try context.save()
        }

        // Ensure user has keys before DM channel creation
        if friendUser.noisePublicKey.isEmpty {
            let friendUsername = friendUser.username
            if let peerInfo = peerStore.peer(byUsername: friendUsername),
               !peerInfo.noisePublicKey.isEmpty {
                friendUser.noisePublicKey = peerInfo.noisePublicKey
                friendUser.signingPublicKey = peerInfo.signingPublicKey
                try? context.save()
                DebugLogger.shared.log("DM", "Backfilled keys for \(friendUsername) before createDMChannel")
            }
        }

        // Ensure DM channel exists
        try createDMChannel(with: friendUser, context: context)

        // Resolve the transport PeerID for the friend so the accept reaches them
        let recipientPeerID: PeerID
        let friendNoiseKey = friendUser.noisePublicKey
        if let peerInfo = peerStore.peer(byNoisePublicKey: friendNoiseKey) {
            recipientPeerID = PeerID(bytes: peerInfo.peerID) ?? PeerID(noisePublicKey: friendUser.noisePublicKey)
        } else if friendUser.noisePublicKey.count == PeerID.length {
            recipientPeerID = PeerID(bytes: friendUser.noisePublicKey) ?? PeerID(noisePublicKey: friendUser.noisePublicKey)
        } else {
            recipientPeerID = PeerID(noisePublicKey: friendUser.noisePublicKey)
        }

        let localUserDesc = FetchDescriptor<User>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        guard let localUser = try context.fetch(localUserDesc).first else {
            throw MessageServiceError.senderNotFound
        }

        var payload = Data()
        payload.append(localUser.username.data(using: .utf8) ?? Data())

        let packet = buildPacket(
            type: .noiseEncrypted,
            payload: prependSubType(.friendAccept, to: payload),
            flags: [.hasRecipient, .hasSignature, .isReliable],
            senderID: identity.peerID,
            recipientID: recipientPeerID
        )

        try sendPacket(packet)

        logger.info("Accepted friend request from \(friendUser.username)")

        NotificationCenter.default.post(
            name: .friendListDidChange,
            object: nil
        )
    }

    // MARK: - Nearby Visibility

    /// Broadcast presence to the mesh so nearby peers can see your username.
    ///
    /// Sends an `announce` packet with username + display name. Only call this
    /// when the user has opted in to nearby visibility.
    @MainActor
    func broadcastPresence() async throws {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }

        let context = ModelContext(modelContainer)
        let userDescriptor = FetchDescriptor<User>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        guard let localUser = try context.fetch(userDescriptor).first else {
            throw MessageServiceError.senderNotFound
        }

        // Payload: username + 0x00 + displayName + 0x00 + noisePublicKey(32B) + signingPublicKey(32B)
        var payload = Data()
        payload.append(localUser.username.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(localUser.resolvedDisplayName.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(identity.noisePublicKey.rawRepresentation) // 32-byte Curve25519 key
        payload.append(identity.signingPublicKey) // 32-byte Ed25519 public key

        let packet = buildPacket(
            type: .announce,
            payload: payload,
            flags: [],
            senderID: identity.peerID,
            recipientID: nil
        )

        try sendPacket(packet)
        DebugLogger.shared.log("TX", "ANNOUNCE → \(localUser.username)")
    }

    // MARK: - Receive Message

    /// Process incoming raw data from the transport layer.
    ///
    /// Flow: deserialize -> deduplicate -> decrypt -> store -> notify delegate
    @MainActor
    func receive(data: Data, from peerID: PeerID) async throws {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("RX", "receive(): \(data.count)B from \(peerHex)")

        // Deserialize the packet
        let packet: Packet
        do {
            packet = try PacketSerializer.decode(data)
            DebugLogger.shared.log("RX", "Decoded packet: type=\(packet.type) flags=\(packet.flags)")
        } catch {
            DebugLogger.shared.log("RX", "DESERIALIZE FAILED: \(error)", isError: true)
            throw MessageServiceError.deserializationFailed(error.localizedDescription)
        }

        // Verify Ed25519 signature if present
        if packet.flags.contains(.hasSignature) {
            let senderData = packet.senderID.bytes
            let senderHex = senderData.prefix(4).map { String(format: "%02x", $0) }.joined()
            let signingKey: Data?

            // Look up sender's signing public key via PeerStore
            if let peerInfo = peerStore.findPeer(byPeerIDBytes: senderData),
               !peerInfo.signingPublicKey.isEmpty {
                signingKey = peerInfo.signingPublicKey
            } else {
                signingKey = nil
            }

            if let key = signingKey {
                let keyPrefix = key.prefix(4).map { String(format: "%02x", $0) }.joined()
                do {
                    let valid = try Signer.verify(packet: packet, publicKey: key)
                    if !valid {
                        print("[Blip-RX] SIGNATURE INVALID — dropping packet from \(senderHex)")
                        DebugLogger.shared.log("RX", "SIG INVALID from \(senderHex) key=\(keyPrefix) — dropped", isError: true)
                        return
                    }
                    print("[Blip-RX] Signature verified")
                    DebugLogger.shared.log("RX", "SIG OK from \(senderHex) key=\(keyPrefix)")
                } catch {
                    // Verification threw (e.g. malformed) — accept with warning
                    print("[Blip-RX] Signature check error: \(error) — accepting anyway")
                    DebugLogger.shared.log("RX", "SIG CHECK ERROR from \(senderHex): \(error) — accepting", isError: true)
                }
            } else {
                // No signing key known yet (pre-announce bootstrap) — accept unverified
                print("[Blip-RX] No signing key for sender — accepting unverified")
                DebugLogger.shared.log("RX", "No signing key for \(senderHex) — accepting unverified")
            }
        }

        // Deduplicate via Bloom filter
        let packetIDData = buildPacketID(packet)
        if bloomFilter.contains(packetIDData) {
            DebugLogger.shared.log("RX", "DUPLICATE packet — skipping")
            return // Already processed
        }
        bloomFilter.insert(packetIDData)
        DebugLogger.shared.log("RX", "Bloom: new packet, inserted")

        // Route based on packet type
        switch packet.type {
        case .announce:
            try await handleAnnounce(packet, from: peerID)
        case .noiseHandshake:
            try await handleNoiseHandshake(packet, from: peerID)
        case .noiseEncrypted:
            try await handleEncryptedPacket(packet, from: peerID)
        case .meshBroadcast:
            try await handleBroadcastMessage(packet)
        case .sosAlert, .sosAccept, .sosPreciseLocation, .sosResolve, .sosNearbyAssist:
            try await handleSOSPacket(packet)
        case .locationShare, .locationRequest, .proximityPing, .iAmHereBeacon:
            try await handleLocationPacket(packet, from: peerID)
        case .pttAudio:
            try await handlePTTAudio(packet, from: peerID)
        case .orgAnnouncement:
            try await handleOrgAnnouncement(packet)
        default:
            break // Other packet types handled by mesh layer
        }
    }

    // MARK: - Private: Encrypt and Send

    private func encryptAndSend(
        payload: Data,
        subType: EncryptedSubType,
        channel: Channel,
        identity: Identity,
        messageID: UUID?
    ) async throws {
        DebugLogger.emit("DM", "encryptAndSend: subType=\(subType) payloadSize=\(payload.count)")
        let taggedPayload = prependSubType(subType, to: payload)

        // Determine compression: skip for pre-compressed types
        let isPreCompressed = (subType == .voiceNote || subType == .imageMessage)
        let compressed = PayloadCompressor.compressIfNeeded(taggedPayload, isPreCompressed: isPreCompressed)

        let ratio = taggedPayload.count > 0 ? Double(compressed.data.count) / Double(taggedPayload.count) : 1.0
        DebugLogger.emit("TX", "Compression: \(taggedPayload.count)B → \(compressed.data.count)B (ratio=\(String(format: "%.2f", ratio)), compressed=\(compressed.wasCompressed))")

        // Build flags
        var flags: PacketFlags = [.isReliable]
        if compressed.wasCompressed {
            flags.insert(.isCompressed)
        }

        if channel.type == .dm {
            // DM: addressed to specific peer
            flags.insert(.hasRecipient)
            let recipientPeerID = resolveRecipientPeerID(for: channel)
            let recipientHex = recipientPeerID?.bytes.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "nil"

            guard let recipientPeerID else {
                DebugLogger.emit("DM", "encryptAndSend: FAILED — recipient could not be resolved", isError: true)
                throw MessageServiceError.invalidRecipient
            }

            // Check for active Noise session — encrypt if available, queue + handshake if not
            if let session = noiseSessionManager?.getSession(for: recipientPeerID) {
                // Encrypt with Noise session
                let ciphertext = try session.encrypt(plaintext: compressed.data)
                DebugLogger.emit("DM", "encryptAndSend: Noise encrypted \(compressed.data.count)B → \(ciphertext.count)B → \(recipientHex)")

                let packet = buildPacket(
                    type: .noiseEncrypted,
                    payload: ciphertext,
                    flags: flags,
                    senderID: identity.peerID,
                    recipientID: recipientPeerID
                )
                try sendPacket(packet)
            } else if try initiateHandshakeIfNeeded(with: recipientPeerID) {
                // Handshake initiated — queue this message
                DebugLogger.emit("DM", "encryptAndSend: queuing message for \(recipientHex) pending handshake")
                let pending = PendingEncryptedMessage(
                    payload: payload,
                    subType: subType,
                    channel: channel,
                    identity: identity,
                    messageID: messageID
                )
                lock.lock()
                pendingHandshakeMessages[recipientPeerID.bytes, default: []].append(pending)
                lock.unlock()

                // Mark message as encrypting
                if let messageID {
                    updateMessageStatus(messageID: messageID, to: .encrypting)
                }
                return // Don't enqueue for retry — the handshake callback will handle it
            } else {
                // Fallback: send unencrypted (session manager not available)
                DebugLogger.emit("DM", "encryptAndSend: no Noise session, sending plaintext to \(recipientHex)")
                let packet = buildPacket(
                    type: .noiseEncrypted,
                    payload: compressed.data,
                    flags: flags,
                    senderID: identity.peerID,
                    recipientID: recipientPeerID
                )
                try sendPacket(packet)
            }
        } else {
            // Group/channel: broadcast (no Noise encryption for groups yet)
            print("[Blip-TX] BROADCAST \(subType) (\(compressed.data.count)B)")
            let packet = buildPacket(
                type: .noiseEncrypted,
                payload: compressed.data,
                flags: flags,
                senderID: identity.peerID,
                recipientID: nil
            )
            try sendPacket(packet)
        }

        // Enqueue for retry if needed
        if let messageID {
            try await enqueueForRetry(messageID: messageID)
        }
    }

    private func sendPacket(_ packet: Packet) throws {
        guard let transport else {
            print("[Blip-TX] SEND FAILED: no transport available")
            DebugLogger.emit("TX", "SEND FAILED: no transport available", isError: true)
            throw MessageServiceError.noTransportAvailable
        }

        // Sign the packet with our Ed25519 key before encoding
        let signedPacket: Packet
        if let identity = getIdentity() {
            do {
                signedPacket = try Signer.sign(packet: packet, secretKey: identity.signingSecretKey)
                DebugLogger.emit("TX", "Ed25519 signing OK")
            } catch {
                print("[Blip-TX] SIGNING FAILED: \(error) — sending unsigned")
                DebugLogger.emit("TX", "Ed25519 SIGNING FAILED: \(error) — sending unsigned", isError: true)
                signedPacket = packet
            }
        } else {
            signedPacket = packet
        }

        let wireData: Data
        do {
            wireData = try PacketSerializer.encode(signedPacket)
        } catch {
            print("[Blip-TX] ENCODE FAILED: \(error)")
            DebugLogger.emit("TX", "ENCODE FAILED: \(error)", isError: true)
            throw error
        }

        if let recipientID = signedPacket.recipientID, !recipientID.isBroadcast {
            let recipientHex = recipientID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            do {
                try transport.send(data: wireData, to: recipientID)
                print("[Blip-TX] SENT \(wireData.count)B (signed) to \(recipientHex)")
                DebugLogger.emit("TX", "SENT \(wireData.count)B → \(recipientHex) (peer-specific)")
            } catch {
                print("[Blip-TX] SEND FAILED to peer: \(error) — falling back to broadcast")
                DebugLogger.emit("TX", "SEND FAILED to \(recipientHex): \(error) — fallback broadcast", isError: true)
                transport.broadcast(data: wireData)
                DebugLogger.emit("TX", "BROADCAST fallback \(wireData.count)B")
            }
        } else {
            transport.broadcast(data: wireData)
            print("[Blip-TX] BROADCAST \(wireData.count)B (signed)")
            DebugLogger.emit("TX", "BROADCAST \(wireData.count)B")
        }
    }

    // MARK: - Private: Handle Received Packets

    /// Handle an incoming announce packet — update the peer's username in PeerStore so
    /// they appear in the "People Nearby" list.
    @MainActor
    private func handleAnnounce(_ packet: Packet, from peerID: PeerID) async throws {
        let context = ModelContext(modelContainer)

        // Parse: username + 0x00 + displayName + 0x00 + noisePublicKey(32 bytes)
        let payload = packet.payload
        let bytes = Array(payload)
        guard let firstSep = bytes.firstIndex(of: 0x00) else { return }
        let username = String(data: Data(bytes[..<firstSep]), encoding: .utf8) ?? ""
        guard !username.isEmpty else { return }

        let afterFirst = firstSep + 1
        var displayName = username
        var realNoiseKey = Data()    // 32-byte Curve25519 noise key
        var realSigningKey = Data()  // 32-byte Ed25519 signing key

        if afterFirst < bytes.count {
            if let secondSep = bytes[afterFirst...].firstIndex(of: 0x00) {
                displayName = String(data: Data(bytes[afterFirst..<secondSep]), encoding: .utf8) ?? username
                let keyStart = secondSep + 1
                if keyStart + 64 <= bytes.count {
                    // Both noise key (32B) and signing key (32B) present
                    realNoiseKey = Data(bytes[keyStart..<keyStart + 32])
                    realSigningKey = Data(bytes[keyStart + 32..<keyStart + 64])
                } else if keyStart + 32 <= bytes.count {
                    // Only noise key (legacy announce without signing key)
                    realNoiseKey = Data(bytes[keyStart..<keyStart + 32])
                }
            } else {
                displayName = String(data: Data(bytes[afterFirst...]), encoding: .utf8) ?? username
            }
        }

        // Fallback: use PeerID bytes if no 32-byte key in payload (legacy announces)
        let noiseKeyToStore = realNoiseKey.isEmpty ? packet.senderID.bytes : realNoiseKey

        let senderData = peerID.bytes
        let peerHex = senderData.prefix(4).map { String(format: "%02x", $0) }.joined()

        // Upsert into PeerStore
        let info = PeerInfo(
            peerID: senderData,
            noisePublicKey: noiseKeyToStore,
            signingPublicKey: realSigningKey,
            username: username,
            rssi: peerStore.peer(for: senderData)?.rssi ?? -60,
            isConnected: true,
            lastSeenAt: Date(),
            hopCount: 1
        )
        peerStore.upsert(peer: info)

        // Create or update User record — always update noisePublicKey to latest
        let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
        if let existingUser = try context.fetch(userDesc).first {
            var updated = false
            // Backfill noisePublicKey: update if empty, or if we now have a real 32-byte key
            // replacing a legacy PeerID-sized placeholder
            if existingUser.noisePublicKey.isEmpty ||
               (realNoiseKey.count == 32 && existingUser.noisePublicKey.count < 32) {
                existingUser.noisePublicKey = noiseKeyToStore
                existingUser.displayName = displayName
                updated = true
                DebugLogger.shared.log("RX", "BACKFILL User.noisePublicKey for \(username)")
            }
            if !realSigningKey.isEmpty && existingUser.signingPublicKey.isEmpty {
                existingUser.signingPublicKey = realSigningKey
                updated = true
            }
            if updated { try context.save() }
        } else {
            let user = User(
                username: username,
                displayName: displayName,
                emailHash: "",
                noisePublicKey: noiseKeyToStore,
                signingPublicKey: realSigningKey
            )
            context.insert(user)
            try context.save()
        }

        // Trigger UI refresh so the peer card appears immediately
        NotificationCenter.default.post(name: .meshPeerStateChanged, object: nil)

        let noisePrefix = noiseKeyToStore.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("RX", "ANNOUNCE ← \(username) from \(peerHex) noiseKey=\(noisePrefix)… sigKey=\(realSigningKey.isEmpty ? "none" : "\(realSigningKey.count)B")")
        logger.debug("Announce received from \(username)")
    }

    // MARK: - Noise Handshake

    /// Handle an incoming Noise XX handshake message.
    ///
    /// The handshake payload carries a 1-byte step indicator:
    /// - `0x01`: message 1 (initiator → responder)
    /// - `0x02`: message 2 (responder → initiator)
    /// - `0x03`: message 3 (initiator → responder)
    @MainActor
    private func handleNoiseHandshake(_ packet: Packet, from peerID: PeerID) async throws {
        guard let sessionManager = noiseSessionManager, let identity = getIdentity() else { return }
        let payload = packet.payload
        guard !payload.isEmpty else { return }

        let step = payload[payload.startIndex]
        let handshakeData = Data(payload.dropFirst())
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        switch step {
        case 0x01:
            // We are responder — receive msg1, send msg2
            DebugLogger.shared.log("NOISE", "← handshake msg1 from \(peerHex)")
            _ = try sessionManager.receiveHandshakeInit(from: peerID, message: handshakeData)
            let msg2 = try sessionManager.respondToHandshake(for: peerID)
            var response = Data([0x02])
            response.append(msg2)
            let responsePacket = buildPacket(
                type: .noiseHandshake,
                payload: response,
                flags: [.hasRecipient],
                senderID: identity.peerID,
                recipientID: peerID
            )
            try sendPacket(responsePacket)
            DebugLogger.shared.log("NOISE", "→ handshake msg2 to \(peerHex)")

        case 0x02:
            // We are initiator — receive msg2, send msg3 (completes handshake)
            DebugLogger.shared.log("NOISE", "← handshake msg2 from \(peerHex)")
            let (_, session) = try sessionManager.processHandshakeMessage(from: peerID, message: handshakeData)
            if session == nil {
                // Need to send msg3
                let (msg3, _) = try sessionManager.completeHandshake(with: peerID)
                var response = Data([0x03])
                response.append(msg3)
                let responsePacket = buildPacket(
                    type: .noiseHandshake,
                    payload: response,
                    flags: [.hasRecipient],
                    senderID: identity.peerID,
                    recipientID: peerID
                )
                try sendPacket(responsePacket)
                DebugLogger.shared.log("NOISE", "→ handshake msg3 to \(peerHex)")
            }
            // Session should now be established (after msg3 was written)
            onSessionEstablished(with: peerID)

        case 0x03:
            // We are responder — receive msg3 (completes handshake)
            DebugLogger.shared.log("NOISE", "← handshake msg3 from \(peerHex)")
            let (_, session) = try sessionManager.processHandshakeMessage(from: peerID, message: handshakeData)
            if session != nil {
                DebugLogger.shared.log("NOISE", "Session established with \(peerHex)")
                onSessionEstablished(with: peerID)
            }

        default:
            DebugLogger.shared.log("NOISE", "Unknown handshake step \(step) from \(peerHex)", isError: true)
        }
    }

    /// Initiate a Noise XX handshake with a peer if one isn't already in progress.
    ///
    /// Returns `true` if a handshake was initiated (message needs queuing),
    /// `false` if a session already exists (can encrypt immediately).
    private func initiateHandshakeIfNeeded(with recipientPeerID: PeerID) throws -> Bool {
        guard let sessionManager = noiseSessionManager, let identity = getIdentity() else {
            return false
        }

        // Already have an active session
        if sessionManager.hasSession(for: recipientPeerID) {
            return false
        }

        // Check if handshake already in progress
        let peerHex = recipientPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let alreadyPending = pendingHandshakeMessages[recipientPeerID.bytes] != nil
        lock.unlock()

        if alreadyPending {
            DebugLogger.emit("NOISE", "Handshake already pending for \(peerHex)")
            return true
        }

        // Start handshake
        let (_, msg1) = try sessionManager.initiateHandshake(with: recipientPeerID)
        var payload = Data([0x01])
        payload.append(msg1)
        let packet = buildPacket(
            type: .noiseHandshake,
            payload: payload,
            flags: [.hasRecipient],
            senderID: identity.peerID,
            recipientID: recipientPeerID
        )
        try sendPacket(packet)
        DebugLogger.emit("NOISE", "→ handshake msg1 to \(peerHex)")

        // Initialize pending queue
        lock.lock()
        if pendingHandshakeMessages[recipientPeerID.bytes] == nil {
            pendingHandshakeMessages[recipientPeerID.bytes] = []
        }
        lock.unlock()

        // Schedule 30-second timeout
        let peerBytes = recipientPeerID.bytes
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.handleHandshakeTimeout(peerIDBytes: peerBytes)
        }

        return true
    }

    /// Called when a Noise session is established — flush all queued messages.
    @MainActor
    private func onSessionEstablished(with peerID: PeerID) {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let pending = pendingHandshakeMessages.removeValue(forKey: peerID.bytes) ?? []
        lock.unlock()

        guard !pending.isEmpty else {
            DebugLogger.shared.log("NOISE", "Session with \(peerHex) ready (no queued messages)")
            return
        }

        DebugLogger.shared.log("NOISE", "Flushing \(pending.count) queued message(s) to \(peerHex)")
        for msg in pending {
            Task { @MainActor in
                do {
                    try await self.encryptAndSend(
                        payload: msg.payload,
                        subType: msg.subType,
                        channel: msg.channel,
                        identity: msg.identity,
                        messageID: msg.messageID
                    )
                    // Update message status from .encrypting to .sent
                    if let messageID = msg.messageID {
                        self.updateMessageStatus(messageID: messageID, to: .sent)
                    }
                } catch {
                    DebugLogger.shared.log("NOISE", "Failed to send queued message: \(error)", isError: true)
                    if let messageID = msg.messageID {
                        self.updateMessageStatus(messageID: messageID, to: .queued)
                    }
                }
            }
        }
    }

    /// Handle handshake timeout — mark pending messages as queued (retry via normal path).
    @MainActor
    private func handleHandshakeTimeout(peerIDBytes: Data) {
        lock.lock()
        let pending = pendingHandshakeMessages.removeValue(forKey: peerIDBytes)
        lock.unlock()

        guard let pending, !pending.isEmpty else { return }

        let peerHex = peerIDBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("NOISE", "Handshake timeout for \(peerHex) — \(pending.count) message(s) reverted to queued", isError: true)

        // Revert messages to queued so retry service picks them up
        for msg in pending {
            if let messageID = msg.messageID {
                updateMessageStatus(messageID: messageID, to: .queued)
            }
        }

        // Clean up the timed-out handshake
        if let peerID = PeerID(bytes: peerIDBytes) {
            noiseSessionManager?.destroySession(for: peerID)
        }
    }

    /// Update a message's status in SwiftData.
    private func updateMessageStatus(messageID: UUID, to status: MessageStatus) {
        let context = ModelContext(modelContainer)
        let targetID = messageID
        let desc = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        if let message = try? context.fetch(desc).first {
            message.statusRaw = status.rawValue
            try? context.save()
        }
    }

    @MainActor
    private func handleEncryptedPacket(_ packet: Packet, from peerID: PeerID) async throws {
        var payload = packet.payload

        // Attempt Noise decryption if we have an active session with this peer
        if let session = noiseSessionManager?.getSession(for: peerID) {
            do {
                payload = try session.decrypt(ciphertext: payload)
                let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.shared.log("NOISE", "Decrypted \(payload.count)B from \(senderHex)")
            } catch {
                // Decryption failed — fall through to try as plaintext (backward compat)
                let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.shared.log("NOISE", "Decryption failed from \(senderHex), trying plaintext: \(error)", isError: true)
            }
        }

        // Decompress if needed
        if packet.flags.contains(.isCompressed) {
            payload = try PayloadCompressor.decompress(payload)
        }

        // Extract sub-type (first byte of decrypted payload)
        guard !payload.isEmpty, let subType = EncryptedSubType(rawValue: payload[payload.startIndex]) else {
            DebugLogger.shared.log("RX", "Encrypted packet with empty/invalid subType", isError: true)
            return
        }
        let contentData = payload.dropFirst()
        let senderHex = packet.senderID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("RX", "ENCRYPTED \(subType) from \(senderHex) (\(contentData.count)B)")

        switch subType {
        case .privateMessage, .groupMessage:
            try await handleIncomingMessage(
                data: Data(contentData),
                subType: subType,
                senderPeerID: packet.senderID,
                timestamp: packet.date
            )
        case .deliveryAck:
            handleDeliveryAck(data: Data(contentData))
        case .readReceipt:
            handleReadReceipt(data: Data(contentData))
        case .typingIndicator:
            handleTypingIndicator(from: packet.senderID, data: Data(contentData))
        case .voiceNote:
            try await handleIncomingMedia(
                data: Data(contentData),
                type: .voiceNote,
                senderPeerID: packet.senderID,
                timestamp: packet.date
            )
        case .imageMessage:
            try await handleIncomingMedia(
                data: Data(contentData),
                type: .image,
                senderPeerID: packet.senderID,
                timestamp: packet.date
            )
        case .friendRequest:
            try await handleFriendRequest(data: Data(contentData), from: packet.senderID)
        case .friendAccept:
            try await handleFriendAccept(data: Data(contentData), from: packet.senderID)
        case .messageDelete:
            try await handleMessageDelete(data: Data(contentData))
        case .messageEdit:
            try await handleMessageEdit(data: Data(contentData))
        case .groupKeyDistribution, .groupMemberAdd, .groupMemberRemove, .groupAdminChange:
            try await handleGroupManagement(subType: subType, data: Data(contentData), from: packet.senderID)
        case .profileRequest, .profileResponse, .blockVote:
            break // Handled elsewhere
        }
    }

    @MainActor
    private func handleIncomingMessage(
        data: Data,
        subType: EncryptedSubType,
        senderPeerID: PeerID,
        timestamp: Date
    ) async throws {
        let senderHex = senderPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleIncomingMessage: \(data.count)B from \(senderHex) subType=\(subType)")

        let context = ModelContext(modelContainer)

        // Parse message ID and content from payload
        let (messageID, content, replyToID) = parseTextPayload(data)
        DebugLogger.shared.log("DM", "Parsed msgID=\(messageID) contentLen=\(content.count) replyTo=\(replyToID?.uuidString ?? "nil")")

        // Check for duplicate
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        let existing = try context.fetch(descriptor)
        if !existing.isEmpty {
            DebugLogger.shared.log("DM", "DUPLICATE msgID=\(messageID) — skipping")
            return
        }

        // Resolve sender (try transport PeerID, then fallback to noisePublicKey)
        let senderPeerData = senderPeerID.bytes
        let peerInfo = peerStore.findPeer(byPeerIDBytes: senderPeerData)
        DebugLogger.shared.log("DM", "Sender lookup: PeerStore=\(peerInfo != nil ? "found (\(peerInfo?.username ?? "no name"))" : "NOT FOUND")")
        let senderUser: User? = peerInfo.flatMap { peer in
            guard let username = peer.username else { return nil }
            let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            do {
                return try context.fetch(userDesc).first
            } catch {
                logger.error("Failed to fetch user for peer username \(username): \(error.localizedDescription)")
                return nil
            }
        }
        DebugLogger.shared.log("DM", "Sender resolution: User=\(senderUser?.username ?? "NOT FOUND")")

        // Resolve channel
        let channel = try resolveChannel(
            for: subType,
            senderPeerID: senderPeerID,
            context: context
        )
        DebugLogger.shared.log("DM", "Channel resolved: \(channel.id) type=\(channel.type)")

        // Create and store message
        let message = Message(
            id: messageID,
            sender: senderUser,
            channel: channel,
            type: .text,
            encryptedPayload: content,
            status: .delivered,
            createdAt: timestamp
        )

        if let replyToID {
            let replyTargetID = replyToID
            let replyDesc = FetchDescriptor<Message>(predicate: #Predicate { $0.id == replyTargetID })
            message.replyTo = try context.fetch(replyDesc).first
        }

        context.insert(message)

        // Update channel activity
        channel.lastActivityAt = Date()
        do {
            try context.save()
            DebugLogger.shared.log("DM", "MSG stored OK: \(messageID) in channel \(channel.id)")
        } catch {
            DebugLogger.shared.log("DM", "MSG STORE FAILED: \(messageID) error=\(error)", isError: true)
            throw error
        }

        // Send delivery ack
        Task { [logger] in
            do {
                try await sendDeliveryAck(for: messageID, to: senderPeerID)
            } catch {
                logger.warning("Failed to send delivery ack for message \(messageID): \(error.localizedDescription)")
                DebugLogger.shared.log("DM", "Delivery ack FAILED for \(messageID): \(error)", isError: true)
            }
        }

        // Notify delegate and post notification for any active ChatViewModel
        delegate?.messageService(self, didReceiveMessage: message, in: channel)
        NotificationCenter.default.post(
            name: .didReceiveBlipMessage,
            object: nil,
            userInfo: [
                "messageID": message.id,
                "channelID": channel.id,
            ]
        )
        DebugLogger.shared.log("RX", "UI notified: msgID=\(messageID) channel=\(channel.id)")
    }

    @MainActor
    private func handleIncomingMedia(
        data: Data,
        type: MessageType,
        senderPeerID: PeerID,
        timestamp: Date
    ) async throws {
        let context = ModelContext(modelContainer)

        guard data.count >= 16 else { return }

        // First 16 bytes: message UUID
        let uuidBytes = data.prefix(16)
        let messageID = UUID(uuidString: uuidBytes.map { String(format: "%02x", $0) }.joined()) ?? UUID()
        let mediaData = data.dropFirst(16)

        let channel = try resolveChannel(
            for: type == .voiceNote ? .voiceNote : .imageMessage,
            senderPeerID: senderPeerID,
            context: context
        )

        let attachmentType: AttachmentType = type == .voiceNote ? .voiceNote : .image
        let mimeType = type == .voiceNote ? "audio/opus" : "image/jpeg"

        let message = Message(
            id: messageID,
            channel: channel,
            type: type == .voiceNote ? .voiceNote : .image,
            encryptedPayload: Data(),
            status: .delivered,
            createdAt: timestamp
        )

        let attachment = Attachment(
            message: message,
            type: attachmentType,
            fullData: Data(mediaData),
            sizeBytes: mediaData.count,
            mimeType: mimeType
        )

        context.insert(message)
        context.insert(attachment)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessage: message, in: channel)
    }

    @MainActor
    private func handleBroadcastMessage(_ packet: Packet) async throws {
        let context = ModelContext(modelContainer)

        let content = packet.payload
        let geohash = extractGeohash(from: content)

        // Find or create location channel
        let channel: Channel
        if let geohash {
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.geohash == geohash })
            if let existing = try context.fetch(descriptor).first {
                channel = existing
            } else {
                channel = Channel(
                    type: .locationChannel,
                    name: "Nearby",
                    geohash: geohash,
                    maxRetention: 86_400, // 24hr
                    isAutoJoined: true
                )
                context.insert(channel)
            }
        } else {
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "locationChannel" })
            if let existing = try context.fetch(descriptor).first {
                channel = existing
            } else {
                channel = Channel(type: .locationChannel, name: "Nearby", isAutoJoined: true)
                context.insert(channel)
            }
        }

        let message = Message(
            channel: channel,
            type: .text,
            encryptedPayload: content,
            status: .delivered,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessage: message, in: channel)
    }

    @MainActor
    private func handleSOSPacket(_ packet: Packet) async throws {
        // SOS packets are forwarded to the SOS subsystem via notification
        NotificationCenter.default.post(
            name: .didReceiveSOSPacket,
            object: nil,
            userInfo: ["packet": packet]
        )
    }

    @MainActor
    private func handleLocationPacket(_ packet: Packet, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceiveLocationPacket,
            object: nil,
            userInfo: ["packet": packet, "peerID": peerID]
        )
    }

    @MainActor
    private func handlePTTAudio(_ packet: Packet, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceivePTTAudio,
            object: nil,
            userInfo: ["packet": packet, "peerID": peerID]
        )
    }

    @MainActor
    private func handleOrgAnnouncement(_ packet: Packet) async throws {
        let context = ModelContext(modelContainer)

        let channel: Channel
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "stageChannel" })
        if let existing = try context.fetch(descriptor).first {
            channel = existing
        } else {
            channel = Channel(type: .stageChannel, name: "Announcements", isAutoJoined: true)
            context.insert(channel)
        }

        let message = Message(
            channel: channel,
            type: .text,
            encryptedPayload: packet.payload,
            status: .delivered,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessage: message, in: channel)
    }

    private func handleDeliveryAck(data: Data) {
        guard let uuidString = String(data: data, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }
        delegate?.messageService(self, didReceiveDeliveryAck: messageID)
    }

    private func handleReadReceipt(data: Data) {
        guard let uuidString = String(data: data, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }
        delegate?.messageService(self, didReceiveReadReceipt: messageID)
    }

    private func handleTypingIndicator(from senderPeerID: PeerID, data: Data) {
        guard let channelIDString = String(data: data, encoding: .utf8),
              let channelID = UUID(uuidString: channelIDString) else { return }
        delegate?.messageService(self, didReceiveTypingIndicatorFrom: senderPeerID, in: channelID)
    }

    @MainActor
    private func handleFriendRequest(data: Data, from peerID: PeerID) async throws {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleFriendRequest: \(data.count)B from \(peerHex)")

        let context = ModelContext(modelContainer)

        // Parse payload: username + 0x00 + displayName
        let (senderUsername, senderDisplayName) = parseFriendPayload(data)
        DebugLogger.shared.log("DM", "FRIEND_REQ from \(senderUsername ?? "nil") display=\(senderDisplayName ?? "nil")")

        // Resolve sender via PeerStore -> User (try peerID then noisePublicKey fallback)
        let peerData = peerID.bytes
        let foundPeer = peerStore.findPeer(byPeerIDBytes: peerData)
        DebugLogger.shared.log("DM", "FRIEND_REQ: PeerStore=\(foundPeer != nil ? "found" : "NOT FOUND") noiseKey=\(foundPeer?.noisePublicKey.count ?? 0)B")

        // Create or find User for the sender
        let senderUser: User
        if let foundPeer {
            senderUser = try resolveOrCreateUser(for: foundPeer, context: context)
            // Update username/display name from payload
            if let name = senderUsername, !name.isEmpty {
                senderUser.username = name
            }
            if let display = senderDisplayName, !display.isEmpty {
                senderUser.displayName = display
            }
        } else if let username = senderUsername, !username.isEmpty {
            // No peer found by peerID — try by username for key lookup
            var fallbackNoiseKey = Data()
            var fallbackSigningKey = Data()
            if let peerByUsername = peerStore.peer(byUsername: username) {
                fallbackNoiseKey = peerByUsername.noisePublicKey
                fallbackSigningKey = peerByUsername.signingPublicKey
                DebugLogger.shared.log("RX", "FRIEND_REQ: pulled keys from PeerStore for fallback User \(username)")
            }

            let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            if let existing = try context.fetch(userDesc).first {
                senderUser = existing
                // Backfill keys if the existing User is missing them
                if existing.noisePublicKey.isEmpty && !fallbackNoiseKey.isEmpty {
                    existing.noisePublicKey = fallbackNoiseKey
                    existing.signingPublicKey = fallbackSigningKey
                    try? context.save()
                    DebugLogger.shared.log("RX", "FRIEND_REQ: backfilled keys on existing User \(username)")
                }
            } else {
                senderUser = User(
                    username: username,
                    displayName: senderDisplayName,
                    emailHash: "",
                    noisePublicKey: fallbackNoiseKey,
                    signingPublicKey: fallbackSigningKey
                )
                context.insert(senderUser)
            }
        } else {
            logger.warning("Received friend request with no parseable sender info")
            return
        }

        // Create Friend record with pending status (or update if exists)
        try createOrUpdateFriend(user: senderUser, status: .pending, context: context)

        logger.info("Received friend request from \(senderUser.username)")

        // Send local push notification
        let senderUserID = senderUser.id
        let friendDesc2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.user?.id == senderUserID })
        if let friendRecord = try? context.fetch(friendDesc2).first {
            NotificationService().notifyFriendRequest(
                fromName: senderUser.resolvedDisplayName,
                friendID: friendRecord.id
            )
        }

        // Notify UI
        NotificationCenter.default.post(
            name: .didReceiveFriendRequest,
            object: nil,
            userInfo: ["data": data, "peerID": peerID, "username": senderUser.username]
        )

        NotificationCenter.default.post(
            name: .friendListDidChange,
            object: nil
        )
    }

    @MainActor
    private func handleFriendAccept(data: Data, from peerID: PeerID) async throws {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleFriendAccept: \(data.count)B from \(peerHex)")

        let context = ModelContext(modelContainer)

        // Parse payload: username
        let (senderUsername, _) = parseFriendPayload(data)
        DebugLogger.shared.log("DM", "FRIEND_ACCEPT from \(senderUsername ?? "nil")")

        // Find the Friend record for this peer (try peerID then noisePublicKey fallback)
        let peerData = peerID.bytes

        var friendUser: User?

        if let acceptPeer = peerStore.findPeer(byPeerIDBytes: peerData) {
            friendUser = try? resolveOrCreateUser(for: acceptPeer, context: context)
            DebugLogger.shared.log("DM", "FRIEND_ACCEPT: resolved user=\(friendUser?.username ?? "nil") via PeerStore")
        }

        // Fallback: find by username
        if friendUser == nil, let username = senderUsername, !username.isEmpty {
            let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            friendUser = try context.fetch(userDesc).first
        }

        guard let resolvedUser = friendUser else {
            logger.warning("Received friend accept from unknown peer")
            return
        }

        // Update Friend status to accepted
        let userID = resolvedUser.id
        let friendDesc = FetchDescriptor<Friend>(predicate: #Predicate {
            $0.user?.id == userID
        })
        if let friend = try context.fetch(friendDesc).first {
            friend.statusRaw = FriendStatus.accepted.rawValue
            try context.save()
        }

        // Ensure user has keys before DM channel creation
        if resolvedUser.noisePublicKey.isEmpty {
            let resolvedUsername = resolvedUser.username
            if let backfillPeer = peerStore.peer(byUsername: resolvedUsername),
               !backfillPeer.noisePublicKey.isEmpty {
                resolvedUser.noisePublicKey = backfillPeer.noisePublicKey
                resolvedUser.signingPublicKey = backfillPeer.signingPublicKey
                try? context.save()
                DebugLogger.shared.log("DM", "Backfilled keys for \(resolvedUsername) before createDMChannel")
            }
        }

        // Create DM channel
        try createDMChannel(with: resolvedUser, context: context)

        logger.info("Friend accept received from \(resolvedUser.username)")

        NotificationCenter.default.post(
            name: .didReceiveFriendAccept,
            object: nil,
            userInfo: ["data": data, "peerID": peerID, "username": resolvedUser.username]
        )

        NotificationCenter.default.post(
            name: .friendListDidChange,
            object: nil
        )
    }

    @MainActor
    private func handleMessageDelete(data: Data) async throws {
        guard let uuidString = String(data: data, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }

        let context = ModelContext(modelContainer)
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        if let message = try context.fetch(descriptor).first {
            context.delete(message)
            try context.save()
        }
    }

    @MainActor
    private func handleMessageEdit(data: Data) async throws {
        // Payload: UUID string (36 bytes) + new content
        guard data.count > 36 else { return }
        let uuidData = data.prefix(36)
        guard let uuidString = String(data: uuidData, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }

        let newContent = Data(data.dropFirst(36))

        let context = ModelContext(modelContainer)
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        if let message = try context.fetch(descriptor).first {
            message.encryptedPayload = newContent
            try context.save()
        }
    }

    @MainActor
    private func handleGroupManagement(subType: EncryptedSubType, data: Data, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceiveGroupManagement,
            object: nil,
            userInfo: ["subType": subType, "data": data, "peerID": peerID]
        )
    }

    // MARK: - Private: Friend Helpers

    /// Parse friend request/accept payload: username + 0x00 + displayName (optional)
    private func parseFriendPayload(_ data: Data) -> (String?, String?) {
        let bytes = [UInt8](data)
        guard let sepIndex = bytes.firstIndex(of: 0x00) else {
            // No separator — entire payload is username
            return (String(data: data, encoding: .utf8), nil)
        }
        let usernameData = Data(bytes[0 ..< sepIndex])
        let username = String(data: usernameData, encoding: .utf8)
        let afterSep = sepIndex + 1
        let displayName: String?
        if afterSep < bytes.count {
            displayName = String(data: Data(bytes[afterSep...]), encoding: .utf8)
        } else {
            displayName = nil
        }
        return (username, displayName)
    }

    /// Resolve or create a User record from a PeerInfo.
    @MainActor
    private func resolveOrCreateUser(for peerInfo: PeerInfo, context: ModelContext) throws -> User {
        // Try matching by noisePublicKey
        let peerKey = peerInfo.noisePublicKey
        let keyDesc = FetchDescriptor<User>(predicate: #Predicate { $0.noisePublicKey == peerKey })
        if let existing = try context.fetch(keyDesc).first {
            return existing
        }

        // Try matching by username
        if let username = peerInfo.username, !username.isEmpty {
            let usernameDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            if let existing = try context.fetch(usernameDesc).first {
                // Update public key if missing
                if existing.noisePublicKey.isEmpty {
                    existing.noisePublicKey = peerInfo.noisePublicKey
                }
                return existing
            }
        }

        // Create new User
        let shortID = peerInfo.peerID.prefix(4).map { String(format: "%02x", $0) }.joined()
        let user = User(
            username: peerInfo.username ?? "peer_\(shortID)",
            displayName: peerInfo.username,
            emailHash: "",
            noisePublicKey: peerInfo.noisePublicKey,
            signingPublicKey: peerInfo.signingPublicKey
        )
        context.insert(user)
        try context.save()
        return user
    }

    /// Create or update a Friend record for a given user.
    @MainActor
    private func createOrUpdateFriend(user: User, status: FriendStatus, context: ModelContext) throws {
        let userID = user.id
        let existingDesc = FetchDescriptor<Friend>(predicate: #Predicate {
            $0.user?.id == userID
        })
        if let existing = try context.fetch(existingDesc).first {
            // Don't downgrade accepted -> pending
            if existing.status != .accepted || status == .accepted {
                existing.statusRaw = status.rawValue
            }
            try context.save()
            return
        }

        let friend = Friend(
            user: user,
            status: status
        )
        context.insert(friend)
        try context.save()
    }

    /// Create a DM channel with the given user if one doesn't already exist.
    @MainActor
    private func createDMChannel(with remoteUser: User, context: ModelContext) throws {
        // Check for existing DM
        let dmDescriptor = FetchDescriptor<Channel>(predicate: #Predicate {
            $0.typeRaw == "dm"
        })
        let existingChannels = try context.fetch(dmDescriptor)
        for channel in existingChannels {
            for membership in channel.memberships {
                if membership.user?.id == remoteUser.id {
                    return // DM already exists
                }
            }
        }

        // Create new DM channel
        let channel = Channel(type: .dm, name: remoteUser.resolvedDisplayName)
        context.insert(channel)

        // Add membership for the remote user
        let membership = GroupMembership(
            user: remoteUser,
            channel: channel,
            role: .member
        )
        context.insert(membership)

        try context.save()
        logger.info("Created DM channel with \(remoteUser.username)")
    }

    // MARK: - Private: Payload Builders

    private func buildTextPayload(content: String, messageID: UUID, replyToID: UUID?) -> Data {
        var payload = Data()
        // Message UUID (36 bytes as UTF-8 string)
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        // Separator byte
        payload.append(0x00)
        // Reply-to UUID (36 bytes or empty)
        if let replyToID {
            payload.append(replyToID.uuidString.data(using: .utf8) ?? Data())
        }
        payload.append(0x00)
        // Content (UTF-8 text)
        payload.append(content.data(using: .utf8) ?? Data())
        return payload
    }

    private func parseTextPayload(_ data: Data) -> (UUID, Data, UUID?) {
        let bytes = [UInt8](data)

        // Find first separator
        var firstSep = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let messageIDBytes = Data(bytes[0 ..< firstSep])
        let messageID = String(data: messageIDBytes, encoding: .utf8).flatMap(UUID.init) ?? UUID()

        // Find second separator
        let afterFirstSep = min(firstSep + 1, bytes.endIndex)
        var secondSep = bytes[afterFirstSep...].firstIndex(of: 0x00) ?? bytes.endIndex
        let replyToBytes = Data(bytes[afterFirstSep ..< secondSep])
        let replyToID: UUID? = String(data: replyToBytes, encoding: .utf8).flatMap(UUID.init)

        // Content
        let contentStart = min(secondSep + 1, bytes.endIndex)
        let content = Data(bytes[contentStart...])

        return (messageID, content, replyToID)
    }

    private struct VoiceNoteMeta {
        let duration: TimeInterval
    }

    private func buildMediaPayload(data: Data, messageID: UUID, mediaMeta: VoiceNoteMeta?) -> Data {
        var payload = Data()
        // Message UUID
        payload.append(messageID.uuidString.data(using: .utf8) ?? Data())
        payload.append(0x00)
        // Duration for voice notes (8 bytes, Double)
        if let meta = mediaMeta {
            var duration = meta.duration
            payload.append(Data(bytes: &duration, count: 8))
        }
        // Media data
        payload.append(data)
        return payload
    }

    private func prependSubType(_ subType: EncryptedSubType, to payload: Data) -> Data {
        var tagged = Data(capacity: 1 + payload.count)
        tagged.append(subType.rawValue)
        tagged.append(payload)
        return tagged
    }

    // MARK: - Private: Packet Builder

    private func buildPacket(
        type: BlipProtocol.MessageType,
        payload: Data,
        flags: PacketFlags,
        senderID: PeerID,
        recipientID: PeerID?
    ) -> Packet {
        var effectiveFlags = flags
        // Strip hasSignature — no signing layer yet. PacketSerializer.encode()
        // throws missingSignature if the flag is set but signature is nil.
        effectiveFlags.remove(.hasSignature)
        if recipientID != nil {
            effectiveFlags.insert(.hasRecipient)
        }

        return Packet(
            type: type,
            ttl: 7,
            timestamp: Packet.currentTimestamp(),
            flags: effectiveFlags,
            senderID: senderID,
            recipientID: recipientID,
            payload: payload,
            signature: nil
        )
    }

    // MARK: - Private: Packet ID for Bloom Filter

    private func buildPacketID(_ packet: Packet) -> Data {
        var idData = Data()
        packet.senderID.appendTo(&idData)
        var ts = packet.timestamp.bigEndian
        idData.append(Data(bytes: &ts, count: 8))
        idData.append(packet.type.rawValue)
        return idData
    }

    // MARK: - Private: Channel Resolution

    @MainActor
    private func resolveChannel(
        for subType: EncryptedSubType,
        senderPeerID: PeerID,
        context: ModelContext
    ) throws -> Channel {
        switch subType {
        case .privateMessage:
            // Find the User for this sender via PeerStore (try peerID then noisePublicKey)
            let peerData = senderPeerID.bytes
            let senderUser: User?
            if let channelPeer = peerStore.findPeer(byPeerIDBytes: peerData),
               !channelPeer.noisePublicKey.isEmpty {
                let noiseKey = channelPeer.noisePublicKey
                let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.noisePublicKey == noiseKey })
                senderUser = try context.fetch(userDesc).first
            } else {
                senderUser = nil
            }

            // Look for existing DM channel with this peer via memberships
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
                $0.typeRaw == "dm"
            })
            let channels = try context.fetch(descriptor)

            if let user = senderUser {
                for ch in channels {
                    for membership in ch.memberships {
                        if membership.user?.id == user.id {
                            return ch
                        }
                    }
                }
            }

            // Create new DM channel with proper membership for the remote user
            let channel = Channel(type: .dm)
            context.insert(channel)
            if let user = senderUser {
                let membership = GroupMembership(user: user, channel: channel)
                context.insert(membership)
            }
            try context.save()
            return channel

        case .groupMessage:
            // Group messages include a channel reference in the payload; fallback to first group
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
                $0.typeRaw == "group"
            })
            if let existing = try context.fetch(descriptor).first {
                return existing
            }
            let channel = Channel(type: .group, name: "Group")
            context.insert(channel)
            return channel

        default:
            // Default to location channel
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
                $0.typeRaw == "locationChannel"
            })
            if let existing = try context.fetch(descriptor).first {
                return existing
            }
            let channel = Channel(type: .locationChannel, name: "Nearby", isAutoJoined: true)
            context.insert(channel)
            return channel
        }
    }

    // MARK: - Private: Recipient Resolution

    private func resolveRecipientPeerID(for channel: Channel) -> PeerID? {
        guard channel.type == .dm else { return nil }

        // Get local identity to filter out self from memberships
        guard let identity = getIdentity() else {
            print("[Blip-TX] ERROR resolveRecipient: no local identity")
            DebugLogger.emit("DM", "resolveRecipient FAILED: no local identity", isError: true)
            return nil
        }
        let localNoiseKey = identity.noisePublicKey.rawRepresentation

        // Fresh-fetch channel in a new context to avoid SwiftData lazy loading
        // returning empty memberships from a stale context
        let freshContext = ModelContext(modelContainer)
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let freshChannel = try? freshContext.fetch(channelDesc).first else {
            print("[Blip-TX] ERROR resolveRecipient: channel not found in fresh context")
            DebugLogger.emit("DM", "resolveRecipient FAILED: channel \(channelID) not found in fresh context", isError: true)
            return nil
        }

        let memberships = freshChannel.memberships
        print("[Blip-TX] resolveRecipient: channel has \(memberships.count) memberships")
        DebugLogger.emit("DM", "resolveRecipient: channel \(channelID) has \(memberships.count) memberships")

        for membership in memberships {
            guard let user = membership.user else {
                DebugLogger.emit("DM", "resolveRecipient: membership has nil user — skipping")
                continue
            }

            let keyLen = user.noisePublicKey.count
            let keyPresent = !user.noisePublicKey.isEmpty
            DebugLogger.emit("DM", "resolveRecipient: checking \(user.username) noiseKey=\(keyPresent ? "\(keyLen)B" : "empty")")

            // Skip local user
            if user.noisePublicKey == localNoiseKey {
                print("[Blip-TX] resolveRecipient: skipping local user \(user.username)")
                DebugLogger.emit("DM", "resolveRecipient: skipping local user \(user.username)")
                continue
            }

            // Skip users with empty keys
            if user.noisePublicKey.isEmpty {
                print("[Blip-TX] resolveRecipient: user \(user.username) has empty noisePublicKey — skipping")
                DebugLogger.emit("DM", "resolveRecipient: \(user.username) has EMPTY noisePublicKey — skipping", isError: true)
                continue
            }

            // Look up PeerStore by noisePublicKey to get BLE transport PeerID
            let userKey = user.noisePublicKey
            if let recipientPeer = peerStore.peer(byNoisePublicKey: userKey) {
                let peerHex = recipientPeer.peerID.prefix(4).map { String(format: "%02x", $0) }.joined()
                print("[Blip-TX] resolveRecipient: resolved \(user.username) → peerID \(peerHex)")
                DebugLogger.emit("DM", "resolveRecipientPeerID: found=\(peerHex) via=ble (\(user.username))")
                return PeerID(bytes: recipientPeer.peerID)
            }

            // Fallback: construct PeerID from stored key
            if user.noisePublicKey.count == PeerID.length {
                print("[Blip-TX] resolveRecipient: using raw key as PeerID for \(user.username)")
                let keyHex = user.noisePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.emit("DM", "resolveRecipientPeerID: found=\(keyHex) via=cache (raw key, \(user.username))")
                return PeerID(bytes: user.noisePublicKey)
            }
            print("[Blip-TX] resolveRecipient: user \(user.username) has key but no peer in PeerStore")
            let derivedHex = user.noisePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
            DebugLogger.emit("DM", "resolveRecipientPeerID: found=\(derivedHex) via=relay (derived, \(user.username))")
            return PeerID(noisePublicKey: user.noisePublicKey)
        }

        print("[Blip-TX] ERROR resolveRecipient: no valid remote user found in channel \(channelID)")
        DebugLogger.emit("DM", "resolveRecipient FAILED: no valid remote user in channel \(channelID)", isError: true)
        return nil
    }

    // MARK: - Private: Retry Queue

    @MainActor
    private func enqueueForRetry(messageID: UUID) async throws {
        let context = ModelContext(modelContainer)
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        guard let message = try context.fetch(descriptor).first else { return }

        let queueEntry = MessageQueue(
            message: message,
            maxAttempts: 50,
            nextRetryAt: Date().addingTimeInterval(2),
            transport: .any
        )
        context.insert(queueEntry)
        try context.save()
    }

    // MARK: - Private: Helpers

    private func getIdentity() -> Identity? {
        lock.lock()
        defer { lock.unlock() }
        return localIdentity
    }

    private func extractGeohash(from data: Data) -> String? {
        // Geohash is encoded as the first 12 bytes of broadcast payload (if present)
        guard data.count >= 12 else { return nil }
        let geohashData = data.prefix(12)
        return String(data: geohashData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }
}

// MARK: - TransportDelegate

extension MessageService: TransportDelegate {

    func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID) {
        Task { @MainActor in
            do {
                try await self.receive(data: data, from: peerID)
            } catch {
                let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                self.logger.error("Failed to process incoming packet: \(error.localizedDescription)")
                DebugLogger.shared.log("RX", "PROCESS FAILED from \(peerHex): \(error)", isError: true)
            }
        }
    }

    func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        let shortID = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            DebugLogger.shared.log("PEER", "CONNECTED: \(shortID)")
            try? await self.broadcastPresence()
        }
    }

    func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        let shortID = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            DebugLogger.shared.log("PEER", "DISCONNECTED: \(shortID)")
        }
    }

    func transport(_ transport: any Transport, didChangeState state: TransportState) {
        // State changes handled by TransportCoordinator; no MessageService action needed.
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let didReceiveSOSPacket = Notification.Name("com.blip.didReceiveSOSPacket")
    static let didReceiveLocationPacket = Notification.Name("com.blip.didReceiveLocationPacket")
    static let didReceivePTTAudio = Notification.Name("com.blip.didReceivePTTAudio")
    static let didReceiveFriendRequest = Notification.Name("com.blip.didReceiveFriendRequest")
    static let didReceiveFriendAccept = Notification.Name("com.blip.didReceiveFriendAccept")
    static let friendListDidChange = Notification.Name("com.blip.friendListDidChange")
    static let didReceiveGroupManagement = Notification.Name("com.blip.didReceiveGroupManagement")
    static let didReceiveBlipMessage = Notification.Name("com.blip.didReceiveMessage")
}
