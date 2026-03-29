import Foundation
import SwiftData
import os.log
import BlipProtocol
import BlipMesh
import BlipCrypto

// MARK: - Message Service Error

enum MessageServiceError: Error, Sendable {
    case insufficientBalance
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
    func messageService(_ service: MessageService, didReceiveTypingIndicator from: PeerID, in channelID: UUID)
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
/// - MessagePack for balance tracking
final class MessageService: @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "MessageService")

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let keyManager: KeyManager
    private let bloomFilter: MultiTierBloomFilter
    weak var delegate: (any MessageServiceDelegate)?

    // Transport reference (set externally after initialization)
    private var transport: (any Transport)?

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

    init(modelContainer: ModelContainer, keyManager: KeyManager = .shared) {
        self.modelContainer = modelContainer
        self.keyManager = keyManager
        self.bloomFilter = MultiTierBloomFilter()
    }

    // MARK: - Configuration

    func configure(transport: any Transport, identity: Identity) {
        lock.lock()
        defer { lock.unlock() }
        self.transport = transport
        self.localIdentity = identity
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
            throw MessageServiceError.senderNotFound
        }

        // Check message balance (text = 1 message credit)
        try await deductMessageBalance()

        let context = ModelContext(modelContainer)

        // Create the message model
        let message = Message(
            sender: nil, // Local user, resolved via identity
            channel: channel,
            type: .text,
            encryptedPayload: Data(),
            status: .queued,
            replyTo: replyTo,
            createdAt: Date()
        )
        context.insert(message)
        try context.save()

        // Encrypt and send
        let payload = buildTextPayload(content: content, messageID: message.id, replyToID: replyTo?.id)
        try await encryptAndSend(
            payload: payload,
            subType: channel.isGroup ? .groupMessage : .privateMessage,
            channel: channel,
            identity: identity,
            messageID: message.id
        )

        // Update status
        message.status = .sent
        try context.save()

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

        try await deductMessageBalance()

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

        try await deductMessageBalance()

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

    // MARK: - Receive Message

    /// Process incoming raw data from the transport layer.
    ///
    /// Flow: deserialize -> deduplicate -> decrypt -> store -> notify delegate
    @MainActor
    func receive(data: Data, from peerID: PeerID) async throws {
        // Deserialize the packet
        let packet: Packet
        do {
            packet = try PacketSerializer.decode(data)
        } catch {
            throw MessageServiceError.deserializationFailed(error.localizedDescription)
        }

        // Deduplicate via Bloom filter
        let packetIDData = buildPacketID(packet)
        if bloomFilter.contains(packetIDData) {
            return // Already processed
        }
        bloomFilter.insert(packetIDData)

        // Route based on packet type
        switch packet.type {
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
        let taggedPayload = prependSubType(subType, to: payload)

        // Determine compression: skip for pre-compressed types
        let isPreCompressed = (subType == .voiceNote || subType == .imageMessage)
        let compressed = PayloadCompressor.compressIfNeeded(taggedPayload, isPreCompressed: isPreCompressed)

        // Build flags
        var flags: PacketFlags = [.hasSignature, .isReliable]
        if compressed.wasCompressed {
            flags.insert(.isCompressed)
        }

        if channel.type == .dm {
            // DM: addressed to specific peer
            flags.insert(.hasRecipient)
            let recipientPeerID = resolveRecipientPeerID(for: channel)
            let packet = buildPacket(
                type: .noiseEncrypted,
                payload: compressed.data,
                flags: flags,
                senderID: identity.peerID,
                recipientID: recipientPeerID
            )
            try sendPacket(packet)
        } else {
            // Group/channel: broadcast
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
            throw MessageServiceError.noTransportAvailable
        }

        let wireData = try PacketSerializer.encode(packet)

        if let recipientID = packet.recipientID, !recipientID.isBroadcast {
            try transport.send(data: wireData, to: recipientID)
        } else {
            transport.broadcast(data: wireData)
        }
    }

    // MARK: - Private: Handle Received Packets

    @MainActor
    private func handleEncryptedPacket(_ packet: Packet, from peerID: PeerID) async throws {
        var payload = packet.payload

        // Decompress if needed
        if packet.flags.contains(.isCompressed) {
            payload = try PayloadCompressor.decompress(payload)
        }

        // Extract sub-type (first byte of decrypted payload)
        guard !payload.isEmpty, let subType = EncryptedSubType(rawValue: payload[payload.startIndex]) else {
            return
        }
        let contentData = payload.dropFirst()

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
        let context = ModelContext(modelContainer)

        // Parse message ID and content from payload
        let (messageID, content, replyToID) = parseTextPayload(data)

        // Check for duplicate
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        let existing = try context.fetch(descriptor)
        if !existing.isEmpty { return }

        // Resolve sender
        let senderPeerData = senderPeerID.bytes
        let peerDescriptor = FetchDescriptor<MeshPeer>(predicate: #Predicate { $0.peerID == senderPeerData })
        let peers = try context.fetch(peerDescriptor)
        let senderUser: User? = peers.first.flatMap { peer in
            guard let username = peer.username else { return nil }
            let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            do {
                return try context.fetch(userDesc).first
            } catch {
                logger.error("Failed to fetch user for peer username \(username): \(error.localizedDescription)")
                return nil
            }
        }

        // Resolve channel
        let channel = try resolveChannel(
            for: subType,
            senderPeerID: senderPeerID,
            context: context
        )

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
        try context.save()

        // Send delivery ack
        Task { [logger] in
            do {
                try await sendDeliveryAck(for: messageID, to: senderPeerID)
            } catch {
                logger.warning("Failed to send delivery ack for message \(messageID): \(error.localizedDescription)")
            }
        }

        // Notify delegate
        delegate?.messageService(self, didReceiveMessage: message, in: channel)
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
        delegate?.messageService(self, didReceiveTypingIndicator: senderPeerID, in: channelID)
    }

    @MainActor
    private func handleFriendRequest(data: Data, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceiveFriendRequest,
            object: nil,
            userInfo: ["data": data, "peerID": peerID]
        )
    }

    @MainActor
    private func handleFriendAccept(data: Data, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceiveFriendAccept,
            object: nil,
            userInfo: ["data": data, "peerID": peerID]
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
            signature: nil // Signature applied by crypto layer before transport
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
            // Find or create DM channel with this peer
            let peerData = senderPeerID.bytes
            let descriptor = FetchDescriptor<Channel>(predicate: #Predicate {
                $0.typeRaw == "dm"
            })
            let channels = try context.fetch(descriptor)

            // Look for existing DM with this peer via memberships
            for ch in channels {
                for membership in ch.memberships {
                    if let user = membership.user, user.noisePublicKey == peerData {
                        return ch
                    }
                }
            }

            // Create new DM channel
            let channel = Channel(type: .dm)
            context.insert(channel)
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
        // In a DM, the other membership's user has the peer ID
        for membership in channel.memberships {
            if let user = membership.user {
                return PeerID(noisePublicKey: user.noisePublicKey)
            }
        }
        return nil
    }

    // MARK: - Private: Balance Management

    @MainActor
    private func deductMessageBalance() async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MessagePack>(
            sortBy: [SortDescriptor(\.purchaseDate, order: .forward)]
        )
        let packs = try context.fetch(descriptor)

        // Find a pack with remaining balance
        for pack in packs {
            if pack.isUnlimited { return }
            if pack.messagesRemaining > 0 {
                pack.messagesRemaining -= 1
                try context.save()
                return
            }
        }

        throw MessageServiceError.insufficientBalance
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
                self.logger.error("Failed to process incoming packet: \(error.localizedDescription)")
            }
        }
    }

    func transport(_ transport: any Transport, didConnect peerID: PeerID) {
        // Connection handled by TransportCoordinator; no MessageService action needed.
    }

    func transport(_ transport: any Transport, didDisconnect peerID: PeerID) {
        // Disconnection handled by TransportCoordinator; no MessageService action needed.
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
    static let didReceiveGroupManagement = Notification.Name("com.blip.didReceiveGroupManagement")
}
