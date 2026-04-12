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

    enum SendOutcome: Sendable, Equatable {
        case sent
        case deferred(MessageStatus)
    }

    enum PeerIngressTransport: Sendable, Equatable {
        case bluetooth
        case relay
        case unknown

        var peerTransportType: PeerTransportType {
            switch self {
            case .bluetooth:
                return .bluetooth
            case .relay:
                return .relay
            case .unknown:
                return .unknown
            }
        }
    }

    // MARK: - Queues

    /// Queue for message processing (receive pipeline, packet handling).
    private let messageQueue = DispatchQueue(label: "com.blip.messages", qos: .userInitiated)

    /// Queue for encryption/decryption and Noise handshake operations.
    private let encryptionQueue = DispatchQueue(label: "com.blip.encryption", qos: .userInitiated)

    // MARK: - Logging

    let logger = Logger(subsystem: "com.blip", category: "MessageService")

    // MARK: - Dependencies

    let modelContainer: ModelContainer
    private let keyManager: KeyManager
    private let bloomFilter: MultiTierBloomFilter
    let peerStore: PeerStore
    weak var delegate: (any MessageServiceDelegate)?
    private var deliveryFailureObservation: NSObjectProtocol?

    // Transport reference (set externally after initialization)
    private var transport: (any Transport)?

    // MARK: - Fragment Reassembly

    /// Reassembles incoming fragment packets into complete payloads.
    private let fragmentAssembler = FragmentAssembler()

    // MARK: - Noise Sessions

    /// Manages Noise XX handshakes and active encrypted sessions.
    var noiseSessionManager: NoiseSessionManager?

    /// Messages queued while waiting for a Noise handshake to complete.
    var pendingHandshakeMessages: [Data: [PendingEncryptedMessage]] = [:]

    /// Control packets queued while waiting for a Noise handshake to complete.
    var pendingHandshakeControlMessages: [Data: [PendingEncryptedControlMessage]] = [:]

    /// A message waiting for a Noise session to be established before it can be encrypted.
    struct PendingEncryptedMessage {
        let payload: Data
        let subType: EncryptedSubType
        let channel: Channel
        let identity: Identity
        let messageID: UUID?
    }

    /// A control packet waiting for a Noise session before it can be encrypted.
    struct PendingEncryptedControlMessage {
        let payload: Data
        let subType: EncryptedSubType
        let identity: Identity
        let flags: PacketFlags
    }

    // MARK: - State

    let lock = NSLock()
    private var localIdentity: Identity?

    // Typing indicator debounce tracking: channelID -> last sent timestamp
    private var lastTypingIndicatorSent: [UUID: Date] = [:]
    private let typingIndicatorInterval: TimeInterval = 3.0

    /// Debounce for broadcastPresence() — prevents announce storms from rapid CONNECTED events.
    private var lastBroadcastTime: Date?
    private let broadcastDebounceInterval: TimeInterval = 1.0

    // MARK: - Sender Binding (BDEV-86)

    /// Maps a delivering transport PeerID → the first claimed sender PeerID from that connection.
    /// Once bound, any packet from that transport PeerID claiming a different sender is dropped.
    private var senderBindings: [Data: Data] = [:]

    /// Counts unverified packets per sender (no signing key yet). Drop after threshold.
    private var unverifiedPacketCounts: [Data: Int] = [:]
    private static let maxUnverifiedPackets = 5

    /// Consecutive Noise decrypt failures per sender PeerID bytes.
    var decryptFailureCounts: [Data: Int] = [:]

    /// Last time automatic Noise session recovery was attempted for a sender.
    var lastRecoveryAttempt: [Data: Date] = [:]

    /// Check if an encrypted packet carries a friend request or accept payload.
    /// These are exempt from the unverified packet counter because they arrive
    /// before the peer has announced (no signing key available yet).
    private static func isHandshakeRelatedEncrypted(_ packet: Packet) -> Bool {
        guard packet.type == .noiseEncrypted, let firstByte = packet.payload.first else {
            return false
        }
        let subType = EncryptedSubType(rawValue: firstByte)
        return subType == .friendRequest || subType == .friendAccept
    }

    // MARK: - Constants

    /// Maximum text payload size in bytes (UTF-8).
    private static let maxTextPayloadSize = 4096

    /// Consecutive decrypt failures required before attempting session recovery.
    static let decryptFailureRecoveryThreshold = 3

    /// Minimum interval between automatic session recovery attempts for one peer.
    static let decryptFailureRecoveryCooldown: TimeInterval = 30

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
        self.deliveryFailureObservation = NotificationCenter.default.addObserver(
            forName: .didFailMessageDelivery,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleDeliveryFailureNotification(notification)
            }
        }
    }

    deinit {
        if let deliveryFailureObservation {
            NotificationCenter.default.removeObserver(deliveryFailureObservation)
        }
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

        // Re-fetch Channel in this context to avoid cross-context insert crash
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let localChannel = try context.fetch(channelDesc).first else {
            throw MessageServiceError.channelNotFound
        }

        // Re-fetch replyTo in this context if present
        var localReplyTo: Message?
        if let replyTo {
            let replyToID = replyTo.id
            let replyDesc = FetchDescriptor<Message>(predicate: #Predicate { $0.id == replyToID })
            localReplyTo = try context.fetch(replyDesc).first
        }

        // Create the message model
        let message = Message(
            sender: nil, // Local user, resolved via identity
            channel: localChannel,
            type: .text,
            rawPayload: content.data(using: .utf8) ?? Data(),
            status: .queued,
            replyTo: localReplyTo,
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
        let payload: Data
        if localChannel.isGroup {
            payload = MessagePayloadBuilder.buildGroupTextPayload(
                content: content,
                channelID: localChannel.id,
                messageID: message.id,
                replyToID: replyTo?.id
            )
        } else {
            payload = MessagePayloadBuilder.buildTextPayload(
                content: content,
                messageID: message.id,
                replyToID: replyTo?.id
            )
        }
        let sendOutcome: SendOutcome
        do {
            sendOutcome = try await encryptAndSend(
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

        switch sendOutcome {
        case .sent:
            message.status = .sent
        case .deferred(let status):
            message.status = status
        }
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

        // Re-fetch Channel in this context to avoid cross-context insert crash
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let localChannel = try context.fetch(channelDesc).first else {
            throw MessageServiceError.channelNotFound
        }

        let message = Message(
            channel: localChannel,
            type: .voiceNote,
            rawPayload: Data(),
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

        let payload = MessagePayloadBuilder.buildMediaPayload(data: audioData, messageID: message.id, duration: duration)
        let sendOutcome = try await encryptAndSend(
            payload: payload,
            subType: .voiceNote,
            channel: channel,
            identity: identity,
            messageID: message.id
        )

        switch sendOutcome {
        case .sent:
            message.status = .sent
        case .deferred(let status):
            message.status = status
        }
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

        // Re-fetch Channel in this context to avoid cross-context insert crash
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let localChannel = try context.fetch(channelDesc).first else {
            throw MessageServiceError.channelNotFound
        }

        let message = Message(
            channel: localChannel,
            type: .image,
            rawPayload: Data(),
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

        let payload = MessagePayloadBuilder.buildMediaPayload(data: imageData, messageID: message.id, duration: nil)
        let sendOutcome = try await encryptAndSend(
            payload: payload,
            subType: .imageMessage,
            channel: channel,
            identity: identity,
            messageID: message.id
        )

        switch sendOutcome {
        case .sent:
            message.status = .sent
        case .deferred(let status):
            message.status = status
        }
        try context.save()

        return message
    }

    /// Send a typing indicator to a channel.
    @MainActor
    func sendTypingIndicator(to channel: Channel) async throws {
        guard let identity = getIdentity() else { return }

        // Debounce: only send every 3 seconds
        let shouldSkip: Bool = lock.withLock {
            let lastSent = lastTypingIndicatorSent[channel.id]
            let now = Date()
            if let lastSent, now.timeIntervalSince(lastSent) < typingIndicatorInterval {
                return true
            }
            lastTypingIndicatorSent[channel.id] = now
            return false
        }
        if shouldSkip { return }

        // Re-fetch channel in a fresh context to avoid cross-context crash
        let context = ModelContext(modelContainer)
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let localChannel = try context.fetch(channelDesc).first else {
            DebugLogger.emit("DM", "sendTypingIndicator: channel \(channelID) not found in fresh context", isError: true)
            return
        }

        var payload = Data()
        payload.append(localChannel.id.uuidString.data(using: .utf8) ?? Data())

        _ = try await encryptAndSend(
            payload: payload,
            subType: .typingIndicator,
            channel: localChannel,
            identity: identity,
            messageID: nil
        )
    }

    /// Send a delivery acknowledgement for a received message.
    ///
    /// Encrypts through the active Noise session or queues behind handshake
    /// establishment. This avoids sending plaintext tagged as `.noiseEncrypted`,
    /// which would desynchronize session nonces.
    @MainActor
    func sendDeliveryAck(for messageID: UUID, to peerID: PeerID) async throws {
        guard let identity = getIdentity() else { return }
        guard let payload = messageID.uuidString.data(using: .utf8) else {
            DebugLogger.shared.log("CRYPTO", "deliveryAck payload encoding failed for \(messageID)", isError: true)
            throw MessageServiceError.encryptionFailed("Failed to encode delivery acknowledgement payload")
        }

        try await sendEncryptedControl(
            payload: payload,
            subType: .deliveryAck,
            to: peerID,
            identity: identity,
            flags: [.hasRecipient, .hasSignature, .isReliable]
        )
    }

    /// Send a read receipt for a message.
    ///
    /// Encrypts through the active Noise session or queues behind handshake
    /// establishment. This avoids sending plaintext tagged as `.noiseEncrypted`,
    /// which would desynchronize session nonces.
    @MainActor
    func sendReadReceipt(for messageID: UUID, to peerID: PeerID) async throws {
        guard let identity = getIdentity() else { return }
        guard let payload = messageID.uuidString.data(using: .utf8) else {
            DebugLogger.shared.log("CRYPTO", "readReceipt payload encoding failed for \(messageID)", isError: true)
            throw MessageServiceError.encryptionFailed("Failed to encode read receipt payload")
        }

        try await sendEncryptedControl(
            payload: payload,
            subType: .readReceipt,
            to: peerID,
            identity: identity,
            flags: [.hasRecipient, .hasSignature]
        )
    }

    // See MessageService+FriendRequests.swift and MessageService+Handshake.swift


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

        let packet = MessagePayloadBuilder.buildPacket(
            type: .announce,
            payload: payload,
            flags: [],
            senderID: identity.peerID,
            recipientID: nil
        )

        try await sendPacket(packet)
        DebugLogger.shared.log("TX", "ANNOUNCE → \(DebugLogger.redact(localUser.username))")
    }

    // MARK: - Receive Message

    /// Process incoming raw data from the transport layer.
    ///
    /// Flow: deserialize (messageQueue) -> verify -> deduplicate -> route to handler (MainActor for DB)
    func receive(data: Data, from peerID: PeerID, via ingressTransport: PeerIngressTransport) {
        let transportData = peerID.bytes
        let peerHex = transportData.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.emit("RX", "receive(): \(data.count)B from \(peerHex)", level: .verbose)

        messageQueue.async { [weak self] in
            guard let self else { return }

            // Deserialize the packet (CPU-bound, off main)
            let packet: Packet
            do {
                packet = try PacketSerializer.decode(data)
                DebugLogger.emit("RX", "Decoded packet: type=\(packet.type) flags=\(packet.flags)", level: .verbose)
            } catch {
                DebugLogger.emit("RX", "DESERIALIZE FAILED: \(error)", isError: true)
                return
            }

            // BDEV-86: Sender binding check
            let claimedSender = packet.senderID.bytes
            let claimedHex = claimedSender.prefix(4).map { String(format: "%02x", $0) }.joined()
            let boundSender = self.lock.withLock { self.senderBindings[transportData] }
            if let boundSender, boundSender != claimedSender {
                let boundHex = boundSender.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.emit("RX", "⚠️ SENDER MISMATCH: transport=\(peerHex) bound=\(boundHex) claimed=\(claimedHex) — DROPPED", isError: true)
                return
            }

            // Verify Ed25519 signature (crypto-bound, off main)
            if packet.flags.contains(.hasSignature) {
                let senderData = packet.senderID.bytes
                let senderHex = senderData.prefix(4).map { String(format: "%02x", $0) }.joined()
                let signingKey: Data?

                if let peerInfo = self.peerStore.findPeer(byPeerIDBytes: senderData),
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
                            DebugLogger.emit("RX", "SIG INVALID from \(senderHex) key=\(keyPrefix) — dropped", isError: true)
                            return
                        }
                        DebugLogger.emit("RX", "SIG OK from \(senderHex) key=\(keyPrefix)", level: .verbose)
                        self.lock.withLock { _ = self.unverifiedPacketCounts.removeValue(forKey: senderData) }
                    } catch {
                        DebugLogger.emit("RX", "SIG CHECK ERROR from \(senderHex): \(error) — accepting", isError: true)
                    }
                } else {
                    // Exempt handshake and friend request/accept packets from the
                    // unverified limit — these arrive before the peer has announced
                    // and must not consume the budget meant for data packets.
                    let hasNoiseSession = packet.type == .noiseEncrypted
                        && self.noiseSessionManager?.hasSession(for: packet.senderID) == true
                    let isExempt = packet.type == .noiseHandshake
                        || Self.isHandshakeRelatedEncrypted(packet)
                        || hasNoiseSession

                    if !isExempt {
                        let count: Int = self.lock.withLock {
                            let c = (self.unverifiedPacketCounts[senderData] ?? 0) + 1
                            self.unverifiedPacketCounts[senderData] = c
                            return c
                        }
                        if count > Self.maxUnverifiedPackets {
                            DebugLogger.emit("RX", "UNVERIFIED LIMIT: \(senderHex) sent \(count) packets without announcing — DROPPED", isError: true)
                            return
                        }
                        DebugLogger.emit("RX", "No signing key for \(senderHex) — accepting unverified (\(count)/\(Self.maxUnverifiedPackets))", level: .debug)
                    } else {
                        DebugLogger.emit("RX", "No signing key for \(senderHex) — exempt (handshake/friend)", level: .debug)
                    }
                }
            }

            // Deduplicate via Bloom filter
            let packetIDData = MessagePayloadBuilder.buildPacketID(packet)
            if self.bloomFilter.contains(packetIDData) {
                DebugLogger.emit("RX", "DUPLICATE packet — skipping", level: .verbose)
                return
            }
            self.bloomFilter.insert(packetIDData)
            DebugLogger.emit("RX", "Bloom: new packet, inserted", level: .verbose)

            // Dispatch handler to MainActor for SwiftData writes
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    switch packet.type {
                    case .announce:
                        try await self.handleAnnounce(packet, from: peerID, ingressTransport: ingressTransport)
                    case .noiseHandshake:
                        try await self.handleNoiseHandshake(packet, from: peerID)
                    case .noiseEncrypted:
                        try await self.handleEncryptedPacket(packet, from: peerID)
                    case .meshBroadcast:
                        try await self.handleBroadcastMessage(packet)
                    case .sosAlert, .sosAccept, .sosPreciseLocation, .sosResolve, .sosNearbyAssist:
                        try await self.handleSOSPacket(packet)
                    case .locationShare, .locationRequest, .proximityPing, .iAmHereBeacon:
                        try await self.handleLocationPacket(packet, from: peerID)
                    case .pttAudio:
                        try await self.handlePTTAudio(packet, from: peerID)
                    case .orgAnnouncement:
                        try await self.handleOrgAnnouncement(packet)
                    case .leave:
                        self.handleLeave(packet)
                    case .fragment:
                        self.handleFragment(packet, from: peerID, ingressTransport: ingressTransport)
                    case .syncRequest:
                        self.handleSyncRequest(packet, from: peerID)
                    case .fileTransfer:
                        self.handleFileTransfer(packet, from: peerID)
                    case .channelUpdate:
                        self.handleChannelUpdate(packet)
                    }
                } catch {
                    let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                    DebugLogger.shared.log("RX", "HANDLER FAILED from \(peerHex): \(error)", isError: true)
                }
            }
        }
    }

    // MARK: - Edit / Delete

    /// Send a message edit to the remote peer.
    @MainActor
    func sendMessageEdit(messageID: UUID, newContent: String, to channel: Channel) async throws {
        guard let identity = try KeyManager.shared.loadIdentity() else {
            DebugLogger.shared.log("DM", "Cannot send edit: no identity", isError: true)
            return
        }
        var payload = Data(messageID.uuidString.utf8)
        payload.append(newContent.data(using: .utf8) ?? Data())
        _ = try await encryptAndSend(
            payload: payload,
            subType: .messageEdit,
            channel: channel,
            identity: identity,
            messageID: messageID,
            shouldEnqueueForRetry: false
        )
    }

    /// Send a message delete to the remote peer.
    @MainActor
    func sendMessageDelete(messageID: UUID, to channel: Channel) async throws {
        guard let identity = try KeyManager.shared.loadIdentity() else {
            DebugLogger.shared.log("DM", "Cannot send delete: no identity", isError: true)
            return
        }
        let payload = Data(messageID.uuidString.utf8)
        _ = try await encryptAndSend(
            payload: payload,
            subType: .messageDelete,
            channel: channel,
            identity: identity,
            messageID: messageID,
            shouldEnqueueForRetry: false
        )
    }

    // MARK: - Private: Encrypt and Send

    @MainActor
    func encryptAndSend(
        payload: Data,
        subType: EncryptedSubType,
        channel: Channel,
        identity: Identity,
        messageID: UUID?,
        shouldEnqueueForRetry: Bool = true
    ) async throws -> SendOutcome {
        DebugLogger.emit("DM", "encryptAndSend: subType=\(subType) payloadSize=\(payload.count)", level: .verbose)
        let taggedPayload = MessagePayloadBuilder.prependSubType(subType, to: payload)

        // Determine compression: skip for pre-compressed types
        let isPreCompressed = (subType == .voiceNote || subType == .imageMessage)
        let compressed = PayloadCompressor.compressIfNeeded(taggedPayload, isPreCompressed: isPreCompressed)

        let ratio = taggedPayload.count > 0 ? Double(compressed.data.count) / Double(taggedPayload.count) : 1.0
        DebugLogger.emit("TX", "Compression: \(taggedPayload.count)B → \(compressed.data.count)B (ratio=\(String(format: "%.2f", ratio)), compressed=\(compressed.wasCompressed))", level: .verbose)

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
                DebugLogger.emit("DM", "encryptAndSend: Noise encrypted \(compressed.data.count)B → \(ciphertext.count)B → \(recipientHex)", level: .verbose)

                let packet = MessagePayloadBuilder.buildPacket(
                    type: .noiseEncrypted,
                    payload: ciphertext,
                    flags: flags,
                    senderID: identity.peerID,
                    recipientID: recipientPeerID
                )
                try await sendPacket(packet)
                return .sent
            } else if try await initiateHandshakeIfNeeded(with: recipientPeerID) {
                // Handshake initiated — queue this message
                DebugLogger.emit("DM", "encryptAndSend: queuing message for \(recipientHex) pending handshake", level: .debug)
                let pending = PendingEncryptedMessage(
                    payload: payload,
                    subType: subType,
                    channel: channel,
                    identity: identity,
                    messageID: messageID
                )
                lock.withLock {
                    pendingHandshakeMessages[recipientPeerID.bytes, default: []].append(pending)
                }

                // Mark message as encrypting
                if let messageID {
                    updateMessageStatus(messageID: messageID, to: .encrypting)
                }
                return .deferred(.encrypting) // Don't enqueue for retry — the handshake callback will handle it
            } else {
                // No session and handshake could not be initiated — refuse to send plaintext.
                // Messages will be retried by MessageRetryService when a session is established.
                DebugLogger.emit("DM", "encryptAndSend: no Noise session and handshake failed for \(recipientHex) — message queued for retry", isError: true)
                if let messageID {
                    updateMessageStatus(messageID: messageID, to: .queued)
                }
            }
        } else {
            // Group/channel: broadcast (no Noise encryption for groups yet)
            DebugLogger.emit("TX", "BROADCAST \(subType) (\(compressed.data.count)B)")
            let packet = MessagePayloadBuilder.buildPacket(
                type: .noiseEncrypted,
                payload: compressed.data,
                flags: flags,
                senderID: identity.peerID,
                recipientID: nil
            )
            try await sendPacket(packet)
            return .sent
        }

        // Enqueue for retry if needed
        if shouldEnqueueForRetry, let messageID {
            try await enqueueForRetry(messageID: messageID)
        }

        return .deferred(.queued)
    }

    /// Sign, encode, and transmit a packet. Dispatches signing + encoding to
    /// the encryption queue to keep the main thread free.
    func sendPacket(_ packet: Packet) async throws {
        guard let transport else {
            DebugLogger.emit("TX", "SEND FAILED: no transport available", isError: true)
            throw MessageServiceError.noTransportAvailable
        }

        // Sign + encode on encryptionQueue (CPU-bound crypto)
        let (wireData, signedPacket) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Packet), Error>) in
            encryptionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MessageServiceError.noTransportAvailable)
                    return
                }
                let signed: Packet
                if let identity = self.getIdentity() {
                    do {
                        signed = try Signer.sign(packet: packet, secretKey: identity.signingSecretKey)
                        DebugLogger.emit("TX", "Ed25519 signing OK", level: .verbose)
                    } catch {
                        DebugLogger.emit("TX", "Ed25519 SIGNING FAILED: \(error) — sending unsigned", isError: true)
                        CrashReportingService.shared.captureError(error, context: ["operation": "ed25519_sign"])
                        signed = packet
                    }
                } else {
                    signed = packet
                }

                do {
                    let data = try PacketSerializer.encode(signed)
                    continuation.resume(returning: (data, signed))
                } catch {
                    DebugLogger.emit("TX", "ENCODE FAILED: \(error)", isError: true)
                    CrashReportingService.shared.captureError(error, context: ["operation": "packet_encode"])
                    continuation.resume(throwing: error)
                }
            }
        }

        // Transport send (thread-safe)
        if let recipientID = signedPacket.recipientID, !recipientID.isBroadcast {
            let recipientHex = recipientID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            do {
                try transport.send(data: wireData, to: recipientID)
                DebugLogger.emit("TX", "SENT \(wireData.count)B → \(recipientHex) (peer-specific)", level: .verbose)
            } catch {
                DebugLogger.emit("TX", "SEND FAILED to \(recipientHex): \(error) — fallback broadcast", isError: true)
                transport.broadcast(data: wireData)
                DebugLogger.emit("TX", "BROADCAST fallback \(wireData.count)B", level: .verbose)
            }
        } else {
            transport.broadcast(data: wireData)
            DebugLogger.emit("TX", "BROADCAST \(wireData.count)B", level: .verbose)
        }
    }

    // MARK: - Private: Handle Received Packets

    /// Handle an incoming announce packet — update the peer's username in PeerStore so
    /// they appear in the "People Nearby" list.
    @MainActor
    private func handleAnnounce(
        _ packet: Packet,
        from peerID: PeerID,
        ingressTransport: PeerIngressTransport
    ) async throws {
        // BDEV-87: Reject stale or future-dated announces
        let announceAge = Date().timeIntervalSince(packet.date)
        if announceAge > 900 {
            let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            DebugLogger.shared.log("RX", "STALE ANNOUNCE from \(peerHex) — \(Int(announceAge))s old, dropping", isError: true)
            return
        }
        if announceAge < -60 {
            let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            DebugLogger.shared.log("RX", "FUTURE ANNOUNCE from \(peerHex) — \(Int(-announceAge))s ahead, dropping", isError: true)
            return
        }

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
        let peerTransportType = ingressTransport.peerTransportType
        let hopCount = ingressTransport == .bluetooth ? 1 : max(2, 8 - Int(packet.ttl))

        // BDEV-86: Bind transport PeerID → claimed sender on first DIRECT announce.
        // Direct = TTL still at max (7), meaning not decremented by a relay hop.
        let transportData = peerID.bytes
        let claimedSender = packet.senderID.bytes
        if packet.ttl == 7 {
            if let boundSender = senderBindings[transportData] {
                if boundSender != claimedSender {
                    let boundHex = boundSender.prefix(4).map { String(format: "%02x", $0) }.joined()
                    let claimedHex = claimedSender.prefix(4).map { String(format: "%02x", $0) }.joined()
                    DebugLogger.shared.log("RX", "⚠️ ANNOUNCE BINDING MISMATCH: transport=\(peerHex) bound=\(boundHex) claimed=\(claimedHex) — DROPPED", isError: true)
                    return
                }
            } else {
                senderBindings[transportData] = claimedSender
                let claimedHex = claimedSender.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.shared.log("RX", "SENDER BOUND: transport=\(peerHex) → sender=\(claimedHex) (\(DebugLogger.redact(username)))")
                // Announce carries the signing key — reset unverified counter
                unverifiedPacketCounts.removeValue(forKey: claimedSender)
            }
        }

        // Upsert into PeerStore
        let info = PeerInfo(
            peerID: senderData,
            noisePublicKey: noiseKeyToStore,
            signingPublicKey: realSigningKey,
            username: username,
            rssi: peerTransportType == .bluetooth
                ? (peerStore.peer(for: senderData)?.rssi ?? PeerInfo.noSignalRSSI)
                : PeerInfo.noSignalRSSI,
            isConnected: true,
            lastSeenAt: Date(),
            hopCount: hopCount,
            lastAnnounceTimestamp: packet.timestamp,
            transportType: peerTransportType
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
                DebugLogger.shared.log("RX", "BACKFILL User.noisePublicKey for \(DebugLogger.redact(username))")
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
        DebugLogger.shared.log("RX", "ANNOUNCE ← \(DebugLogger.redact(username)) from \(peerHex) noiseKey=\(DebugLogger.redactHex(noisePrefix))… sigKey=\(realSigningKey.isEmpty ? "none" : "\(realSigningKey.count)B")")
        logger.debug("Announce received from \(username)")
    }

    // See MessageService+FriendRequests.swift and MessageService+Handshake.swift

    // MARK: - Leave

    private func handleLeave(_ packet: Packet) {
        let senderBytes = packet.senderID.bytes
        let senderHex = senderBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.emit("PEER", "Received LEAVE from \(senderHex) — marking disconnected")
        peerStore.markDisconnected(peerID: senderBytes)
    }

    // MARK: - Fragment Reassembly

    private func handleFragment(
        _ packet: Packet,
        from peerID: PeerID,
        ingressTransport: PeerIngressTransport
    ) {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        guard let fragment = Fragment.parse(packet.payload) else {
            DebugLogger.emit("RX", "FRAGMENT from \(senderHex): failed to parse header", isError: true)
            return
        }

        let fragIDHex = fragment.fragmentID.prefix(2).map { String(format: "%02x", $0) }.joined()
        DebugLogger.emit("RX", "FRAGMENT from \(senderHex): id=\(fragIDHex) \(fragment.index + 1)/\(fragment.total)")

        do {
            let result = try fragmentAssembler.receive(fragment)
            switch result {
            case .incomplete(let received, let total):
                DebugLogger.emit("RX", "FRAGMENT assembly \(fragIDHex): \(received)/\(total)")
            case .complete(let reassembled):
                DebugLogger.emit("RX", "FRAGMENT assembly \(fragIDHex): COMPLETE (\(reassembled.count) bytes) — re-dispatching")
                // Re-dispatch the reassembled data through the normal receive pipeline
                receive(data: reassembled, from: peerID, via: ingressTransport)
            }
        } catch {
            DebugLogger.emit("RX", "FRAGMENT assembly error: \(error)", isError: true)
        }
    }

    // MARK: - Sync Request (stub)

    private func handleSyncRequest(_ packet: Packet, from peerID: PeerID) {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let payloadSize = packet.payload.count
        DebugLogger.emit("SYNC", "Received syncRequest from \(senderHex) (\(payloadSize) bytes) — not yet implemented")
    }

    // MARK: - File Transfer (stub)

    private func handleFileTransfer(_ packet: Packet, from peerID: PeerID) {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let payloadSize = packet.payload.count
        DebugLogger.emit("RX", "Received fileTransfer from \(senderHex) (\(payloadSize) bytes) — not yet implemented")
    }

    // MARK: - Channel Update (stub)

    private func handleChannelUpdate(_ packet: Packet) {
        let senderHex = packet.senderID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let payloadSize = packet.payload.count
        DebugLogger.emit("RX", "Received channelUpdate from \(senderHex) (\(payloadSize) bytes) — not yet implemented")
    }

    func handleDeliveryAck(data: Data) {
        guard let uuidString = String(data: data, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }
        delegate?.messageService(self, didReceiveDeliveryAck: messageID)
    }

    func handleReadReceipt(data: Data) {
        guard let uuidString = String(data: data, encoding: .utf8),
              let messageID = UUID(uuidString: uuidString) else { return }
        delegate?.messageService(self, didReceiveReadReceipt: messageID)
    }

    func handleTypingIndicator(from senderPeerID: PeerID, data: Data) {
        guard let channelIDString = String(data: data, encoding: .utf8),
              let channelID = UUID(uuidString: channelIDString) else { return }
        delegate?.messageService(self, didReceiveTypingIndicatorFrom: senderPeerID, in: channelID)
    }

    // MARK: - Private: Channel Resolution

    @MainActor
    func resolveChannel(
        for subType: EncryptedSubType,
        senderPeerID: PeerID,
        context: ModelContext
    ) throws -> (Channel, User?) {
        switch subType {
        case .privateMessage:
            // Resolve the User who sent this DM. Three fallback strategies:
            // 1. PeerStore lookup (fast path — works when announce arrived first)
            // 2. Noise session remote static key (works for relay-first DMs)
            // 3. Derived PeerID scan across all known Users (last resort)
            let peerData = senderPeerID.bytes
            var senderUser: User?

            // 1. PeerStore lookup
            if let channelPeer = peerStore.findPeer(byPeerIDBytes: peerData),
               !channelPeer.noisePublicKey.isEmpty {
                let noiseKey = channelPeer.noisePublicKey
                let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.noisePublicKey == noiseKey })
                senderUser = try context.fetch(userDesc).first
                if senderUser != nil {
                    DebugLogger.emit("DM", "resolveChannel: found sender via PeerStore")
                }
            }

            // 2. Noise session fallback — the handshake completed so we have the remote static key
            if senderUser == nil, let session = noiseSessionManager?.getSession(for: senderPeerID) {
                let noiseKeyData = session.remoteStaticKey.rawRepresentation
                let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.noisePublicKey == noiseKeyData })
                do {
                    senderUser = try context.fetch(userDesc).first
                    if senderUser != nil {
                        DebugLogger.emit("DM", "resolveChannel: found sender via Noise session remote key")
                    }
                } catch {
                    DebugLogger.emit("DM", "resolveChannel: Noise session user lookup failed: \(error.localizedDescription)", isError: true)
                }
            }

            // 3. Derived PeerID scan — compute PeerID from each User's noisePublicKey and compare
            if senderUser == nil {
                let allUsersDesc = FetchDescriptor<User>()
                do {
                    let allUsers = try context.fetch(allUsersDesc)
                    for candidate in allUsers where !candidate.noisePublicKey.isEmpty {
                        let derivedID = PeerID(noisePublicKey: candidate.noisePublicKey)
                        if derivedID == senderPeerID {
                            senderUser = candidate
                            DebugLogger.emit("DM", "resolveChannel: found sender via derived PeerID scan (\(candidate.username))")

                            // Back-fill PeerStore so future lookups use the fast path
                            let peerInfo = PeerInfo(
                                peerID: senderPeerID.bytes,
                                noisePublicKey: candidate.noisePublicKey,
                                signingPublicKey: candidate.signingPublicKey,
                                username: candidate.username,
                                rssi: -100,
                                isConnected: false,
                                lastSeenAt: Date(),
                                hopCount: 0
                            )
                            peerStore.upsert(peer: peerInfo)
                            break
                        }
                    }
                } catch {
                    DebugLogger.emit("DM", "resolveChannel: derived PeerID scan failed: \(error.localizedDescription)", isError: true)
                }
            }

            if let user = senderUser {
                return (try findOrCreateDMChannel(with: user, context: context), user)
            }

            // All resolution paths failed — reuse an existing orphan DM channel if one exists,
            // otherwise create one (will be repaired once the sender's identity is resolved).
            DebugLogger.emit("DM", "resolveChannel: all sender resolution failed for \(senderPeerID) — using anonymous channel", isError: true)
            let orphanDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
            let dmChannels = try context.fetch(orphanDesc)
            if let orphan = dmChannels.first(where: { $0.memberships.isEmpty && $0.name == nil }) {
                return (orphan, nil)
            }
            let channel = Channel(type: .dm, name: nil)
            context.insert(channel)
            try context.save()
            return (channel, nil)

        case .groupMessage:
            DebugLogger.emit("GROUP", "resolveChannel called for groupMessage without a channel ID", isError: true)
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "group" })
            if let existing = try context.fetch(descriptor).first {
                return (existing, nil)
            }
            let channel = Channel(type: .group, name: "Group")
            context.insert(channel)
            return (channel, nil)

        default:
            // Default to location channel
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
                $0.typeRaw == "locationChannel"
            })
            if let existing = try context.fetch(descriptor).first {
                return (existing, nil)
            }
            let channel = Channel(type: .locationChannel, name: "Nearby", isAutoJoined: true)
            context.insert(channel)
            return (channel, nil)
        }
    }

    @MainActor
    func resolveSenderUser(for senderPeerID: PeerID, context: ModelContext) throws -> User? {
        let peerData = senderPeerID.bytes

        if let channelPeer = peerStore.findPeer(byPeerIDBytes: peerData),
           !channelPeer.noisePublicKey.isEmpty {
            return try resolveOrCreateUser(for: channelPeer, context: context)
        }

        let allUsers = try context.fetch(FetchDescriptor<User>())
        for candidate in allUsers where !candidate.noisePublicKey.isEmpty {
            let derivedPeerID = PeerID(noisePublicKey: candidate.noisePublicKey)
            if derivedPeerID == senderPeerID {
                let peerInfo = PeerInfo(
                    peerID: senderPeerID.bytes,
                    noisePublicKey: candidate.noisePublicKey,
                    signingPublicKey: candidate.signingPublicKey,
                    username: candidate.username,
                    rssi: -100,
                    isConnected: false,
                    lastSeenAt: Date(),
                    hopCount: 0
                )
                peerStore.upsert(peer: peerInfo)
                return candidate
            }
        }

        return nil
    }

    // MARK: - Private: Recipient Resolution

    private func resolveRecipientPeerID(for channel: Channel) -> PeerID? {
        guard channel.type == .dm else { return nil }

        // Get local identity to filter out self from memberships
        guard let identity = getIdentity() else {
            DebugLogger.emit("DM", "resolveRecipient FAILED: no local identity", isError: true)
            return nil
        }
        let localNoiseKey = identity.noisePublicKey.rawRepresentation

        // Fresh-fetch channel in a new context to avoid SwiftData lazy loading
        // returning empty memberships from a stale context
        let freshContext = ModelContext(modelContainer)
        let channelID = channel.id
        let channelDesc = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        let freshChannel: Channel?
        do {
            freshChannel = try freshContext.fetch(channelDesc).first
        } catch {
            DebugLogger.emit("DM", "resolveRecipient FAILED: fetch error for channel \(channelID): \(error)", isError: true)
            return nil
        }
        guard let freshChannel else {
            DebugLogger.emit("DM", "resolveRecipient FAILED: channel \(channelID) not found in fresh context", isError: true)
            return nil
        }

        let memberships = freshChannel.memberships
        DebugLogger.emit("DM", "resolveRecipient: channel \(channelID) has \(memberships.count) memberships")

        for membership in memberships {
            guard let user = membership.user else {
                DebugLogger.emit("DM", "resolveRecipient: membership has nil user — skipping")
                continue
            }

            let keyLen = user.noisePublicKey.count
            let keyPresent = !user.noisePublicKey.isEmpty
            DebugLogger.emit("DM", "resolveRecipient: checking \(DebugLogger.redact(user.username)) noiseKey=\(keyPresent ? "\(keyLen)B" : "empty")")

            // Skip local user
            if user.noisePublicKey == localNoiseKey {
                DebugLogger.emit("DM", "resolveRecipient: skipping local user \(DebugLogger.redact(user.username))")
                continue
            }

            // Skip users with empty keys
            if user.noisePublicKey.isEmpty {
                DebugLogger.emit("DM", "resolveRecipient: \(DebugLogger.redact(user.username)) has empty noisePublicKey — skipping", isError: true)
                continue
            }

            // Look up PeerStore by noisePublicKey to get BLE transport PeerID
            let userKey = user.noisePublicKey
            if let recipientPeer = peerStore.peer(byNoisePublicKey: userKey) {
                let peerHex = recipientPeer.peerID.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.emit("DM", "resolveRecipient: found=\(peerHex) via=ble (\(DebugLogger.redact(user.username)))")
                return PeerID(bytes: recipientPeer.peerID)
            }

            // Fallback: construct PeerID from stored key
            if user.noisePublicKey.count == PeerID.length {
                let keyHex = user.noisePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
                DebugLogger.emit("DM", "resolveRecipient: found=\(keyHex) via=cache (raw key, \(DebugLogger.redact(user.username)))")
                return PeerID(bytes: user.noisePublicKey)
            }
            let derivedHex = user.noisePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
            DebugLogger.emit("DM", "resolveRecipient: found=\(derivedHex) via=relay (derived, \(DebugLogger.redact(user.username)))")
            return PeerID(noisePublicKey: user.noisePublicKey)
        }

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

        let existingEntries = message.queueEntries.filter { $0.status == .queued || $0.status == .sending }
        if !existingEntries.isEmpty {
            return
        }

        let queueEntry = MessageQueue(
            message: message,
            maxAttempts: 50,
            nextRetryAt: Date().addingTimeInterval(2),
            transport: .any
        )
        context.insert(queueEntry)
        try context.save()
    }

    @MainActor
    func retryQueuedMessage(messageID: UUID) async throws -> SendOutcome {
        guard let identity = getIdentity() else {
            throw MessageServiceError.senderNotFound
        }

        let context = ModelContext(modelContainer)
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        guard let message = try context.fetch(descriptor).first else {
            throw MessageServiceError.serializationFailed("Queued message not found")
        }
        guard let channel = message.channel else {
            throw MessageServiceError.channelNotFound
        }

        let payload: Data
        let subType: EncryptedSubType

        switch message.type {
        case .text:
            guard let content = String(data: message.rawPayload, encoding: .utf8) else {
                throw MessageServiceError.serializationFailed("Queued text payload could not be decoded")
            }
            if channel.isGroup {
                payload = MessagePayloadBuilder.buildGroupTextPayload(
                    content: content,
                    channelID: channel.id,
                    messageID: message.id,
                    replyToID: message.replyTo?.id
                )
            } else {
                payload = MessagePayloadBuilder.buildTextPayload(
                    content: content,
                    messageID: message.id,
                    replyToID: message.replyTo?.id
                )
            }
            subType = channel.isGroup ? .groupMessage : .privateMessage

        case .voiceNote:
            guard let attachment = message.attachments.first(where: { $0.type == .voiceNote }),
                  let audioData = attachment.fullData else {
                throw MessageServiceError.serializationFailed("Queued voice note attachment missing")
            }
            payload = MessagePayloadBuilder.buildMediaPayload(
                data: audioData,
                messageID: message.id,
                duration: attachment.duration
            )
            subType = .voiceNote

        case .image:
            guard let attachment = message.attachments.first(where: { $0.type == .image }),
                  let imageData = attachment.fullData else {
                throw MessageServiceError.serializationFailed("Queued image attachment missing")
            }
            payload = MessagePayloadBuilder.buildMediaPayload(
                data: imageData,
                messageID: message.id,
                duration: nil
            )
            subType = .imageMessage

        case .pttAudio:
            throw MessageServiceError.serializationFailed("PTT retry is not supported by MessageService")
        }

        return try await encryptAndSend(
            payload: payload,
            subType: subType,
            channel: channel,
            identity: identity,
            messageID: message.id,
            shouldEnqueueForRetry: false
        )
    }

    // MARK: - Private: Helpers

    func getIdentity() -> Identity? {
        lock.lock()
        defer { lock.unlock() }
        return localIdentity
    }

    func extractGeohash(from data: Data) -> String? {
        // Geohash is encoded as the first 12 bytes of broadcast payload (if present)
        guard data.count >= 12 else { return nil }
        let geohashData = data.prefix(12)
        return String(data: geohashData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    @MainActor
    private func handleDeliveryFailureNotification(_ notification: Notification) {
        guard let data = notification.userInfo?["data"] as? Data else { return }

        let targetPeerID: PeerID?
        if let peerData = notification.userInfo?["peerID"] as? Data {
            targetPeerID = PeerID(bytes: peerData)
        } else {
            targetPeerID = nil
        }

        let packet: Packet
        do {
            packet = try PacketSerializer.decode(data)
        } catch {
            DebugLogger.emit("TX", "Failed delivery decode failed: \(error)", isError: true)
            return
        }

        let context = ModelContext(modelContainer)
        let messageID = extractMessageID(fromFailedPacket: packet)
            ?? findBestEffortFailedMessageID(for: packet, targetPeerID: targetPeerID, context: context)

        guard let messageID else {
            DebugLogger.emit("TX", "Failed delivery could not be matched to a local message", isError: true)
            return
        }

        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        do {
            guard let message = try context.fetch(descriptor).first else {
                DebugLogger.emit("TX", "Failed delivery matched missing message \(messageID.uuidString)", isError: true)
                return
            }
            guard message.status != .delivered, message.status != .read else { return }

            message.status = .failed
            try context.save()
            delegate?.messageService(self, didUpdateStatus: .failed, for: messageID)
        } catch {
            DebugLogger.emit("DB", "Failed to mark message delivery failure: \(error.localizedDescription)", isError: true)
        }
    }

    private func extractMessageID(fromFailedPacket packet: Packet) -> UUID? {
        guard !packet.flags.contains(.hasRecipient) else { return nil }

        var payload = packet.payload
        if packet.flags.contains(.isCompressed) {
            do {
                payload = try PayloadCompressor.decompress(payload)
            } catch {
                DebugLogger.emit("TX", "Failed delivery payload decompress failed: \(error)", isError: true)
                return nil
            }
        }

        guard let subTypeByte = payload.first,
              let subType = EncryptedSubType(rawValue: subTypeByte) else {
            return nil
        }

        let body = Data(payload.dropFirst())
        switch subType {
        case .groupMessage:
            let (_, scopedContent) = MessagePayloadBuilder.parseChannelScopedPayload(body)
            return MessagePayloadBuilder.parseLeadingMessageID(scopedContent)
        case .privateMessage, .voiceNote, .imageMessage:
            return MessagePayloadBuilder.parseLeadingMessageID(body)
        default:
            return nil
        }
    }

    private func findBestEffortFailedMessageID(
        for packet: Packet,
        targetPeerID: PeerID?,
        context: ModelContext
    ) -> UUID? {
        let failedPeerID = targetPeerID ?? packet.recipientID
        guard let failedPeerID, packet.flags.contains(.hasRecipient) else { return nil }

        let packetDate = packet.date
        let localNoiseKey = getIdentity()?.noisePublicKey.rawRepresentation

        let descriptor = FetchDescriptor<Message>()
        let messages: [Message]
        do {
            messages = try context.fetch(descriptor)
        } catch {
            DebugLogger.emit("DB", "Failed delivery candidate fetch failed: \(error.localizedDescription)", isError: true)
            return nil
        }

        let candidate = messages
            .filter { message in
                guard let channel = message.channel, channel.type == .dm else { return false }
                guard message.status == .queued || message.status == .encrypting || message.status == .sent else {
                    return false
                }
                return channel.memberships.contains { membership in
                    guard let user = membership.user else { return false }
                    if user.noisePublicKey == localNoiseKey {
                        return false
                    }
                    if let directPeerID = PeerID(bytes: user.noisePublicKey), directPeerID == failedPeerID {
                        return true
                    }
                    return PeerID(noisePublicKey: user.noisePublicKey) == failedPeerID
                }
            }
            .map { message in
                (message, abs(message.createdAt.timeIntervalSince(packetDate)))
            }
            .filter { _, delta in delta <= 5.0 }
            .min { lhs, rhs in lhs.1 < rhs.1 }

        return candidate?.0.id
    }
}

// MARK: - TransportDelegate

extension MessageService: TransportDelegate {

    func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID) {
        receive(data: data, from: peerID, via: ingressTransport(for: transport))
    }

    func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        let shortID = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            DebugLogger.shared.log("PEER", "CONNECTED: \(shortID)")

            // Debounce: skip broadcast if one was sent less than 1s ago
            if let last = self.lastBroadcastTime,
               Date().timeIntervalSince(last) < self.broadcastDebounceInterval {
                DebugLogger.shared.log("PRESENCE", "Broadcast debounced for \(shortID)")
                return
            }

            do {
                try await self.broadcastPresence()
                self.lastBroadcastTime = Date()
            } catch {
                DebugLogger.shared.log("PRESENCE", "Broadcast on connect failed: \(error)", isError: true)
            }
        }
    }

    func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        let peerData = peerID.bytes
        let shortID = peerData.prefix(4).map { String(format: "%02x", $0) }.joined()

        // Mark peer as disconnected in PeerStore so UI updates immediately
        peerStore.markDisconnected(peerID: peerData)

        Task { @MainActor in
            // BDEV-86: Clean up sender binding for this transport PeerID
            if self.senderBindings.removeValue(forKey: peerData) != nil {
                DebugLogger.shared.log("PEER", "DISCONNECTED: \(shortID) (binding cleared, peer marked disconnected)")
            } else {
                DebugLogger.shared.log("PEER", "DISCONNECTED: \(shortID) (peer marked disconnected)")
            }
        }
    }

    func transport(_ transport: any Transport, didChangeState state: TransportState) {
        // State changes handled by TransportCoordinator; no MessageService action needed.
    }

    private func ingressTransport(for transport: any Transport) -> PeerIngressTransport {
        if transport is BLEService {
            return .bluetooth
        }
        if transport is WebSocketTransport {
            return .relay
        }
        return .unknown
    }
}

// MARK: - Notification Names

// MARK: - Data Hex Extension

extension Data {
    /// Initialize Data from a hex-encoded string (e.g. "a1b2c3" → 3 bytes).
    init(hexString: String) {
        self.init()
        let chars = Array(hexString)
        for i in stride(from: 0, to: chars.count - 1, by: 2) {
            if let byte = UInt8(String(chars[i...i+1]), radix: 16) {
                append(byte)
            }
        }
    }
}

extension Notification.Name {
    static let didReceiveSOSPacket = Notification.Name("com.blip.didReceiveSOSPacket")
    static let didReceiveLocationPacket = Notification.Name("com.blip.didReceiveLocationPacket")
    static let didReceivePTTAudio = Notification.Name("com.blip.didReceivePTTAudio")
    static let didReceiveFriendRequest = Notification.Name("com.blip.didReceiveFriendRequest")
    static let didReceiveFriendAccept = Notification.Name("com.blip.didReceiveFriendAccept")
    static let didAcceptFriendRequest = Notification.Name("com.blip.didAcceptFriendRequest")
    static let friendListDidChange = Notification.Name("com.blip.friendListDidChange")
    static let didReceiveGroupManagement = Notification.Name("com.blip.didReceiveGroupManagement")
    static let didReceiveBlipMessage = Notification.Name("com.blip.didReceiveMessage")
}
