import Foundation
import BlipProtocol
import BlipCrypto
import SwiftData

// MARK: - MessageService + Noise Handshake

/// Noise XX handshake handling, initiation, timeout, and session establishment.
/// Extracted from MessageService to reduce file size.
extension MessageService {

    // MARK: - Noise Handshake

    /// Handle an incoming Noise XX handshake message.
    ///
    /// The handshake payload carries a 1-byte step indicator:
    /// - `0x01`: message 1 (initiator → responder)
    /// - `0x02`: message 2 (responder → initiator)
    /// - `0x03`: message 3 (initiator → responder)
    @MainActor
    func handleNoiseHandshake(_ packet: Packet, from peerID: PeerID) async throws {
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
            guard let _ = try sessionManager.receiveHandshakeInit(from: peerID, message: handshakeData) else {
                // Tiebreaker: we have the higher PeerID — keep our initiator role, discard this msg1
                DebugLogger.shared.log("NOISE", "Tiebreak won against \(peerHex) — keeping initiator role")
                return
            }
            let msg2 = try sessionManager.respondToHandshake(for: peerID)
            var response = Data([0x02])
            response.append(msg2)
            let responsePacket = MessagePayloadBuilder.buildPacket(
                type: .noiseHandshake,
                payload: response,
                flags: [.hasRecipient],
                senderID: identity.peerID,
                recipientID: peerID
            )
            try await sendPacket(responsePacket)
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
                let responsePacket = MessagePayloadBuilder.buildPacket(
                    type: .noiseHandshake,
                    payload: response,
                    flags: [.hasRecipient],
                    senderID: identity.peerID,
                    recipientID: peerID
                )
                try await sendPacket(responsePacket)
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
    func initiateHandshakeIfNeeded(with recipientPeerID: PeerID) async throws -> Bool {
        guard let sessionManager = noiseSessionManager, let identity = getIdentity() else {
            return false
        }

        // Already have an active session
        if sessionManager.hasSession(for: recipientPeerID) {
            return false
        }

        // Check if handshake already in progress
        let peerHex = recipientPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let alreadyPending: Bool = lock.withLock {
            pendingHandshakeMessages[recipientPeerID.bytes] != nil
        }

        if alreadyPending {
            DebugLogger.emit("NOISE", "Handshake already pending for \(peerHex)")
            return true
        }

        // A handshake may already be in progress as responder (we received their msg1
        // and sent msg2, waiting for msg3). Don't start a competing initiator handshake —
        // just queue messages on the existing handshake.
        if sessionManager.hasPendingHandshake(for: recipientPeerID) {
            DebugLogger.emit("NOISE", "Handshake in progress (responder) for \(peerHex) — queueing")
            let needsTimeout: Bool = lock.withLock {
                let isNew = pendingHandshakeMessages[recipientPeerID.bytes] == nil
                if isNew {
                    pendingHandshakeMessages[recipientPeerID.bytes] = []
                }
                return isNew
            }
            if needsTimeout {
                let peerBytes = recipientPeerID.bytes
                Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        DebugLogger.shared.log("NOISE", "Handshake timeout sleep cancelled: \(error)")
                        return
                    }
                    self.handleHandshakeTimeout(peerIDBytes: peerBytes)
                }
            }
            return true
        }

        // Start handshake
        let (_, msg1) = try sessionManager.initiateHandshake(with: recipientPeerID)
        var payload = Data([0x01])
        payload.append(msg1)
        let packet = MessagePayloadBuilder.buildPacket(
            type: .noiseHandshake,
            payload: payload,
            flags: [.hasRecipient],
            senderID: identity.peerID,
            recipientID: recipientPeerID
        )
        try await sendPacket(packet)
        DebugLogger.emit("NOISE", "→ handshake msg1 to \(peerHex)")

        // Initialize pending queue
        lock.withLock {
            if pendingHandshakeMessages[recipientPeerID.bytes] == nil {
                pendingHandshakeMessages[recipientPeerID.bytes] = []
            }
        }

        // Handshake retry loop: retry msg1 at 60-second intervals for roughly 4 minutes.
        // This handles relay paths where the recipient may connect after the first attempt.
        let peerBytes = recipientPeerID.bytes
        let retryPeerID = recipientPeerID
        Task { @MainActor in
            let retryDelays: [Duration] = [.seconds(60), .seconds(60), .seconds(60), .seconds(60)]
            for (attempt, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    DebugLogger.shared.log("NOISE", "Handshake retry sleep cancelled: \(error)")
                    return
                }

                // Check if session was established while we waited.
                if self.noiseSessionManager?.hasSession(for: retryPeerID) == true {
                    DebugLogger.shared.log("NOISE", "Handshake completed during retry wait")
                    return
                }

                // Check if messages are still pending (not already timed out by another path).
                let stillPending: Bool = self.lock.withLock {
                    self.pendingHandshakeMessages[peerBytes] != nil
                }
                guard stillPending else { return }

                // Retry: re-initiate handshake msg1 if no session yet.
                if attempt < retryDelays.count - 1 {
                    DebugLogger.shared.log("NOISE", "Handshake retry \(attempt + 1)/\(retryDelays.count - 1) for \(peerHex)")
                    if let sessionManager = self.noiseSessionManager,
                       let identity = self.getIdentity() {
                        do {
                            sessionManager.destroySession(for: retryPeerID)
                            let (_, retryMsg1) = try sessionManager.initiateHandshake(with: retryPeerID)
                            var retryPayload = Data([0x01])
                            retryPayload.append(retryMsg1)
                            let retryPacket = MessagePayloadBuilder.buildPacket(
                                type: .noiseHandshake,
                                payload: retryPayload,
                                flags: [.hasRecipient],
                                senderID: identity.peerID,
                                recipientID: retryPeerID
                            )
                            try await self.sendPacket(retryPacket)
                            DebugLogger.shared.log("NOISE", "→ handshake msg1 retry to \(peerHex)")
                        } catch {
                            DebugLogger.shared.log("NOISE", "Handshake retry failed: \(error)", isError: true)
                        }
                    }
                } else {
                    // Final timeout — give up.
                    self.handleHandshakeTimeout(peerIDBytes: peerBytes)
                }
            }
        }

        return true
    }

    /// Called when a Noise session is established — flush all queued messages.
    @MainActor
    func onSessionEstablished(with peerID: PeerID) {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let pending = pendingHandshakeMessages.removeValue(forKey: peerID.bytes) ?? []
        let pendingControls = pendingHandshakeControlMessages.removeValue(forKey: peerID.bytes) ?? []
        lock.unlock()

        guard !pending.isEmpty || !pendingControls.isEmpty else {
            DebugLogger.shared.log("NOISE", "Session with \(peerHex) ready (no queued payloads)")
            return
        }

        DebugLogger.shared.log(
            "NOISE",
            "Flushing \(pendingControls.count) queued control packet(s) and \(pending.count) queued message(s) to \(peerHex)"
        )
        Task { @MainActor in
            for pendingControl in pendingControls {
                do {
                    try await self.sendEncryptedControl(
                        payload: pendingControl.payload,
                        subType: pendingControl.subType,
                        to: peerID,
                        identity: pendingControl.identity,
                        flags: pendingControl.flags,
                        shouldQueueIfHandshakeMissing: false
                    )
                } catch {
                    DebugLogger.shared.log("NOISE", "Failed to send queued control packet: \(error)", isError: true)
                }
            }

            for msg in pending {
                do {
                    let outcome = try await self.encryptAndSend(
                        payload: msg.payload,
                        subType: msg.subType,
                        channel: msg.channel,
                        identity: msg.identity,
                        messageID: msg.messageID,
                        shouldEnqueueForRetry: false
                    )
                    if let messageID = msg.messageID {
                        switch outcome {
                        case .sent:
                            self.updateMessageStatus(messageID: messageID, to: .sent)
                        case .deferred(let status):
                            self.updateMessageStatus(messageID: messageID, to: status)
                        }
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
    func handleHandshakeTimeout(peerIDBytes: Data) {
        lock.lock()
        let pending = pendingHandshakeMessages.removeValue(forKey: peerIDBytes)
        let pendingControls = pendingHandshakeControlMessages.removeValue(forKey: peerIDBytes)
        lock.unlock()

        let peerHex = peerIDBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        if let pendingControls, !pendingControls.isEmpty {
            DebugLogger.shared.log(
                "NOISE",
                "Handshake timeout for \(peerHex) — dropped \(pendingControls.count) queued control packet(s)",
                isError: true
            )
        }

        guard let pending, !pending.isEmpty else {
            if let peerID = PeerID(bytes: peerIDBytes) {
                noiseSessionManager?.destroySession(for: peerID)
            }
            return
        }

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
    func updateMessageStatus(messageID: UUID, to status: MessageStatus) {
        let context = ModelContext(modelContainer)
        let targetID = messageID
        let desc = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        do {
            if let message = try context.fetch(desc).first {
                message.statusRaw = status.rawValue
                try context.save()
                delegate?.messageService(self, didUpdateStatus: status, for: messageID)
            }
        } catch {
            DebugLogger.emit("DB", "Failed to update message status: \(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    func handleEncryptedPacket(_ packet: Packet, from peerID: PeerID) async throws {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let peerBytes = peerID.bytes

        guard let session = noiseSessionManager?.getSession(for: peerID) else {
            DebugLogger.shared.log("NOISE", "Dropped .noiseEncrypted packet from \(senderHex): no active Noise session", isError: true)
            return
        }

        let decryptedPayload: Data
        do {
            let nonceBefore = session.receiveCipher.currentNonce
            let recoveryBefore = session.receiveCipher.nonceRecoveryCount
            decryptedPayload = try session.decrypt(ciphertext: packet.payload)
            if session.receiveCipher.nonceRecoveryCount > recoveryBefore {
                DebugLogger.shared.log("CRYPTO", "Decrypted \(decryptedPayload.count)B from \(senderHex) nonce=\(nonceBefore)→\(session.receiveCipher.currentNonce) (recovery)")
            } else {
                DebugLogger.shared.log("CRYPTO", "Decrypted \(decryptedPayload.count)B from \(senderHex) nonce=\(nonceBefore)→\(session.receiveCipher.currentNonce)")
            }
            resetDecryptFailureTracking(for: peerBytes)
        } catch {
            DebugLogger.shared.log("NOISE", "Dropped .noiseEncrypted packet from \(senderHex): Noise decryption failed: \(error)", isError: true)
            try await handleDecryptFailure(for: peerID, peerHex: senderHex)
            return
        }

        // Decompress if needed
        var payload = decryptedPayload
        if packet.flags.contains(.isCompressed) {
            payload = try PayloadCompressor.decompress(payload)
        }

        // Extract sub-type (first byte of decrypted payload)
        guard !payload.isEmpty, let subType = EncryptedSubType(rawValue: payload[payload.startIndex]) else {
            DebugLogger.shared.log("RX", "Encrypted packet with empty/invalid subType", isError: true)
            return
        }
        let contentData = payload.dropFirst()
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

    private func resetDecryptFailureTracking(for peerBytes: Data) {
        lock.withLock {
            decryptFailureCounts[peerBytes] = 0
        }
    }

    @MainActor
    private func handleDecryptFailure(for peerID: PeerID, peerHex: String) async throws {
        let peerBytes = peerID.bytes
        let now = Date()
        let failureCount: Int = lock.withLock {
            let updatedCount = (decryptFailureCounts[peerBytes] ?? 0) + 1
            decryptFailureCounts[peerBytes] = updatedCount
            return updatedCount
        }

        guard failureCount >= Self.decryptFailureRecoveryThreshold else {
            return
        }

        let shouldAttemptRecovery: Bool = lock.withLock {
            if let lastAttempt = lastRecoveryAttempt[peerBytes],
               now.timeIntervalSince(lastAttempt) < Self.decryptFailureRecoveryCooldown {
                return false
            }

            lastRecoveryAttempt[peerBytes] = now
            decryptFailureCounts[peerBytes] = 0
            return true
        }

        guard shouldAttemptRecovery else {
            DebugLogger.shared.log(
                "NOISE",
                "Suppressing session recovery for \(peerHex): last recovery attempt was less than \(Int(Self.decryptFailureRecoveryCooldown))s ago",
                isError: true
            )
            return
        }

        DebugLogger.shared.log(
            "NOISE",
            "Initiating session recovery for \(peerHex) after \(failureCount) consecutive decrypt failures",
            isError: true
        )
        noiseSessionManager?.destroySession(for: peerID)

        do {
            let initiated = try await initiateHandshakeIfNeeded(with: peerID)
            if !initiated {
                DebugLogger.shared.log("NOISE", "Session recovery for \(peerHex) did not initiate a new handshake", isError: true)
            }
        } catch {
            DebugLogger.shared.log("NOISE", "Session recovery handshake initiation failed for \(peerHex): \(error)", isError: true)
            throw error
        }
    }

    @MainActor
    func handleIncomingMessage(
        data: Data,
        subType: EncryptedSubType,
        senderPeerID: PeerID,
        timestamp: Date
    ) async throws {
        let senderHex = senderPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleIncomingMessage: \(data.count)B from \(senderHex) subType=\(subType)")

        let context = ModelContext(modelContainer)

        let messageID: UUID
        let content: Data
        let replyToID: UUID?
        let channel: Channel
        let senderUser: User?

        switch subType {
        case .groupMessage:
            let parsedPayload = MessagePayloadBuilder.parseGroupTextPayload(data)
            guard let groupChannelID = parsedPayload.channelID else {
                DebugLogger.shared.log("GROUP", "Dropped group message from \(senderHex): missing or invalid channel ID", isError: true)
                return
            }
            messageID = parsedPayload.messageID
            content = parsedPayload.content
            replyToID = parsedPayload.replyToID
            channel = try resolveGroupChannel(groupChannelID: groupChannelID, context: context)
            senderUser = try resolveSenderUser(for: senderPeerID, context: context)

        default:
            let parsedPayload = MessagePayloadBuilder.parseTextPayload(data)
            messageID = parsedPayload.messageID
            content = parsedPayload.content
            replyToID = parsedPayload.replyToID

            // Resolve channel and sender together — resolveChannel has a 3-fallback chain
            // (PeerStore → Noise session → derived PeerID scan) that is more robust than
            // the old PeerStore-only lookup that failed for relay-first DMs.
            let resolvedChannel = try resolveChannel(
                for: subType,
                senderPeerID: senderPeerID,
                context: context
            )
            channel = resolvedChannel.0
            senderUser = resolvedChannel.1
        }
        DebugLogger.shared.log("DM", "Parsed msgID=\(messageID) contentLen=\(content.count) replyTo=\(replyToID?.uuidString ?? "nil")")

        // Check for duplicate
        let targetID = messageID
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        let existing = try context.fetch(descriptor)
        if !existing.isEmpty {
            DebugLogger.shared.log("DM", "DUPLICATE msgID=\(messageID) — skipping")
            return
        }

        DebugLogger.shared.log("DM", "Channel resolved: \(channel.id) type=\(channel.type) sender=\(DebugLogger.redact(senderUser?.username ?? "nil"))")

        // Create and store message
        let message = Message(
            id: messageID,
            sender: senderUser,
            channel: channel,
            type: .text,
            rawPayload: content,
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

        // Send delivery ack (MainActor for Noise cipher state access)
        Task { @MainActor [logger] in
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
    private func resolveGroupChannel(groupChannelID: UUID, context: ModelContext) throws -> Channel {
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == groupChannelID })
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let channel = Channel(id: groupChannelID, type: .group, name: "Group")
        context.insert(channel)
        return channel
    }

    @MainActor
    func handleIncomingMedia(
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

        let (channel, senderUser) = try resolveChannel(
            for: type == .voiceNote ? .voiceNote : .imageMessage,
            senderPeerID: senderPeerID,
            context: context
        )

        let attachmentType: AttachmentType = type == .voiceNote ? .voiceNote : .image
        let mimeType = type == .voiceNote ? "audio/opus" : "image/jpeg"

        let message = Message(
            id: messageID,
            sender: senderUser,
            channel: channel,
            type: type == .voiceNote ? .voiceNote : .image,
            rawPayload: Data(),
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
    func handleBroadcastMessage(_ packet: Packet) async throws {
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
            rawPayload: content,
            status: .delivered,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessage: message, in: channel)
    }

    @MainActor
    func handleSOSPacket(_ packet: Packet) async throws {
        // SOS packets are forwarded to the SOS subsystem via notification
        NotificationCenter.default.post(
            name: .didReceiveSOSPacket,
            object: nil,
            userInfo: ["packet": packet]
        )
    }

    @MainActor
    func handleLocationPacket(_ packet: Packet, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceiveLocationPacket,
            object: nil,
            userInfo: ["packet": packet, "peerID": peerID]
        )
    }

    @MainActor
    func handlePTTAudio(_ packet: Packet, from peerID: PeerID) async throws {
        NotificationCenter.default.post(
            name: .didReceivePTTAudio,
            object: nil,
            userInfo: ["packet": packet, "peerID": peerID]
        )
    }

    @MainActor
    func handleOrgAnnouncement(_ packet: Packet) async throws {
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
            rawPayload: packet.payload,
            status: .delivered,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessage: message, in: channel)
    }


}
