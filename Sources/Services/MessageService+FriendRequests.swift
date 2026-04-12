import Foundation
import BlipProtocol
import BlipCrypto
import SwiftData

// MARK: - MessageService + Friend Requests

/// Friend request send, receive, accept, and helper logic.
/// Extracted from MessageService to reduce file size.
extension MessageService {

    // MARK: - Friend Requests

    /// Send a friend request to a remote user looked up by username.
    ///
    /// Calls the auth server to resolve the username, creates a local User record,
    /// registers the peer in PeerStore, then sends through the normal friend request flow
    /// (falls back to WebSocket relay if BLE is unavailable).
    @MainActor
    func sendFriendRequestByUsername(_ username: String) async throws {
        let syncService = UserSyncService()

        guard let remote = try await syncService.lookupUser(username: username) else {
            throw MessageServiceError.invalidRecipient
        }

        guard let noiseKeyHex = remote.noisePublicKey else {
            throw MessageServiceError.invalidRecipient
        }

        let noiseKeyData = Data(hexString: noiseKeyHex)
        guard !noiseKeyData.isEmpty else {
            throw MessageServiceError.invalidRecipient
        }

        let signingKeyData: Data
        if let sigHex = remote.signingPublicKey {
            signingKeyData = Data(hexString: sigHex)
        } else {
            signingKeyData = Data()
        }

        // Derive PeerID from noise public key (SHA256[0:8])
        let peerID = PeerID(noisePublicKey: noiseKeyData)

        // Register in PeerStore so transport layer can route to them
        let peerInfo = PeerInfo(
            peerID: peerID.bytes,
            noisePublicKey: noiseKeyData,
            signingPublicKey: signingKeyData,
            username: remote.username,
            rssi: 0,
            isConnected: false,
            lastSeenAt: Date(),
            hopCount: 0
        )
        peerStore.upsert(peer: peerInfo)

        // Create/update User record in SwiftData
        let context = ModelContext(modelContainer)
        let targetUsername = remote.username
        let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == targetUsername })
        let user: User
        if let existing = try context.fetch(userDesc).first {
            if existing.noisePublicKey.isEmpty {
                existing.noisePublicKey = noiseKeyData
            }
            if existing.signingPublicKey.isEmpty && !signingKeyData.isEmpty {
                existing.signingPublicKey = signingKeyData
            }
            user = existing
        } else {
            user = User(
                username: remote.username,
                displayName: remote.username,
                emailHash: "",
                noisePublicKey: noiseKeyData,
                signingPublicKey: signingKeyData
            )
            context.insert(user)
        }
        try context.save()

        // Send friend request through normal flow
        try await sendFriendRequest(to: peerID)

        DebugLogger.shared.log("DM", "FRIEND_REQ by username → \(DebugLogger.redact(remote.username))")
    }

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

        try await sendEncryptedControl(
            payload: payload,
            subType: .friendRequest,
            to: peerID,
            identity: identity
        )

        // Create or update local Friend record for the remote peer
        let peerData = peerID.bytes
        if let peerInfo = peerStore.findPeer(byPeerIDBytes: peerData) {
            let remoteUser = try resolveOrCreateUser(for: peerInfo, context: context)
            try createOrUpdateFriend(
                user: remoteUser,
                status: .pending,
                direction: .outgoing,
                context: context
            )
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
                do {
                    try context.save()
                } catch {
                    DebugLogger.shared.log("DB", "Failed to save backfilled keys: \(error.localizedDescription)", isError: true)
                }
                DebugLogger.shared.log("DM", "Backfilled keys for \(DebugLogger.redact(friendUsername)) before createDMChannel")
            }
        }

        // Fallback: fetch from auth server if PeerStore didn't have keys
        await fetchRemoteKeysIfNeeded(for: friendUser, context: context)

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

        try await sendEncryptedControl(
            payload: payload,
            subType: .friendAccept,
            to: recipientPeerID,
            identity: identity
        )

        logger.info("Accepted friend request from \(friendUser.username)")

        NotificationCenter.default.post(
            name: .didAcceptFriendRequest,
            object: nil,
            userInfo: ["username": friendUser.username]
        )

        NotificationCenter.default.post(
            name: .friendListDidChange,
            object: nil
        )
    }


    // MARK: - Incoming Friend Handlers

    @MainActor func handleFriendRequest(data: Data, from peerID: PeerID) async throws {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleFriendRequest: \(data.count)B from \(peerHex)")

        let context = ModelContext(modelContainer)

        // Parse payload: username + 0x00 + displayName
        let (senderUsername, senderDisplayName) = MessagePayloadBuilder.parseFriendPayload(data)
        DebugLogger.shared.log("DM", "FRIEND_REQ from \(DebugLogger.redact(senderUsername ?? "nil")) display=\(DebugLogger.redact(senderDisplayName ?? "nil"))")

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
                DebugLogger.shared.log("RX", "FRIEND_REQ: pulled keys from PeerStore for fallback User \(DebugLogger.redact(username))")
            }

            let userDesc = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            if let existing = try context.fetch(userDesc).first {
                senderUser = existing
                // Backfill keys if the existing User is missing them
                if existing.noisePublicKey.isEmpty && !fallbackNoiseKey.isEmpty {
                    existing.noisePublicKey = fallbackNoiseKey
                    existing.signingPublicKey = fallbackSigningKey
                    do {
                        try context.save()
                    } catch {
                        DebugLogger.shared.log("DB", "Failed to save backfilled friend keys: \(error.localizedDescription)", isError: true)
                    }
                    DebugLogger.shared.log("RX", "FRIEND_REQ: backfilled keys on existing User \(DebugLogger.redact(username))")
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

        // Fetch keys from auth server if still missing after PeerStore resolution
        await fetchRemoteKeysIfNeeded(for: senderUser, context: context)

        // BDEV-216: If we already sent an outgoing friend request to this
        // user, treat the incoming request as mutual consent and auto-accept.
        // When both users click Add Friend independently before either
        // request arrives, both sides detect the pending outgoing Friend on
        // receive and converge to `.accepted` without any manual step.
        let senderUserID = senderUser.id
        let mutualDescriptor = FetchDescriptor<Friend>(
            predicate: #Predicate<Friend> { friend in
                friend.user?.id == senderUserID &&
                friend.statusRaw == "pending" &&
                friend.requestDirectionRaw == "outgoing"
            }
        )

        let outgoingPending: [Friend]
        do {
            outgoingPending = try context.fetch(mutualDescriptor)
        } catch {
            DebugLogger.shared.log(
                "DB",
                "Failed to query for mutual friend request: \(error.localizedDescription)",
                isError: true
            )
            outgoingPending = []
        }

        if let existingFriend = outgoingPending.first {
            existingFriend.statusRaw = FriendStatus.accepted.rawValue
            existingFriend.requestDirectionRaw = nil

            // findOrCreateDMChannel saves the context, so the status update
            // above is persisted atomically with the DM channel creation.
            try findOrCreateDMChannel(with: senderUser, context: context)

            DebugLogger.shared.log(
                "DM",
                "Auto-accepted mutual friend request from \(DebugLogger.redact(senderUser.username))"
            )
            logger.info("Auto-accepted mutual friend request from \(senderUser.username)")

            NotificationCenter.default.post(
                name: .didAcceptFriendRequest,
                object: nil,
                userInfo: ["username": senderUser.username]
            )
            NotificationCenter.default.post(
                name: .friendListDidChange,
                object: nil
            )
            return
        }

        // Create Friend record with pending status (or update if exists)
        try createOrUpdateFriend(
            user: senderUser,
            status: .pending,
            direction: .incoming,
            context: context
        )

        logger.info("Received friend request from \(senderUser.username)")

        // Send local push notification
        let friendDesc2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.user?.id == senderUserID })
        do {
            if let friendRecord = try context.fetch(friendDesc2).first {
                NotificationService().notifyFriendRequest(
                    fromName: senderUser.resolvedDisplayName,
                    friendID: friendRecord.id
                )
            }
        } catch {
            DebugLogger.shared.log("DB", "Failed to fetch friend for notification: \(error.localizedDescription)", isError: true)
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

    @MainActor func handleFriendAccept(data: Data, from peerID: PeerID) async throws {
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        DebugLogger.shared.log("DM", "handleFriendAccept: \(data.count)B from \(peerHex)")

        let context = ModelContext(modelContainer)

        // Parse payload: username
        let (senderUsername, _) = MessagePayloadBuilder.parseFriendPayload(data)
        DebugLogger.shared.log("DM", "FRIEND_ACCEPT from \(DebugLogger.redact(senderUsername ?? "nil"))")

        // Find the Friend record for this peer (try peerID then noisePublicKey fallback)
        let peerData = peerID.bytes

        var friendUser: User?

        if let acceptPeer = peerStore.findPeer(byPeerIDBytes: peerData) {
            do {
                friendUser = try resolveOrCreateUser(for: acceptPeer, context: context)
            } catch {
                DebugLogger.shared.log("DM", "FRIEND_ACCEPT: failed to resolve user from PeerStore: \(error)", isError: true)
            }
            DebugLogger.shared.log("DM", "FRIEND_ACCEPT: resolved user=\(DebugLogger.redact(friendUser?.username ?? "nil")) via PeerStore")
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
        } else {
            try createOrUpdateFriend(
                user: resolvedUser,
                status: .accepted,
                direction: .outgoing,
                context: context
            )
        }

        // Ensure user has keys before DM channel creation
        if resolvedUser.noisePublicKey.isEmpty {
            let resolvedUsername = resolvedUser.username
            if let backfillPeer = peerStore.peer(byUsername: resolvedUsername),
               !backfillPeer.noisePublicKey.isEmpty {
                resolvedUser.noisePublicKey = backfillPeer.noisePublicKey
                resolvedUser.signingPublicKey = backfillPeer.signingPublicKey
                do {
                    try context.save()
                } catch {
                    DebugLogger.shared.log("DB", "Failed to save backfilled keys: \(error.localizedDescription)", isError: true)
                }
                DebugLogger.shared.log("DM", "Backfilled keys for \(DebugLogger.redact(resolvedUsername)) before createDMChannel")
            }
        }

        // Fallback: fetch from auth server if PeerStore didn't have keys
        await fetchRemoteKeysIfNeeded(for: resolvedUser, context: context)

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
    func handleMessageDelete(data: Data) async throws {
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
    func handleMessageEdit(data: Data) async throws {
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
            message.rawPayload = newContent
            try context.save()
        }
    }

    @MainActor
    func handleGroupManagement(subType: EncryptedSubType, data: Data, from peerID: PeerID) async throws {
        let senderHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let (channelID, contentData) = MessagePayloadBuilder.parseChannelScopedPayload(data)
        guard let channelID else {
            DebugLogger.shared.log("GROUP", "Dropped \(subType) from \(senderHex): missing or invalid channel ID", isError: true)
            return
        }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == channelID })
        guard let channel = try context.fetch(descriptor).first, channel.isGroup else {
            DebugLogger.shared.log("GROUP", "Dropped \(subType) from \(senderHex): group channel \(channelID) not found", isError: true)
            return
        }

        guard let senderUser = try resolveSenderUser(for: peerID, context: context) else {
            DebugLogger.shared.log("GROUP", "Dropped \(subType) from \(senderHex): sender could not be resolved", isError: true)
            return
        }

        guard let senderMembership = channel.memberships.first(where: { $0.user?.id == senderUser.id }) else {
            DebugLogger.shared.log("GROUP", "Dropped \(subType) from \(senderHex): sender is not a group member", isError: true)
            return
        }

        let requiresAdminRole: Bool
        switch subType {
        case .groupMemberAdd, .groupMemberRemove, .groupAdminChange:
            requiresAdminRole = true
        case .groupKeyDistribution:
            requiresAdminRole = false
        default:
            requiresAdminRole = false
        }

        if requiresAdminRole && !senderMembership.isAdmin {
            DebugLogger.shared.log("GROUP", "Dropped \(subType) from \(senderHex): sender lacks group admin role", isError: true)
            return
        }

        NotificationCenter.default.post(
            name: .didReceiveGroupManagement,
            object: nil,
            userInfo: [
                "subType": subType,
                "data": contentData,
                "channelID": channel.id,
                "peerID": peerID,
            ]
        )
    }



    // MARK: - Friend Helpers

    // MARK: - Private: Friend Helpers

    /// Resolve or create a User record from a PeerInfo.
    @MainActor
    func resolveOrCreateUser(for peerInfo: PeerInfo, context: ModelContext) throws -> User {
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
    func createOrUpdateFriend(
        user: User,
        status: FriendStatus,
        direction: FriendRequestDirection? = nil,
        context: ModelContext
    ) throws {
        let userID = user.id
        let existingDesc = FetchDescriptor<Friend>(predicate: #Predicate {
            $0.user?.id == userID
        })
        if let existing = try context.fetch(existingDesc).first {
            // Don't downgrade accepted -> pending
            if existing.status != .accepted || status == .accepted {
                existing.statusRaw = status.rawValue
            }
            if let direction {
                existing.requestDirection = direction
            }
            try context.save()
            return
        }

        let friend = Friend(
            user: user,
            status: status
        )
        friend.requestDirection = direction
        context.insert(friend)
        try context.save()
    }

    /// Fetch and store public keys for a remote user from the auth server.
    /// No-op if the user already has a non-empty noisePublicKey.
    @MainActor
    func fetchRemoteKeysIfNeeded(for user: User, context: ModelContext) async {
        guard user.noisePublicKey.isEmpty else { return }
        let username = user.username
        guard !username.isEmpty else { return }

        do {
            let syncService = UserSyncService()
            guard let remote = try await syncService.lookupUser(username: username),
                  let noiseKeyHex = remote.noisePublicKey else {
                DebugLogger.shared.log("DM", "fetchRemoteKeys: no keys on server for \(DebugLogger.redact(username))")
                return
            }

            let noiseKeyData = Data(hexString: noiseKeyHex)
            guard !noiseKeyData.isEmpty else {
                DebugLogger.shared.log("DM", "fetchRemoteKeys: invalid noiseKey hex for \(DebugLogger.redact(username))")
                return
            }

            let signingKeyData: Data
            if let sigHex = remote.signingPublicKey {
                signingKeyData = Data(hexString: sigHex)
            } else {
                signingKeyData = Data()
            }

            user.noisePublicKey = noiseKeyData
            if user.signingPublicKey.isEmpty && !signingKeyData.isEmpty {
                user.signingPublicKey = signingKeyData
            }
            try context.save()

            // Register in PeerStore so transport layer can route to them
            let derivedPeerID = PeerID(noisePublicKey: noiseKeyData)
            let peerInfo = PeerInfo(
                peerID: derivedPeerID.bytes,
                noisePublicKey: noiseKeyData,
                signingPublicKey: signingKeyData,
                username: username,
                rssi: 0,
                isConnected: false,
                lastSeenAt: Date(),
                hopCount: 0
            )
            peerStore.upsert(peer: peerInfo)

            DebugLogger.shared.log("DM", "fetchRemoteKeys: stored keys for \(DebugLogger.redact(username)) from server")
        } catch {
            DebugLogger.shared.log("DM", "fetchRemoteKeys: failed for \(DebugLogger.redact(username)): \(error.localizedDescription)", isError: true)
        }
    }

    /// Find an existing DM channel for the given user, or create one.
    ///
    /// Resolution order:
    /// 1. Match by user ID in memberships
    /// 2. Match by username in memberships (handles ID drift across re-registrations)
    /// 3. Repair orphan channels (matching name, zero memberships)
    /// 4. Create a new channel + membership as last resort
    ///
    /// Always ensures the returned channel has a valid `GroupMembership` for the user.
    @MainActor
    @discardableResult
    func findOrCreateDMChannel(with user: User, context: ModelContext) throws -> Channel {
        let localUser: User
        let userID = user.id
        let userIDDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == userID })
        if let existingUser = try context.fetch(userIDDescriptor).first {
            localUser = existingUser
        } else {
            let username = user.username
            let usernameDescriptor = FetchDescriptor<User>(predicate: #Predicate { $0.username == username })
            if let existingUser = try context.fetch(usernameDescriptor).first {
                localUser = existingUser
            } else {
                let createdUser = User(
                    username: user.username,
                    displayName: user.displayName,
                    emailHash: user.emailHash,
                    noisePublicKey: user.noisePublicKey,
                    signingPublicKey: user.signingPublicKey
                )
                context.insert(createdUser)
                localUser = createdUser
            }
        }

        let dmDescriptor = FetchDescriptor<Channel>(predicate: #Predicate {
            $0.typeRaw == "dm"
        })
        let channels = try context.fetch(dmDescriptor)
        let username = localUser.username
        let displayName = localUser.resolvedDisplayName

        var matchingChannels = channels.filter { channel in
            channel.memberships.contains(where: { $0.user?.id == localUser.id })
        }

        if matchingChannels.isEmpty {
            matchingChannels = channels.filter { channel in
                channel.memberships.contains(where: { $0.user?.username == username })
            }
        }

        if !matchingChannels.isEmpty {
            let preferredChannel = preferredDMChannel(from: matchingChannels)
            if let matchingMembership = preferredChannel.memberships.first(where: { membership in
                membership.user?.username == username
            }) {
                matchingMembership.user = localUser
            } else if preferredChannel.memberships.isEmpty {
                let membership = GroupMembership(user: localUser, channel: preferredChannel, role: .member)
                context.insert(membership)
            }

            if preferredChannel.name?.isEmpty != false {
                preferredChannel.name = displayName
            }

            try context.save()
            return preferredChannel
        }

        let orphanChannels = channels.filter { channel in
            channel.memberships.isEmpty && (channel.name == displayName || channel.name == nil)
        }
        if !orphanChannels.isEmpty {
            let preferredChannel = preferredDMChannel(from: orphanChannels)
            preferredChannel.name = displayName
            let membership = GroupMembership(user: localUser, channel: preferredChannel, role: .member)
            context.insert(membership)
            try context.save()
            DebugLogger.shared.log("DM", "Repaired orphan DM channel for \(DebugLogger.redact(username))")
            return preferredChannel
        }

        let channel = Channel(type: .dm, name: displayName)
        context.insert(channel)
        let membership = GroupMembership(user: localUser, channel: channel, role: .member)
        context.insert(membership)
        try context.save()
        DebugLogger.shared.log("DM", "Created DM channel with \(DebugLogger.redact(username))")
        return channel
    }

    /// Create a DM channel with the given user if one doesn't already exist.
    @MainActor
    func createDMChannel(with remoteUser: User, context: ModelContext) throws {
        try findOrCreateDMChannel(with: remoteUser, context: context)
    }

    @MainActor
    func sendEncryptedControl(
        payload: Data,
        subType: EncryptedSubType,
        to peerID: PeerID,
        identity: Identity,
        flags: PacketFlags = [.hasRecipient, .hasSignature, .isReliable],
        shouldQueueIfHandshakeMissing: Bool = true
    ) async throws {
        let taggedPayload = MessagePayloadBuilder.prependSubType(subType, to: payload)
        let peerHex = peerID.bytes.prefix(4).map { String(format: "%02x", $0) }.joined()

        if let session = noiseSessionManager?.getSession(for: peerID) {
            let ciphertext = try session.encrypt(plaintext: taggedPayload)
            DebugLogger.shared.log("CRYPTO", "\(subType) encrypted for \(peerHex) nonce=\(session.sendCipher.currentNonce)")

            let packet = MessagePayloadBuilder.buildPacket(
                type: .noiseEncrypted,
                payload: ciphertext,
                flags: flags,
                senderID: identity.peerID,
                recipientID: peerID
            )
            try await sendPacket(packet)
            return
        }

        guard shouldQueueIfHandshakeMissing else {
            throw MessageServiceError.sessionNotEstablished(peerID)
        }

        if try await initiateHandshakeIfNeeded(with: peerID) {
            let pendingControl = PendingEncryptedControlMessage(
                payload: payload,
                subType: subType,
                identity: identity,
                flags: flags
            )
            lock.withLock {
                pendingHandshakeControlMessages[peerID.bytes, default: []].append(pendingControl)
            }
            DebugLogger.shared.log("NOISE", "Queued \(subType) for \(peerHex) pending handshake")
            return
        }

        DebugLogger.shared.log("NOISE", "No Noise session for \(peerHex) and handshake could not be initiated", isError: true)
        throw MessageServiceError.sessionNotEstablished(peerID)
    }

    private func preferredDMChannel(from channels: [Channel]) -> Channel {
        var preferredChannel = channels[0]

        for candidate in channels.dropFirst() {
            if candidate.lastActivityAt > preferredChannel.lastActivityAt {
                preferredChannel = candidate
                continue
            }
            if candidate.lastActivityAt < preferredChannel.lastActivityAt {
                continue
            }
            if candidate.messages.count > preferredChannel.messages.count {
                preferredChannel = candidate
                continue
            }
            if candidate.messages.count < preferredChannel.messages.count {
                continue
            }
            if candidate.createdAt > preferredChannel.createdAt {
                preferredChannel = candidate
                continue
            }
            if candidate.createdAt < preferredChannel.createdAt {
                continue
            }
            if candidate.id.uuidString < preferredChannel.id.uuidString {
                preferredChannel = candidate
            }
        }

        return preferredChannel
    }
}
