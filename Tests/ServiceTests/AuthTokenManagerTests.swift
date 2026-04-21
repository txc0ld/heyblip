import XCTest
@testable import Blip
@testable import BlipCrypto

// Tests for AuthTokenManager.refreshToken() grace-window fallback.
//
// The server rejects /auth/refresh with 401 when the token has been expired
// for more than refreshGraceSeconds (300s). Before this fix the client would
// send the doomed request anyway. After the fix it detects the over-grace
// condition locally and falls back to re-authentication.
@MainActor
final class AuthTokenManagerTests: XCTestCase {

    // MARK: - Grace window fallback

    func testRefreshToken_expiredBeyondGrace_takesReauthPath() async {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let manager = AuthTokenManager(keyManager: keyManager)
        // Token expired 400s ago — beyond the 300s server grace window.
        manager.setStoredTokenForTesting(
            token: "header.payload.signature",
            expiresAt: Date().addingTimeInterval(-400)
        )

        do {
            try await manager.refreshIfNeeded(force: true)
            XCTFail("Expected an error from the re-auth path")
        } catch let error as AuthTokenManager.AuthError {
            // No identity was seeded, so re-auth fails with missingIdentity,
            // proving the code took the re-auth branch rather than hitting
            // /auth/refresh (which would 401 from the server).
            guard case .missingIdentity = error else {
                XCTFail("Expected missingIdentity, got: \(error)")
                return
            }
        } catch {
            XCTFail("Expected AuthError.missingIdentity, got: \(error)")
        }
    }

    func testRefreshToken_expiredWithinGrace_attemptsRefresh() async {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let manager = AuthTokenManager(keyManager: keyManager)
        // Token expired 60s ago — still within the 300s grace window.
        manager.setStoredTokenForTesting(
            token: "header.payload.signature",
            expiresAt: Date().addingTimeInterval(-60)
        )

        do {
            try await manager.refreshIfNeeded(force: true)
            XCTFail("Expected a network/server error")
        } catch let error as AuthTokenManager.AuthError {
            // Should be a serverError or unauthorized from attempting the real
            // /auth/refresh endpoint — NOT missingIdentity (which would indicate
            // it wrongly fell back to re-auth when the token is still refreshable).
            if case .missingIdentity = error {
                XCTFail("Should not have taken re-auth path for token within grace window")
            }
        } catch {
            // URLError or similar from a failed network call is expected and acceptable here.
        }
    }

    func testRefreshIfNeeded_tokenFresh_skipsRefresh() async throws {
        let keyManager = KeyManager(keyStore: InMemoryKeyManagerStore())
        let manager = AuthTokenManager(keyManager: keyManager)
        // Token expires in 600s — well outside the refreshThreshold (300s).
        manager.setStoredTokenForTesting(
            token: "header.payload.signature",
            expiresAt: Date().addingTimeInterval(600)
        )

        // Should return without hitting the network or re-auth.
        try await manager.refreshIfNeeded()
    }
}
