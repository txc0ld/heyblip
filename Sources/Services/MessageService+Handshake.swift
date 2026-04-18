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

            // Guard: only process msg2 if we have a pending initiator handshake for this peer.
            // If we're a responder (sent msg2, waiting for msg3), ignore stale/duplicate msg2.
            guard sessionManager.hasPendingInitiatorHandshake(for: peerID) else {
                DebugLogger.shared.log("NOISE", "⚠️ Ignoring msg2 from \(peerHex) — no initiator handshake pending")
                return
            }

            do {
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
                onSessionEstablished(with: peerID)
            } catch {
                DebugLogger.shared.log("NOISE", "⚠️ Handshake msg2 failed from \(peerHex): \(error) — destroying and will retry", isError: true)
                sessionManager.destroySession(for: peerID)
            }

        case 0x03:
            // We are responder — receive msg3 (completes handshake)
            DebugLogger.shared.log("NOISE", "← handshake msg3 from \(peerHex)")

            guard sessionManager.hasPendingResponderHandshake(for: peerID) else {
                DebugLogger.shared.log("NOISE", "⚠️ Ignoring msg3 from \(peerHex) — no responder handshake pending")
                return
            }

            do {
                let (_, session) = try sessionManager.processHandshakeMessage(from: peerID, message: handshakeData)
                if session != nil {
                    DebugLogger.shared.log("NOISE", "✅ E2E session established with \(peerHex)")
                    onSessionEstablished(with: peerID)
                }
            } catch {
                DebugLogger.shared.log("NOISE", "⚠️ Handshake msg3 failed from \(peerHex): \(error) — destroying and will retry", isError: true)
                sessionManager.destroySession(for: peerID)
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
                let task = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        // Sleep cancellation is the expected path when the
                        // handshake completes early. Don't log as an error.
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.handleHandshakeTimeout(peerIDBytes: peerBytes)
                }
                lock.withLock {
                    handshakeTimeoutTasks[peerBytes]?.cancel()
                    handshakeTimeoutTasks[peerBytes] = task
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
        let retryTask = Task { @MainActor [weak self] in
            let retryDelays: [Duration] = [.seconds(60), .seconds(60), .seconds(60), .seconds(60)]
            for (attempt, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled — expected when the handshake succeeds or the
                    // service tears down.
                    return
                }

                guard let self, !Task.isCancelled else { return }

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
                        // Don't destroy if we're now a responder (tiebreaker yielded)
                        if sessionManager.hasPendingResponderHandshake(for: retryPeerID) {
                            DebugLogger.shared.log("NOISE", "Skipping retry — now responder for \(peerHex), waiting for msg3")
                            continue
                        }
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
        lock.withLock {
            handshakeRetryTasks[peerBytes]?.cancel()
            handshakeRetryTasks[peerBytes] = retryTask
        }

        return true
    }

    /// Called when a Noise session is established — flush all queued messages.
    @MainActor
    func onSessionEstablished(with peerID: PeerID) {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("NOISE", "✅ E2E session established with \(peerHex)")
        // Cancel any outstanding timeout + retry Tasks for this peer — the
        // session is live now, those Tasks would otherwise fire later and
        // run handshake retries / timeouts over an already-established session.
        let (pending, pendingControls): ([PendingEncryptedMessage], [PendingEncryptedControlMessage])
        (pending, pendingControls) = lock.withLock {
            let msgs = pendingHandshakeMessages.removeValue(forKey: peerID.bytes) ?? []
            let controls = pendingHandshakeControlMessages.removeValue(forKey: peerID.bytes) ?? []
            handshakeTimeoutTasks.removeValue(forKey: peerID.bytes)?.cancel()
            handshakeRetryTasks.removeValue(forKey: peerID.bytes)?.cancel()
            return (msgs, controls)
        }

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
        let pending: [PendingEncryptedMessage]?
        let pendingControls: [PendingEncryptedControlMessage]?
        (pending, pendingControls) = lock.withLock {
            let msgs = pendingHandshakeMessages.removeValue(forKey: peerIDBytes)
            let controls = pendingHandshakeControlMessages.removeValue(forKey: peerIDBytes)
            // Cancel the sibling retry Task — we've given up. Discard the
            // stored timeout Task reference too so we don't leak it.
            handshakeRetryTasks.removeValue(forKey: peerIDBytes)?.cancel()
            _ = handshakeTimeoutTasks.removeValue(forKey: peerIDBytes)
            return (msgs, controls)
        }

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

    /// Re-initiates handshakes for all peers that have queued messages but no active session.
    /// Called when the relay reconnects so messages don't stay stuck behind a stale handshake.
    @MainActor
    func resendPendingHandshakesAfterRelayReconnect() {
        let pendingPeerBytes: [Data] = lock.withLock {
            Array(pendingHandshakeMessages.keys)
        }
        guard !pendingPeerBytes.isEmpty else { return }
        DebugLogger.shared.log("NOISE", "Relay reconnected — re-initiating handshakes for \(pendingPeerBytes.count) pending peer(s)")
        for peerBytes in pendingPeerBytes {
            guard let peerID = PeerID(bytes: peerBytes) else { continue }
            guard noiseSessionManager?.hasSession(for: peerID) == false else { continue }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.initiateHandshakeIfNeeded(with: peerID)
                } catch {
                    let hex = peerBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                    DebugLogger.shared.log("NOISE", "Relay reconnect handshake retry failed for \(hex): \(error)", isError: true)
                }
            }
        }
    }

    /// Update a message's status in SwiftData.
    @MainActor
    func updateMessageStatus(messageID: UUID, to status: MessageStatus) {
        let context = self.context
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
    func handleEncryptedPacket(_ packet: Packet, from peerID: PeerID, ingressTransport: PeerIngressTransport) async throws {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let peerBytes = peerID.bytes

        // Broadcast (no recipient) → sender-key encrypted group message
        if !packet.flags.contains(.hasRecipient) {
            try await handleSenderKeyEncryptedPacket(packet, from: peerID, senderHex: senderHex, ingressTransport: ingressTransport)
            return
        }

        // Addressed (has recipient) → Noise session encrypted DM
        // Try twice: a session may have been established between packet arrival and decrypt attempt
        var session = noiseSessionManager?.getSession(for: peerID)
        if session == nil {
            // Brief yield to allow a concurrent handshake completion to land
            try? await Task.sleep(for: .milliseconds(50))
            session = noiseSessionManager?.getSession(for: peerID)
        }
        guard let session else {
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

        try await dispatchDecryptedPayload(decryptedPayload, packet: packet, from: peerID, senderHex: senderHex, ingressTransport: ingressTransport)
    }

    /// Decrypt and dispatch a sender-key encrypted group broadcast packet.
    @MainActor
    private func handleSenderKeyEncryptedPacket(_ packet: Packet, from peerID: PeerID, senderHex: String, ingressTransport: PeerIngressTransport) async throws {
        guard let senderKeyManager else {
            DebugLogger.shared.log("CRYPTO", "Dropped group packet from \(senderHex): SenderKeyManager not configured", isError: true)
            return
        }

        // Payload format: [channelUUID:16 raw bytes][senderKey ciphertext]
        guard packet.payload.count > 16 else {
            DebugLogger.shared.log("CRYPTO", "Dropped group packet from \(senderHex): payload too short (\(packet.payload.count)B)", isError: true)
            return
        }

        let uuidBytes = packet.payload.prefix(16)
        let ciphertext = Data(packet.payload.dropFirst(16))

        // Reconstruct channel UUID from raw bytes
        let uuid = uuidBytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        let channelUUID = UUID(uuid: uuid)
        let channelIDData = channelUUID.uuidString.data(using: .utf8) ?? Data()

        let decryptedPayload: Data
        do {
            decryptedPayload = try senderKeyManager.decrypt(
                ciphertext: ciphertext,
                channelID: channelIDData,
                senderPeerID: peerID
            )
            DebugLogger.shared.log("CRYPTO", "Sender-key decrypted \(decryptedPayload.count)B from \(senderHex) for channel \(String(channelUUID.uuidString.prefix(8)))")
        } catch {
            DebugLogger.shared.log("CRYPTO", "Dropped group packet from \(senderHex): sender key decryption failed: \(error)", isError: true)
            return
        }

        try await dispatchDecryptedPayload(decryptedPayload, packet: packet, from: peerID, senderHex: senderHex, ingressTransport: ingressTransport)
    }

    /// Decompress, extract sub-type, and dispatch a decrypted payload to the appropriate handler.
    @MainActor
    private func dispatchDecryptedPayload(_ decryptedPayload: Data, packet: Packet, from peerID: PeerID, senderHex: String, ingressTransport: PeerIngressTransport) async throws {
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
                timestamp: packet.date,
                ingressTransport: ingressTransport
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
                timestamp: packet.date,
                ingressTransport: ingressTransport
            )
        case .pttAudio:
            try await handleIncomingPTTAudio(
                data: Data(contentData),
                senderPeerID: packet.senderID,
                timestamp: packet.date,
                ingressTransport: ingressTransport
            )
        case .imageMessage:
            try await handleIncomingMedia(
                data: Data(contentData),
                type: .image,
                senderPeerID: packet.senderID,
                timestamp: packet.date,
                ingressTransport: ingressTransport
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
        timestamp: Date,
        ingressTransport: PeerIngressTransport
    ) async throws {
        let senderHex = senderPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleIncomingMessage: \(data.count)B from \(senderHex) subType=\(subType)")

        let context = self.context

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
            isRelayed: ingressTransport == .relay,
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
        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)
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
        timestamp: Date,
        ingressTransport: PeerIngressTransport
    ) async throws {
        let context = self.context

        // Parse using the symmetric parser — the encoder writes a 36-byte UTF-8 UUID
        // string (not raw 16 bytes), a 0x00 terminator, optional 8-byte duration for
        // voice notes only, then the media bytes.
        let parsed = MessagePayloadBuilder.parseMediaPayload(data, hasDuration: type == .voiceNote)
        let mediaData = parsed.media
        let senderHex = senderPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        // Drop malformed payloads early. Previously the parser fabricated a fresh UUID
        // when the leading ID couldn't be decoded, which meant every retransmit landed
        // as a new row instead of being deduped — visible to the user as repeated
        // images/voice notes after a flaky reconnect.
        guard let messageID = parsed.messageID else {
            DebugLogger.shared.log(
                "RX",
                "Dropped media message from \(senderHex): malformed messageID prefix",
                isError: true
            )
            return
        }

        guard !mediaData.isEmpty else {
            DebugLogger.shared.log(
                "RX",
                "Dropped media message from \(senderHex): empty media payload",
                isError: true
            )
            return
        }

        let (channel, senderUser) = try resolveChannel(
            for: type == .voiceNote ? .voiceNote : .imageMessage,
            senderPeerID: senderPeerID,
            context: context
        )

        // Dedup: a media message may arrive via BLE and relay nearly simultaneously.
        let targetID = messageID
        let duplicateDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        if !(try context.fetch(duplicateDescriptor)).isEmpty {
            DebugLogger.shared.log("DM", "MEDIA DUPLICATE msgID=\(messageID) — skipping")
            return
        }

        let attachmentType: AttachmentType = type == .voiceNote ? .voiceNote : .image
        let mimeType = type == .voiceNote ? "audio/opus" : "image/jpeg"

        let message = Message(
            id: messageID,
            sender: senderUser,
            channel: channel,
            type: type == .voiceNote ? .voiceNote : .image,
            rawPayload: Data(),
            status: .delivered,
            isRelayed: ingressTransport == .relay,
            createdAt: timestamp
        )

        let attachment = Attachment(
            message: message,
            type: attachmentType,
            fullData: mediaData,
            sizeBytes: mediaData.count,
            mimeType: mimeType
        )

        context.insert(message)
        context.insert(attachment)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)
    }

    @MainActor
    func handleBroadcastMessage(_ packet: Packet, ingressTransport: PeerIngressTransport) async throws {
        let context = self.context

        let parsedPayload = MessagePayloadBuilder.parsePublicChannelTextPayload(packet.payload)
        if let channelID = parsedPayload.channelID {
            guard let channel = try resolvePublicChannel(channelID: channelID, context: context) else {
                DebugLogger.shared.log("EVENT", "Dropped public channel broadcast for unknown channel \(channelID.uuidString)", isError: true)
                return
            }

            let messageID = parsedPayload.messageID
            let duplicateDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
            if !(try context.fetch(duplicateDescriptor)).isEmpty {
                return
            }

            let senderUser = try resolveSenderUser(for: packet.senderID, context: context)
            let message = Message(
                id: messageID,
                sender: senderUser,
                channel: channel,
                type: .text,
                rawPayload: parsedPayload.content,
                status: .delivered,
                isRelayed: ingressTransport == .relay,
                createdAt: packet.date
            )

            if let replyToID = parsedPayload.replyToID {
                let replyDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == replyToID })
                message.replyTo = try context.fetch(replyDescriptor).first
            }

            context.insert(message)
            channel.lastActivityAt = Date()
            try context.save()

            delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)
            NotificationCenter.default.post(
                name: .didReceiveBlipMessage,
                object: nil,
                userInfo: [
                    "messageID": message.id,
                    "channelID": channel.id,
                ]
            )
            return
        }

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
            sender: try resolveSenderUser(for: packet.senderID, context: context),
            channel: channel,
            type: .text,
            rawPayload: content,
            status: .delivered,
            isRelayed: ingressTransport == .relay,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)
    }

    @MainActor
    private func resolvePublicChannel(channelID: UUID, context: ModelContext) throws -> Channel? {
        let channelDescriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        if let existingChannel = try context.fetch(channelDescriptor).first {
            return existingChannel
        }

        let eventDescriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == channelID })
        guard let event = try context.fetch(eventDescriptor).first else {
            return nil
        }

        let channel = Channel(
            id: channelID,
            type: .lostAndFound,
            name: "Lost & Found",
            event: event,
            maxRetention: max(event.endDate.timeIntervalSince(event.startDate), 300),
            isAutoJoined: true
        )
        context.insert(channel)
        return channel
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

    /// Handles an incoming PTT audio packet that was encrypted as `.pttAudio` subType
    /// inside a `.noiseEncrypted` packet. Parses the media payload, stores the message,
    /// and triggers PTTViewModel playback via notification.
    @MainActor
    func handleIncomingPTTAudio(
        data: Data,
        senderPeerID: PeerID,
        timestamp: Date,
        ingressTransport: PeerIngressTransport
    ) async throws {
        let context = self.context
        let senderHex = senderPeerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        let parsed = MessagePayloadBuilder.parseMediaPayload(data, hasDuration: true)
        let audioData = parsed.media

        guard let messageID = parsed.messageID else {
            DebugLogger.shared.log("PTT", "Dropped PTT from \(senderHex): malformed messageID prefix", isError: true)
            return
        }

        guard !audioData.isEmpty else {
            DebugLogger.shared.log("PTT", "Dropped PTT from \(senderHex): empty audio payload", isError: true)
            return
        }

        let (channel, senderUser) = try resolveChannel(
            for: .privateMessage,
            senderPeerID: senderPeerID,
            context: context
        )

        let targetID = messageID
        let duplicateDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
        if !(try context.fetch(duplicateDescriptor)).isEmpty {
            DebugLogger.shared.log("PTT", "DUPLICATE PTT msgID=\(messageID) — skipping")
            return
        }

        let message = Message(
            id: messageID,
            sender: senderUser,
            channel: channel,
            type: .voiceNote,
            rawPayload: Data(),
            status: .delivered,
            isRelayed: ingressTransport == .relay,
            createdAt: timestamp
        )

        let attachment = Attachment(
            message: message,
            type: .voiceNote,
            fullData: audioData,
            sizeBytes: audioData.count,
            mimeType: "audio/opus"
        )

        context.insert(message)
        context.insert(attachment)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)

        let senderName = senderUser?.username ?? "Peer \(senderHex)"
        NotificationCenter.default.post(
            name: .didReceivePTTAudio,
            object: nil,
            userInfo: [
                "audioData": audioData,
                "senderName": senderName,
                "receivedAt": timestamp
            ]
        )
    }

    /// Handles a raw (unencrypted) `MessageType.pttAudio` packet.
    /// This path is reserved for future real-time streaming; current PTT uses the
    /// encrypted `.pttAudio` EncryptedSubType path via `handleIncomingPTTAudio`.
    @MainActor
    func handlePTTAudio(_ packet: Packet, from peerID: PeerID, ingressTransport: PeerIngressTransport) async throws {
        let context = self.context
        let audioData = packet.payload

        guard !audioData.isEmpty else { return }

        let (channel, senderUser) = try resolveChannel(
            for: .privateMessage,
            senderPeerID: packet.senderID,
            context: context
        )

        let message = Message(
            sender: senderUser,
            channel: channel,
            type: .voiceNote,
            rawPayload: Data(),
            status: .delivered,
            isRelayed: ingressTransport == .relay,
            createdAt: packet.date
        )

        let attachment = Attachment(
            message: message,
            type: .voiceNote,
            fullData: audioData,
            sizeBytes: audioData.count,
            mimeType: "audio/opus"
        )

        context.insert(message)
        context.insert(attachment)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)

        let senderHex = packet.senderID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let senderName = senderUser?.username ?? "Peer \(senderHex)"
        NotificationCenter.default.post(
            name: .didReceivePTTAudio,
            object: nil,
            userInfo: [
                "audioData": audioData,
                "senderName": senderName,
                "receivedAt": packet.date
            ]
        )
    }

    @MainActor
    func handleOrgAnnouncement(_ packet: Packet, ingressTransport: PeerIngressTransport) async throws {
        let context = self.context

        let channel = try resolveAnnouncementChannel(context: context)

        let message = Message(
            channel: channel,
            type: .text,
            rawPayload: packet.payload,
            status: .delivered,
            isRelayed: ingressTransport == .relay,
            createdAt: packet.date
        )
        context.insert(message)

        channel.lastActivityAt = Date()
        try context.save()

        delegate?.messageService(self, didReceiveMessageID: message.id, channelID: channel.id)
    }

    @MainActor
    private func resolveAnnouncementChannel(context: ModelContext) throws -> Channel {
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "stageChannel" })
        let stageChannels = try context.fetch(descriptor)
        let sortedStageChannels = stageChannels.sorted(by: announcementChannelSort)

        if let activeEventID = try currentEventID(context: context),
           let scopedChannel = sortedStageChannels.first(where: { $0.event?.id == activeEventID }) {
            return scopedChannel
        }

        if let existing = sortedStageChannels.first {
            return existing
        }

        let fallbackEvent = try currentEvent(context: context)
        let fallbackRetention: TimeInterval
        if let fallbackEvent {
            fallbackRetention = max(fallbackEvent.endDate.timeIntervalSince(fallbackEvent.startDate), 300)
        } else {
            fallbackRetention = .infinity
        }

        let fallback = Channel(
            type: .stageChannel,
            name: "Announcements",
            event: fallbackEvent,
            maxRetention: fallbackRetention,
            isAutoJoined: true
        )
        context.insert(fallback)
        return fallback
    }

    @MainActor
    private func currentEvent(context: ModelContext) throws -> Event? {
        guard let eventID = try currentEventID(context: context) else { return nil }
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == eventID })
        return try context.fetch(descriptor).first
    }

    @MainActor
    private func currentEventID(context: ModelContext) throws -> UUID? {
        let descriptor = FetchDescriptor<UserPreferences>()
        return try context.fetch(descriptor).first?.lastEventID
    }

    private func announcementChannelSort(_ lhs: Channel, _ rhs: Channel) -> Bool {
        announcementChannelSortKey(lhs) < announcementChannelSortKey(rhs)
    }

    private func announcementChannelSortKey(_ channel: Channel) -> (Int, String) {
        let normalizedName = channel.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            ?? ""
        let priority = normalizedName == "announcements" ? 0 : 1
        return (priority, normalizedName)
    }


}
