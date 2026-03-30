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

    /// Total message balance across all packs.
    var messageBalance: Int = 0

    /// Whether the user has an unlimited subscription.
    var isUnlimited = false

    /// Editing state fields
    var editingUsername: String = ""
    var editingDisplayName: String = ""
    var editingBio: String = ""

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.blip", category: "ProfileViewModel")
    private let modelContainer: ModelContainer
    private let keyManager: KeyManager
    private let imageService: ImageService

    // MARK: - Constants

    private static let maxBioLength = 140
    private static let maxUsernameLength = 32

    // MARK: - Init

    init(
        modelContainer: ModelContainer,
        keyManager: KeyManager = .shared,
        imageService: ImageService = ImageService()
    ) {
        self.modelContainer = modelContainer
        self.keyManager = keyManager
        self.imageService = imageService
    }

    // MARK: - Load Profile

    /// Load the current user's profile and friends from SwiftData.
    func loadProfile() async {
        isLoading = true
        defer { isLoading = false }

        let context = ModelContext(modelContainer)

        do {
            // Load user
            let userDescriptor = FetchDescriptor<User>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let users = try context.fetch(userDescriptor)
            currentUser = users.first

            if let user = currentUser {
                editingUsername = user.username
                editingDisplayName = user.displayName ?? ""
                editingBio = user.bio ?? ""
            }

            // Load preferences
            preferences = try loadOrCreatePreferences(in: context)

            // Load friends
            let friendDescriptor = FetchDescriptor<Friend>(
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            let allFriends = try context.fetch(friendDescriptor)
            friends = allFriends.filter { $0.status == .accepted }
            pendingRequests = allFriends.filter { $0.status == .pending }
            blockedUsers = allFriends.filter { $0.status == .blocked }

            // Phone verification removed (FEZ-21: switched to email + social login)
            isPhoneVerified = false

            // Calculate message balance
            await refreshMessageBalance()

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

        let context = ModelContext(modelContainer)

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

        let context = ModelContext(modelContainer)

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

        } catch {
            errorMessage = "Failed to update avatar: \(error.localizedDescription)"
        }

        isUploadingAvatar = false
    }

    /// Remove the current avatar.
    func removeAvatar() async {
        guard let user = currentUser else { return }

        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
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

        let context = ModelContext(modelContainer)

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

    // MARK: - Message Balance

    private func refreshMessageBalance() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MessagePack>()
        do {
            let packs = try context.fetch(descriptor)
            isUnlimited = packs.contains { $0.isUnlimited }
            messageBalance = packs.reduce(0) { $0 + $1.messagesRemaining }
        } catch {
            logger.error("Failed to fetch message packs: \(error.localizedDescription)")
        }
    }

    // MARK: - Utility

    /// Dismiss transient messages.
    func clearMessages() {
        errorMessage = nil
        successMessage = nil
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
}
