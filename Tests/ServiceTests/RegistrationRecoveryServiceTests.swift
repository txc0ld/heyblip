import XCTest
@testable import Blip
@testable import BlipCrypto

@MainActor
final class RegistrationRecoveryServiceTests: XCTestCase {
    func testVerifyServerRegistration_whenUserExists_clearsPendingAndRefreshesAuth() async throws {
        let localUser = RegistrationRecoveryService.LocalUserSnapshot(
            username: "alice",
            emailHash: "hash",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32)
        )

        var refreshCalls: [Bool] = []
        let service = RegistrationRecoveryService(
            dependencies: .init(
                fetchLocalUser: { localUser },
                loadIdentity: { nil },
                registerKeys: { _, _ in XCTFail("Key re-sync should not run during self-check") },
                lookupUser: { username in
                    XCTAssertEqual(username, "alice")
                    return UserSyncService.RemoteLookupResult(
                        id: "remote-1",
                        username: username,
                        isVerified: true,
                        noisePublicKey: nil,
                        signingPublicKey: nil,
                        avatarURL: nil,
                        lastActiveAt: nil
                    )
                },
                registerUserWithRetry: { _ in XCTFail("Retry should not run when user already exists") },
                refreshAuthSession: { forceRefresh in
                    refreshCalls.append(forceRefresh)
                }
            )
        )

        let pending = await service.verifyServerRegistration()

        XCTAssertFalse(pending)
        XCTAssertEqual(refreshCalls, [true])
    }

    func testVerifyServerRegistration_whenMissing_retriesAndUsesSecondLookupResult() async {
        let localUser = RegistrationRecoveryService.LocalUserSnapshot(
            username: "alice",
            emailHash: "hash",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32)
        )

        var lookupCount = 0
        var retriedUsers: [RegistrationRecoveryService.LocalUserSnapshot] = []
        var refreshCalls: [Bool] = []

        let service = RegistrationRecoveryService(
            dependencies: .init(
                fetchLocalUser: { localUser },
                loadIdentity: { nil },
                registerKeys: { _, _ in XCTFail("Key re-sync should not run during manual retry") },
                lookupUser: { _ in
                    lookupCount += 1
                    if lookupCount == 1 {
                        return nil
                    }
                    return UserSyncService.RemoteLookupResult(
                        id: "remote-2",
                        username: localUser.username,
                        isVerified: false,
                        noisePublicKey: nil,
                        signingPublicKey: nil,
                        avatarURL: nil,
                        lastActiveAt: nil
                    )
                },
                registerUserWithRetry: { snapshot in
                    retriedUsers.append(snapshot)
                },
                refreshAuthSession: { forceRefresh in
                    refreshCalls.append(forceRefresh)
                }
            )
        )

        let pending = await service.verifyServerRegistration()

        XCTAssertFalse(pending)
        XCTAssertEqual(lookupCount, 2)
        XCTAssertEqual(retriedUsers.map(\.username), ["alice"])
        XCTAssertEqual(refreshCalls, [true])
    }

    func testResyncKeysIfNeeded_uploadsIdentityKeysAndRefreshesAuth() async throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let identity = try keyManager.generateIdentity()
        let localUser = RegistrationRecoveryService.LocalUserSnapshot(
            username: "alice",
            emailHash: "hash",
            noisePublicKey: Data(repeating: 9, count: 32),
            signingPublicKey: Data(repeating: 8, count: 32)
        )

        var uploadedUser: RegistrationRecoveryService.LocalUserSnapshot?
        var uploadedIdentity: Identity?
        var refreshCalls: [Bool] = []

        let service = RegistrationRecoveryService(
            dependencies: .init(
                fetchLocalUser: { localUser },
                loadIdentity: { identity },
                registerKeys: { snapshot, loadedIdentity in
                    uploadedUser = snapshot
                    uploadedIdentity = loadedIdentity
                },
                lookupUser: { _ in nil },
                registerUserWithRetry: { _ in XCTFail("Retry should not run during key re-sync") },
                refreshAuthSession: { forceRefresh in
                    refreshCalls.append(forceRefresh)
                }
            )
        )

        await service.resyncKeysIfNeeded()

        XCTAssertEqual(uploadedUser?.username, "alice")
        XCTAssertEqual(uploadedIdentity?.peerID, identity.peerID)
        XCTAssertEqual(refreshCalls, [true])
    }
}
