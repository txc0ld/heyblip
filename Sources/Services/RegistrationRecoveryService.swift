import Foundation
import SwiftData
import BlipCrypto
import os.log

@MainActor
final class RegistrationRecoveryService {
    struct LocalUserSnapshot: Sendable {
        let username: String
        let emailHash: String
        let noisePublicKey: Data
        let signingPublicKey: Data
    }

    struct Dependencies {
        let fetchLocalUser: @MainActor () throws -> LocalUserSnapshot?
        let loadIdentity: @MainActor () throws -> Identity?
        let registerKeys: @MainActor (_ localUser: LocalUserSnapshot, _ identity: Identity) async throws -> Void
        let lookupUser: @MainActor (String) async throws -> UserSyncService.RemoteLookupResult?
        let registerUserWithRetry: @MainActor (LocalUserSnapshot) async -> Void
        let refreshAuthSession: @MainActor (_ forceRefresh: Bool) async -> Void
    }

    private let dependencies: Dependencies
    private let logger = Logger(subsystem: "com.blip", category: "RegistrationRecovery")

    init(
        modelContainer: ModelContainer,
        keyManager: KeyManager,
        refreshAuthSession: @escaping @MainActor (_ forceRefresh: Bool) async -> Void
    ) {
        let syncService = UserSyncService()
        self.dependencies = Dependencies(
            fetchLocalUser: {
                let context = ModelContext(modelContainer)
                let users = try context.fetch(FetchDescriptor<User>())
                guard let localUser = users.min(by: { $0.createdAt < $1.createdAt }) else {
                    return nil
                }

                return LocalUserSnapshot(
                    username: localUser.username,
                    emailHash: localUser.emailHash,
                    noisePublicKey: localUser.noisePublicKey,
                    signingPublicKey: localUser.signingPublicKey
                )
            },
            loadIdentity: {
                try keyManager.loadIdentity()
            },
            registerKeys: { localUser, identity in
                try await syncService.registerUser(
                    emailHash: localUser.emailHash,
                    username: localUser.username,
                    noisePublicKey: identity.noisePublicKey.rawRepresentation,
                    signingPublicKey: identity.signingPublicKey
                )
            },
            lookupUser: { username in
                try await syncService.lookupUser(username: username)
            },
            registerUserWithRetry: { localUser in
                await syncService.registerUserWithRetry(
                    emailHash: localUser.emailHash,
                    username: localUser.username,
                    noisePublicKey: localUser.noisePublicKey,
                    signingPublicKey: localUser.signingPublicKey
                )
            },
            refreshAuthSession: refreshAuthSession
        )
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func resyncKeysIfNeeded() async {
        do {
            guard let localUser = try dependencies.fetchLocalUser(),
                  !localUser.emailHash.isEmpty else {
                DebugLogger.shared.log("AUTH", "Key re-sync skipped — no local user or empty emailHash")
                return
            }

            guard let identity = try dependencies.loadIdentity() else {
                DebugLogger.shared.log("AUTH", "Key re-sync skipped — no identity in Keychain")
                return
            }

            let noiseKeyHex = identity.noisePublicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            let signingKeyHex = identity.signingPublicKey.map { String(format: "%02x", $0) }.joined()
            DebugLogger.shared.log(
                "AUTH",
                "Key re-sync starting for \(DebugLogger.redact(localUser.username)) — noiseKey: \(DebugLogger.redactHex(String(noiseKeyHex.prefix(16))))…, signingKey: \(DebugLogger.redactHex(String(signingKeyHex.prefix(16))))…"
            )

            try await dependencies.registerKeys(localUser, identity)
            DebugLogger.shared.log("AUTH", "Key upload succeeded for \(DebugLogger.redact(localUser.username))")
            await dependencies.refreshAuthSession(true)
        } catch {
            logger.error("Key re-sync failed: \(error.localizedDescription)")
            DebugLogger.shared.log("AUTH", "Key upload failed: \(error.localizedDescription)", isError: true)
        }
    }

    func verifyServerRegistration() async -> Bool {
        do {
            guard let localUser = try dependencies.fetchLocalUser() else {
                logger.info("SELF_CHECK — no local user, skipping")
                DebugLogger.shared.log("SELF_CHECK", "No local user found, skipping")
                return false
            }

            let result = try await dependencies.lookupUser(localUser.username)
            if result != nil {
                logger.info("SELF_CHECK PASS — \(localUser.username, privacy: .private) found on server")
                DebugLogger.shared.log("SELF_CHECK", "PASS — \(DebugLogger.redact(localUser.username)) found on server")
                await dependencies.refreshAuthSession(true)
                return false
            }

            logger.warning("SELF_CHECK FAIL — \(localUser.username, privacy: .private) not registered, re-registering")
            DebugLogger.shared.log("SELF_CHECK", "FAIL — not registered, re-registering", isError: true)

            await dependencies.registerUserWithRetry(localUser)
            let retryResult = try? await dependencies.lookupUser(localUser.username)
            await dependencies.refreshAuthSession(true)
            return retryResult == nil
        } catch {
            logger.error("SELF_CHECK error: \(error.localizedDescription)")
            DebugLogger.shared.log("SELF_CHECK", "Error: \(error.localizedDescription)", isError: true)
            return true
        }
    }

    func retryRegistration() async -> Bool {
        DebugLogger.shared.log("AUTH", "Manual registration retry triggered")
        return await verifyServerRegistration()
    }
}
