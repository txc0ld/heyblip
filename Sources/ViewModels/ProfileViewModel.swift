import Foundation
import UIKit
import SwiftData
import os.log
import BlipProtocol
import BlipCrypto

// MARK: - Profile View Model

/// Manages the user profile, avatar upload, friends list, and block/unblock actions.
///
/// Handles:
/// - User profile CRUD (username, display name, bio)
/// - Avatar capture (camera/library), crop, compress, and store
/// - Friends list with status (pending, accepted, blocked)
/// - Block/unblock actions
/// - Profile export (recovery kit)
@MainActor
@Observable
final class ProfileViewModel {

    struct AccountExportFile: Sendable {
        let url: URL
        let itemCount: Int
    }

    private struct AccountExportPayload: Encodable {
        let schemaVersion: Int
        let exportedAt: Date
        let user: ExportUser?
        let preferences: ExportPreferences?
        let friends: [ExportFriend]
        let messages: [ExportMessage]
        let joinedEvents: [ExportJoinedEvent]
        let savedSetTimes: [ExportSetTime]
    }

    private struct ExportUser: Encodable {
        let id: UUID
        let username: String
        let displayName: String?
        let emailHash: String
        let noisePublicKey: Data
        let signingPublicKey: Data
        let avatarThumbnail: Data?
        let avatarFullRes: Data?
        let avatarURL: String?
        let bio: String?
        let isVerified: Bool
        let createdAt: Date

        init(user: User) {
            id = user.id
            username = user.username
            displayName = user.displayName
            emailHash = user.emailHash
            noisePublicKey = user.noisePublicKey
            signingPublicKey = user.signingPublicKey
            avatarThumbnail = user.avatarThumbnail
            avatarFullRes = user.avatarFullRes
            avatarURL = user.avatarURL
            bio = user.bio
            isVerified = user.isVerified
            createdAt = user.createdAt
        }
    }

    private struct ExportPreferences: Encodable {
        let theme: AppTheme
        let defaultLocationSharing: LocationPrecision
        let proximityAlertsEnabled: Bool
        let breadcrumbsEnabled: Bool
        let notificationsEnabled: Bool
        let pttMode: PTTMode
        let autoJoinNearbyChannels: Bool
        let crowdPulseVisible: Bool
        let nearbyVisibilityEnabled: Bool
        let friendFinderMapStyle: MapStyle
        let lastEventID: UUID?

        init(preferences: UserPreferences) {
            theme = preferences.theme
            defaultLocationSharing = preferences.defaultLocationSharing
            proximityAlertsEnabled = preferences.proximityAlertsEnabled
            breadcrumbsEnabled = preferences.breadcrumbsEnabled
            notificationsEnabled = preferences.notificationsEnabled
            pttMode = preferences.pttMode
            autoJoinNearbyChannels = preferences.autoJoinNearbyChannels
            crowdPulseVisible = preferences.crowdPulseVisible
            nearbyVisibilityEnabled = preferences.nearbyVisibilityEnabled
            friendFinderMapStyle = preferences.friendFinderMapStyle
            lastEventID = preferences.lastEventID
        }
    }

    private struct ExportFriend: Encodable {
        let id: UUID
        let username: String?
        let displayName: String?
        let nickname: String?
        let status: FriendStatus
        let requestDirection: FriendRequestDirection?
        let phoneVerified: Bool
        let locationSharingEnabled: Bool
        let locationPrecision: LocationPrecision
        let lastSeenLatitude: Double?
        let lastSeenLongitude: Double?
        let lastSeenAt: Date?
        let addedAt: Date

        init(friend: Friend) {
            id = friend.id
            username = friend.user?.username
            displayName = friend.user?.resolvedDisplayName
            nickname = friend.nickname
            status = friend.status
            requestDirection = friend.requestDirection
            phoneVerified = friend.phoneVerified
            locationSharingEnabled = friend.locationSharingEnabled
            locationPrecision = friend.locationPrecision
            lastSeenLatitude = friend.lastSeenLatitude
            lastSeenLongitude = friend.lastSeenLongitude
            lastSeenAt = friend.lastSeenAt
            addedAt = friend.addedAt
        }
    }

    private struct ExportMessage: Encodable {
        let id: UUID
        let channelID: UUID?
        let channelName: String?
        let channelType: String?
        let senderUsername: String?
        let type: MessageType
        let status: MessageStatus
        let rawPayload: Data
        let utf8Text: String?
        let isRelayed: Bool
        let hopCount: Int
        let isEdited: Bool
        let isDeleted: Bool
        let editedAt: Date?
        let createdAt: Date
        let expiresAt: Date?

        init(message: Message) {
            id = message.id
            channelID = message.channel?.id
            channelName = message.channel?.name
            channelType = message.channel?.typeRaw
            senderUsername = message.sender?.username
            type = message.type
            status = message.status
            rawPayload = message.rawPayload
            utf8Text = String(data: message.rawPayload, encoding: .utf8)
            isRelayed = message.isRelayed
            hopCount = message.hopCount
            isEdited = message.isEdited
            isDeleted = message.isDeleted
            editedAt = message.editedAt
            createdAt = message.createdAt
            expiresAt = message.expiresAt
        }
    }

    private struct ExportJoinedEvent: Encodable {
        let id: UUID
        let eventId: String
        let joinedAt: Date

        init(joinedEvent: JoinedEvent) {
            id = joinedEvent.id
            eventId = joinedEvent.eventId
            joinedAt = joinedEvent.joinedAt
        }
    }

    private struct ExportSetTime: Encodable {
        let id: UUID
        let artistName: String
        let stageName: String?
        let eventName: String?
        let startTime: Date
        let endTime: Date
        let savedByUser: Bool
        let reminderSet: Bool

        init(setTime: SetTime) {
            id = setTime.id
            artistName = setTime.artistName
            stageName = setTime.stage?.name
            eventName = setTime.stage?.event?.name
            startTime = setTime.startTime
            endTime = setTime.endTime
            savedByUser = setTime.savedByUser
            reminderSet = setTime.reminderSet
        }
    }

    // MARK: - Published State

    /// The local user's profile.
    var currentUser: User?

    /// User preferences.
    var preferences: UserPreferences?

    /// Friends list sorted by status then name.
    var friends: [Friend] = []

    /// Pending friend requests.
    var pendingRequests: [Friend] = []

    /// Blocked users.
    var blockedUsers: [Friend] = []

    /// Whether the profile is loading.
    var isLoading = false

    /// Whether an avatar upload is in progress.
    var isUploadingAvatar = false

    /// Whether a profile save is in progress.
    var isSaving = false

    /// Error message, if any.
    var errorMessage: String?

    /// Success message for transient feedback.
    var successMessage: String?

    /// Whether the user has completed phone verification.
    var isPhoneVerified = false

    /// Editing state fields
    var editingUsername: String = ""
    var editingDisplayName: String = ""
    var editingBio: String = ""

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.blip", category: "ProfileViewModel")
    private let modelContainer: ModelContainer
    private let context: ModelContext
    private let keyManager: KeyManager
    private let imageService: ImageService
    private let userSyncService: UserSyncService

    // MARK: - Constants

    private static let maxBioLength = 140
    private static let maxUsernameLength = 32

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        keyManager: KeyManager = .shared,
        imageService: ImageService = ImageService(),
        userSyncService: UserSyncService = UserSyncService()
    ) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
        self.keyManager = keyManager
        self.imageService = imageService
        self.userSyncService = userSyncService
    }

    // MARK: - Load Profile

    /// Load the current user's profile and friends from SwiftData.
    func loadProfile() async {
        isLoading = true
        defer { isLoading = false }

        let context = self.context

        do {
            // Load user
            let users = try context.fetch(FetchDescriptor<User>())
            currentUser = users.min(by: { $0.createdAt < $1.createdAt })

            if let user = currentUser {
                editingUsername = user.username
                editingDisplayName = user.displayName ?? ""
                editingBio = user.bio ?? ""
            }

            // Load preferences
            preferences = try loadOrCreatePreferences(in: context)

            // Load friends
            let allFriends = try context.fetch(FetchDescriptor<Friend>())
                .sorted { $0.addedAt > $1.addedAt }
            friends = allFriends.filter { $0.status == .accepted }
            pendingRequests = allFriends.filter { $0.status == .pending }
            blockedUsers = allFriends.filter { $0.status == .blocked }

            // Phone verification removed (FEZ-21: switched to email + social login)
            isPhoneVerified = false

        } catch {
            errorMessage = "Failed to load profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Save Profile

    /// Save profile changes (display name, bio).
    func saveProfile() async {
        guard let user = currentUser else { return }

        isSaving = true
        errorMessage = nil

        let context = self.context

        // Validate
        let trimmedDisplayName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = editingBio.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedBio.count > Self.maxBioLength {
            errorMessage = "Bio must be \(Self.maxBioLength) characters or less"
            isSaving = false
            return
        }

        // Update
        user.displayName = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        user.bio = trimmedBio.isEmpty ? nil : String(trimmedBio.prefix(Self.maxBioLength))

        do {
            try context.save()
            successMessage = "Profile saved"
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }

    // MARK: - Avatar Management

    /// Upload and process a new avatar image.
    ///
    /// Flow: crop to square -> generate 64x64 thumbnail -> compress full-res -> store both
    func updateAvatar(imageData: Data) async {
        guard let user = currentUser else { return }
        guard let image = UIImage(data: imageData) else {
            errorMessage = "Invalid image data"
            return
        }

        isUploadingAvatar = true
        errorMessage = nil

        let context = self.context

        do {
            // Center-crop to square
            let cropped = imageService.centerCrop(image: image)

            // Generate avatar thumbnail (64x64)
            let thumbnailData = try imageService.generateThumbnail(from: cropped, size: .avatar)

            // Compress full-res (capped at 500KB for mesh, but stored locally at higher quality)
            let fullResData: Data
            if let compressed = cropped.jpegData(compressionQuality: 0.8) {
                fullResData = compressed
            } else {
                throw ImageServiceError.compressionFailed
            }

            // Store both
            user.avatarThumbnail = thumbnailData
            user.avatarFullRes = fullResData

            try context.save()

            // Cache the avatar
            imageService.cacheImage(fullResData, forKey: "avatar_\(user.id.uuidString)")

            successMessage = "Avatar updated"

            // Upload to CDN (fire-and-forget)
            let uploadData = fullResData
            let syncService = self.userSyncService
            Task { [weak user] in
                do {
                    let url = try await syncService.uploadAvatar(uploadData)
                    user?.avatarURL = url
                    do {
                        try context.save()
                    } catch {
                        DebugLogger.shared.log("PROFILE", "Failed to persist avatar URL: \(error.localizedDescription)", isError: true)
                    }
                    DebugLogger.shared.log("PROFILE", "Avatar uploaded to CDN: \(DebugLogger.redact(url))")
                } catch {
                    DebugLogger.shared.log("PROFILE", "Avatar CDN upload failed: \(error.localizedDescription)", isError: true)
                }
            }

        } catch {
            errorMessage = "Failed to update avatar: \(error.localizedDescription)"
        }

        isUploadingAvatar = false
    }

    /// Remove the current avatar.
    func removeAvatar() async {
        guard let user = currentUser else { return }

        let context = self.context
        user.avatarThumbnail = nil
        user.avatarFullRes = nil

        do {
            try context.save()
            imageService.removeCachedImage(forKey: "avatar_\(user.id.uuidString)")
            successMessage = "Avatar removed"
        } catch {
            errorMessage = "Failed to remove avatar: \(error.localizedDescription)"
        }
    }

    // MARK: - Friend Management

    /// Accept a pending friend request.
    func acceptFriendRequest(_ friend: Friend) async {
        let context = self.context
        friend.status = .accepted
        do {
            try context.save()
            pendingRequests.removeAll { $0.id == friend.id }
            friends.append(friend)
            friends.sort { ($0.user?.resolvedDisplayName ?? "") < ($1.user?.resolvedDisplayName ?? "") }
            successMessage = "Friend request accepted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Decline a pending friend request.
    func declineFriendRequest(_ friend: Friend) async {
        let context = self.context
        context.delete(friend)
        do {
            try context.save()
            pendingRequests.removeAll { $0.id == friend.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Block a user.
    func blockUser(_ friend: Friend) async {
        let context = self.context
        friend.status = .blocked
        do {
            try context.save()
            friends.removeAll { $0.id == friend.id }
            blockedUsers.append(friend)
            successMessage = "User blocked"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Unblock a user.
    func unblockUser(_ friend: Friend) async {
        let context = self.context
        friend.status = .accepted
        do {
            try context.save()
            blockedUsers.removeAll { $0.id == friend.id }
            friends.append(friend)
            successMessage = "User unblocked"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove a friend entirely.
    func removeFriend(_ friend: Friend) async {
        let context = self.context
        context.delete(friend)
        do {
            try context.save()
            friends.removeAll { $0.id == friend.id }
            successMessage = "Friend removed"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Update the location sharing settings for a friend.
    func updateLocationSharing(for friend: Friend, enabled: Bool, precision: LocationPrecision) {
        let context = self.context
        friend.locationSharingEnabled = enabled
        friend.locationPrecision = precision
        do {
            try context.save()
        } catch {
            logger.error("Failed to save location sharing settings: \(error.localizedDescription)")
            errorMessage = "Failed to update location sharing: \(error.localizedDescription)"
        }
    }

    /// Set a nickname for a friend.
    func setNickname(for friend: Friend, nickname: String?) {
        let context = self.context
        friend.nickname = nickname?.isEmpty == true ? nil : nickname
        do {
            try context.save()
        } catch {
            logger.error("Failed to save nickname: \(error.localizedDescription)")
            errorMessage = "Failed to update nickname: \(error.localizedDescription)"
        }
    }

    // MARK: - Recovery Kit

    /// Export a recovery kit (encrypted keypair backup).
    func exportRecoveryKit(password: String) async throws -> Data {
        let kit = try keyManager.exportRecoveryKit(password: password)
        return kit.data
    }

    /// Import a recovery kit.
    func importRecoveryKit(data: Data, password: String) async throws {
        let kit = RecoveryKit(data: data)
        _ = try keyManager.importRecoveryKit(kit, password: password)
        successMessage = "Recovery kit imported successfully"
        await loadProfile()
    }

    // MARK: - Preferences

    /// Update user preferences.
    func updatePreferences(
        theme: AppTheme? = nil,
        defaultLocationSharing: LocationPrecision? = nil,
        proximityAlertsEnabled: Bool? = nil,
        breadcrumbsEnabled: Bool? = nil,
        notificationsEnabled: Bool? = nil,
        pttMode: PTTMode? = nil,
        autoJoinNearbyChannels: Bool? = nil,
        crowdPulseVisible: Bool? = nil,
        mapStyle: MapStyle? = nil
    ) {
        guard let prefs = preferences else { return }

        let context = self.context

        if let theme { prefs.theme = theme }
        if let sharing = defaultLocationSharing { prefs.defaultLocationSharing = sharing }
        if let alerts = proximityAlertsEnabled { prefs.proximityAlertsEnabled = alerts }
        if let breadcrumbs = breadcrumbsEnabled { prefs.breadcrumbsEnabled = breadcrumbs }
        if let notifications = notificationsEnabled { prefs.notificationsEnabled = notifications }
        if let ptt = pttMode { prefs.pttMode = ptt }
        if let autoJoin = autoJoinNearbyChannels { prefs.autoJoinNearbyChannels = autoJoin }
        if let crowdPulse = crowdPulseVisible { prefs.crowdPulseVisible = crowdPulse }
        if let style = mapStyle { prefs.friendFinderMapStyle = style }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save preferences: \(error.localizedDescription)")
            errorMessage = "Failed to save preferences: \(error.localizedDescription)"
        }
    }

    // MARK: - Utility

    /// Dismiss transient messages.
    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    // MARK: - Account Management

    func exportAccountData(password: String) async throws -> AccountExportFile {
        DebugLogger.shared.log("ACCOUNT", "Starting encrypted account data export")
        let context = self.context

        do {
            let users = try context.fetch(FetchDescriptor<User>())
            let currentUser = users.min(by: { $0.createdAt < $1.createdAt })
            let friends = try context.fetch(FetchDescriptor<Friend>())
                .sorted { $0.addedAt < $1.addedAt }
            let messages = try context.fetch(FetchDescriptor<Message>())
                .sorted { $0.createdAt < $1.createdAt }
            let joinedEvents = try context.fetch(FetchDescriptor<JoinedEvent>())
                .sorted { $0.joinedAt < $1.joinedAt }
            let savedSetTimes = try context.fetch(FetchDescriptor<SetTime>())
                .filter { $0.savedByUser || $0.reminderSet }
                .sorted { $0.startTime < $1.startTime }
            let preferences = try context.fetch(FetchDescriptor<UserPreferences>()).first

            let payload = AccountExportPayload(
                schemaVersion: 1,
                exportedAt: Date(),
                user: currentUser.map(ExportUser.init),
                preferences: preferences.map(ExportPreferences.init),
                friends: friends.map(ExportFriend.init),
                messages: messages.map(ExportMessage.init),
                joinedEvents: joinedEvents.map(ExportJoinedEvent.init),
                savedSetTimes: savedSetTimes.map(ExportSetTime.init)
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            encoder.dataEncodingStrategy = .base64

            let jsonData = try encoder.encode(payload)

            // Encrypt the JSON with the user's password using AES-256-GCM
            let encryptedData = try keyManager.encryptData(jsonData, password: password)

            let timestamp = exportFileTimestamp(for: Date())
            let username = sanitizeFileComponent(currentUser?.username ?? "account")
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("heyblip-account-export-\(username)-\(timestamp)")
                .appendingPathExtension("heyblipexport")

            try encryptedData.write(to: fileURL, options: .atomic)
            DebugLogger.shared.log(
                "ACCOUNT",
                "Encrypted account export ready: \(fileURL.lastPathComponent) (\(encryptedData.count) bytes, plaintext: \(jsonData.count) bytes)"
            )

            return AccountExportFile(
                url: fileURL,
                itemCount: friends.count + messages.count + joinedEvents.count + savedSetTimes.count + (currentUser == nil ? 0 : 1)
            )
        } catch {
            DebugLogger.shared.log("ACCOUNT", "Account export failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    func deleteAccountRemotely() async throws {
        guard currentUser != nil else {
            DebugLogger.shared.log("ACCOUNT", "Remote account deletion failed: missing local user", isError: true)
            throw UserSyncService.SyncError.missingLocalUser
        }

        DebugLogger.shared.log("ACCOUNT", "Requesting remote account deletion")

        do {
            try await userSyncService.deleteCurrentUser()
            DebugLogger.shared.log("ACCOUNT", "Remote account deletion completed")
        } catch {
            DebugLogger.shared.log("ACCOUNT", "Remote account deletion failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    private func loadOrCreatePreferences(in context: ModelContext) throws -> UserPreferences {
        let descriptor = FetchDescriptor<UserPreferences>()
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let preferences = UserPreferences()
        context.insert(preferences)
        try context.save()
        return preferences
    }

    private func sanitizeFileComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sanitized = String(trimmed.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined())
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "account" : sanitized
    }

    private func exportFileTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }
}
