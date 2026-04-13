import Foundation
import BlipCrypto
@preconcurrency import Sodium
import os.log

/// Handles user registration, profile sync, and receipt verification
/// with the Blip backend API.
///
/// All calls are gated on connectivity — callers should check transport mode
/// before invoking (skip if BLE-only mode).
final class UserSyncService: Sendable {

    // MARK: - Configuration

    private static let baseURL = ServerConfig.authBaseURL

    private let logger = Logger(subsystem: "com.blip", category: "UserSync")
    private let authTokenProvider: @Sendable () async throws -> String

    // MARK: - Errors

    enum SyncError: LocalizedError, Sendable {
        case networkError(String)
        case serverError(String)
        case badRequest(String)
        case usernameTaken
        case userNotFound
        case databaseNotConfigured
        case unauthorized
        case missingLocalUser

        var errorDescription: String? {
            switch self {
            case .networkError(let detail):
                return "Network error: \(detail)"
            case .serverError(let detail):
                return "Server error: \(detail)"
            case .badRequest(let detail):
                return detail
            case .usernameTaken:
                return "Username is already taken."
            case .userNotFound:
                return "User not found on server."
            case .databaseNotConfigured:
                return "Backend database is not yet configured."
            case .unauthorized:
                return "Authentication required."
            case .missingLocalUser:
                return "Local account details are unavailable."
            }
        }
    }

    init(
        authTokenProvider: @escaping @Sendable () async throws -> String = {
            try await AuthTokenManager.shared.validToken()
        }
    ) {
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Registration Gate

    /// Shared gate to prevent concurrent registration requests.
    /// Multiple callers (onboarding, AppCoordinator key re-sync, self-check) may
    /// attempt registration simultaneously after onboarding completes. This
    /// serializes them so only one network request fires at a time.
    private static let registrationGate = RegistrationGate()

    private actor RegistrationGate {
        private var inProgress = false

        /// Returns true if this caller should proceed; false if another registration is in flight.
        func tryAcquire() -> Bool {
            if inProgress { return false }
            inProgress = true
            return true
        }

        func release() {
            inProgress = false
        }
    }

    // MARK: - Register User

    /// Register a new user after onboarding completes.
    /// Fire-and-forget — failures are logged but don't block the user.
    /// Gated by a shared lock so concurrent callers (onboarding retry, AppCoordinator
    /// key re-sync, self-check) don't fire duplicate requests.
    func registerUser(
        emailHash: String,
        username: String,
        noisePublicKey: Data? = nil,
        signingPublicKey: Data? = nil
    ) async throws {
        guard await Self.registrationGate.tryAcquire() else {
            DebugLogger.emit("AUTH", "Registration skipped for \(DebugLogger.redact(username)) — already in progress")
            return
        }

        do {
            try await performRegistration(
                emailHash: emailHash,
                username: username,
                noisePublicKey: noisePublicKey,
                signingPublicKey: signingPublicKey
            )
            await Self.registrationGate.release()
        } catch {
            await Self.registrationGate.release()
            throw error
        }
    }

    /// The actual registration network call, separated from the gate logic.
    private func performRegistration(
        emailHash: String,
        username: String,
        noisePublicKey: Data?,
        signingPublicKey: Data?
    ) async throws {
        var body: [String: Any] = [
            "emailHash": emailHash,
            "username": username,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let key = noisePublicKey {
            body["noisePublicKey"] = key.map { String(format: "%02x", $0) }.joined()
        }
        if let key = signingPublicKey {
            body["signingPublicKey"] = key.map { String(format: "%02x", $0) }.joined()
        }

        if noisePublicKey != nil, signingPublicKey != nil {
            let challenge = try await requestChallenge()

            let identity: Identity
            do {
                guard let loadedIdentity = try KeyManager.shared.loadIdentity() else {
                    DebugLogger.emit("AUTH", "Registration signing failed for \(DebugLogger.redact(username)) — missing local identity", isError: true)
                    throw SyncError.serverError("Missing signing identity")
                }
                identity = loadedIdentity
            } catch let error as SyncError {
                throw error
            } catch {
                DebugLogger.emit("AUTH", "Failed to load signing identity for \(DebugLogger.redact(username)): \(error.localizedDescription)", isError: true)
                throw SyncError.serverError("Failed to load signing identity")
            }

            let signature: String
            do {
                signature = try signChallenge(challenge, secretKey: identity.signingSecretKey)
            } catch let error as SyncError {
                DebugLogger.emit("AUTH", "Failed to sign registration challenge for \(DebugLogger.redact(username)): \(error.localizedDescription)", isError: true)
                throw error
            } catch {
                DebugLogger.emit("AUTH", "Failed to sign registration challenge for \(DebugLogger.redact(username)): \(error.localizedDescription)", isError: true)
                throw SyncError.serverError("Ed25519 signing failed")
            }

            body["challenge"] = challenge
            body["signature"] = signature
        }

        let (data, response) = try await post(path: "/users/register", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
        DebugLogger.emit("AUTH", "Register \(DebugLogger.redact(username)): \(http.statusCode) — \(DebugLogger.redact(responseBody))")

        switch http.statusCode {
        case 200, 201:
            logger.info("User registered: \(username, privacy: .private)")
        case 400:
            let message = parseError(data) ?? "Invalid registration data"
            throw SyncError.badRequest(message)
        case 409:
            throw SyncError.usernameTaken
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
    }

    // MARK: - Register with Retry

    /// Wraps `registerUser()` with up to 3 attempts and exponential backoff (2s, 4s, 8s).
    /// If all attempts fail, the error is logged but not thrown — app-launch re-sync will catch it.
    func registerUserWithRetry(
        emailHash: String,
        username: String,
        noisePublicKey: Data? = nil,
        signingPublicKey: Data? = nil
    ) async {
        let maxAttempts = 3
        let baseDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds

        for attempt in 1...maxAttempts {
            do {
                logger.info("Registration attempt \(attempt)/\(maxAttempts) for \(username, privacy: .private)")
                DebugLogger.emit("REGISTER", "Attempt \(attempt)/\(maxAttempts) for \(DebugLogger.redact(username))")

                try await registerUser(
                    emailHash: emailHash,
                    username: username,
                    noisePublicKey: noisePublicKey,
                    signingPublicKey: signingPublicKey
                )

                logger.info("Registration succeeded on attempt \(attempt)")
                DebugLogger.emit("REGISTER", "Success on attempt \(attempt)")
                return
            } catch {
                logger.warning("Registration attempt \(attempt) failed: \(error.localizedDescription)")
                DebugLogger.emit("REGISTER", "Attempt \(attempt) failed: \(error.localizedDescription)", isError: true)

                if attempt < maxAttempts {
                    let delay = baseDelay * UInt64(1 << (attempt - 1)) // 2s, 4s, 8s
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        DebugLogger.emit("REGISTER", "Retry sleep cancelled after attempt \(attempt): \(error.localizedDescription)", isError: true)
                        return
                    }
                }
            }
        }

        logger.error("Registration failed after \(maxAttempts) attempts — will retry on next launch")
        DebugLogger.emit("REGISTER", "All \(maxAttempts) attempts failed — deferring to app-launch re-sync", isError: true)
    }

    // MARK: - Sync Profile

    /// Sync local profile state to the server (called on app launch when online).
    func syncProfile(
        emailHash: String,
        isVerified: Bool? = nil,
        messageBalance: Int? = nil
    ) async throws {
        let body: [String: Any] = [
            "emailHash": emailHash,
            "lastActiveAt": ISO8601DateFormatter().string(from: Date())
        ]

        let (data, response) = try await post(path: "/users/sync", body: body, requiresAuth: true)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            logger.info("Profile synced for \(emailHash.prefix(8), privacy: .private)...")
        case 404:
            throw SyncError.userNotFound
        case 401:
            throw SyncError.unauthorized
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
    }

    // MARK: - Verify Receipt

    /// Send a StoreKit 2 JWS transaction to the backend for server-side validation.
    /// Returns the server response including verification status and credited balance.
    func verifyReceipt(
        transactionID: String,
        productID: String,
        originalID: String,
        purchaseDate: Date,
        emailHash: String,
        environment: String
    ) async throws -> ReceiptResult {
        let body: [String: Any] = [
            "transactionID": transactionID,
            "productID": productID,
            "originalID": originalID,
            "purchaseDate": ISO8601DateFormatter().string(from: purchaseDate),
            "emailHash": emailHash,
            "environment": environment
        ]

        let (data, response) = try await post(path: "/receipts/verify", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.serverError("Invalid response body")
            }
            return ReceiptResult(
                valid: json["valid"] as? Bool ?? false,
                isVerified: json["isVerified"] as? Bool ?? false,
                credits: json["credits"] as? Int ?? 0
            )
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
    }

    // MARK: - Get User (account recovery)

    /// Fetch user profile from server by email hash (for account recovery).
    func getUser(emailHash: String) async throws -> ServerUser {
        guard let url = URL(string: "\(Self.baseURL)/users/\(emailHash)") else {
            throw SyncError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await performAuthenticatedRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userDict = json["user"] as? [String: Any] else {
                throw SyncError.serverError("Invalid response body")
            }
            return ServerUser(
                id: userDict["id"] as? String ?? "",
                username: userDict["username"] as? String ?? "",
                isVerified: userDict["is_verified"] as? Bool ?? false,
                messageBalance: userDict["message_balance"] as? Int ?? 0,
                lastActiveAt: userDict["last_active_at"] as? String,
                createdAt: userDict["created_at"] as? String ?? ""
            )
        case 404:
            throw SyncError.userNotFound
        case 401:
            throw SyncError.unauthorized
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
    }

    // MARK: - Delete Account

    /// Delete the authenticated user account from the auth backend.
    func deleteCurrentUser() async throws {
        guard let url = URL(string: "\(Self.baseURL)/users/self") else {
            throw SyncError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15

        let (data, response) = try await performAuthenticatedRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            logger.info("Account deleted on server")
        case 401:
            throw SyncError.unauthorized
        case 404:
            throw SyncError.userNotFound
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
    }

    // MARK: - Lookup by Username

    /// Look up a user by username via the auth server.
    /// Returns nil if not found (404).
    func lookupUser(username: String) async throws -> RemoteLookupResult? {
        guard let url = URL(string: "\(Self.baseURL)/users/lookup/\(username)") else {
            throw SyncError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await performAuthenticatedRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw SyncError.unauthorized }

        guard http.statusCode == 200 else {
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.serverError("Invalid response body")
            }
            json = parsed
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.serverError("Invalid response body")
        }

        guard let userDict = json["user"] as? [String: Any] else {
            throw SyncError.serverError("Invalid response body")
        }

        // Server returns 200 with id: null for unknown users (anti-enumeration).
        guard let id = userDict["id"] as? String, !id.isEmpty else {
            return nil
        }
        guard let username = userDict["username"] as? String, !username.isEmpty else {
            throw SyncError.serverError("Missing username in lookup response")
        }

        return RemoteLookupResult(
            id: id,
            username: username,
            isVerified: userDict["isVerified"] as? Bool ?? false,
            noisePublicKey: userDict["noisePublicKey"] as? String,
            signingPublicKey: userDict["signingPublicKey"] as? String,
            avatarURL: userDict["avatarURL"] as? String,
            lastActiveAt: userDict["lastActiveAt"] as? String
        )
    }

    struct RemoteLookupResult: Sendable {
        let id: String
        let username: String
        let isVerified: Bool
        let noisePublicKey: String?
        let signingPublicKey: String?
        let avatarURL: String?
        let lastActiveAt: String?
    }

    // MARK: - Types

    struct ReceiptResult: Sendable {
        let valid: Bool
        let isVerified: Bool
        let credits: Int
    }

    struct ServerUser: Sendable {
        let id: String
        let username: String
        let isVerified: Bool
        let messageBalance: Int
        let lastActiveAt: String?
        let createdAt: String
    }

    // MARK: - Avatar Upload

    /// Upload avatar image to CDN via multipart/form-data.
    /// Returns the public URL of the uploaded avatar.
    func uploadAvatar(_ imageData: Data) async throws -> String {
        let cdnBaseURL = ServerConfig.cdnBaseURL

        guard let url = URL(string: "\(cdnBaseURL)/avatars/upload") else {
            throw SyncError.networkError("Invalid CDN URL")
        }

        let boundary = "Blip-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart body
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Authenticate
        request.setValue(try await authorizationHeaderValue(), forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await ServerConfig.pinnedSession.data(for: request)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError("Avatar upload failed: \(message)")
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.serverError("Invalid avatar upload response")
            }
            json = parsed
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.serverError("Invalid avatar upload response")
        }

        guard let avatarURL = json["url"] as? String, !avatarURL.isEmpty else {
            throw SyncError.serverError("Missing URL in avatar upload response")
        }

        return avatarURL
    }

    // MARK: - Device Token

    /// Registers an APNs device token with the backend so the server can send push notifications.
    func registerDeviceToken(_ token: String) async throws {
        let body: [String: Any] = ["token": token, "platform": "ios"]
        let (_, response) = try await post(path: "/devices/register", body: body, requiresAuth: true)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.serverError("Device token registration failed (\(status))")
        }
    }

    /// Unregisters an APNs device token from the backend (called on sign out).
    func unregisterDeviceToken(_ token: String) async throws {
        let body: [String: Any] = ["token": token]
        let (_, response) = try await post(path: "/devices/unregister", body: body, requiresAuth: true)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.serverError("Device token unregistration failed (\(status))")
        }
    }

    // MARK: - Private

    private func requestChallenge() async throws -> String {
        let (data, response) = try await post(path: "/auth/challenge", body: [:])

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let serverMessage = parseError(data) ?? String(data: data, encoding: .utf8) ?? "<no body>"
            DebugLogger.emit("AUTH", "Challenge request failed: HTTP \(httpResponse.statusCode) — \(serverMessage)", isError: true)
            throw SyncError.serverError("Challenge failed (\(httpResponse.statusCode)): \(serverMessage)")
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DebugLogger.emit("AUTH", "Challenge response was not a JSON object", isError: true)
                throw SyncError.badRequest("Invalid challenge response")
            }
            json = parsed
        } catch let error as SyncError {
            throw error
        } catch {
            DebugLogger.emit("AUTH", "Failed to decode challenge response: \(error.localizedDescription)", isError: true)
            throw SyncError.badRequest("Invalid challenge response")
        }

        guard let challenge = json["challenge"] as? String, !challenge.isEmpty else {
            DebugLogger.emit("AUTH", "Challenge response missing challenge field", isError: true)
            throw SyncError.badRequest("Invalid challenge response")
        }

        return challenge
    }

    private func signChallenge(_ challenge: String, secretKey: Data) throws -> String {
        let challengeBytes = try hexToBytes(challenge)
        let sodium = Sodium()

        guard let signature = sodium.sign.signature(
            message: Array(challengeBytes),
            secretKey: Array(secretKey)
        ) else {
            throw SyncError.serverError("Ed25519 signing failed")
        }

        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    private func hexToBytes(_ hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw SyncError.badRequest("Invalid challenge response")
        }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw SyncError.badRequest("Invalid challenge response")
            }
            data.append(byte)
            index = nextIndex
        }

        return data
    }

    private func post(path: String, body: [String: Any], requiresAuth: Bool = false) async throws -> (Data, URLResponse) {
        guard let url = URL(string: Self.baseURL + path) else {
            throw SyncError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw SyncError.networkError("Failed to encode request")
        }

        if requiresAuth {
            return try await performAuthenticatedRequest(request)
        }

        do {
            return try await ServerConfig.pinnedSession.data(for: request)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
    }

    private func get(path: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: Self.baseURL + path) else {
            throw SyncError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            return try await ServerConfig.pinnedSession.data(for: request)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }

    private func performAuthenticatedRequest(_ request: URLRequest, allowRetry: Bool = true) async throws -> (Data, URLResponse) {
        var authorizedRequest = request
        authorizedRequest.setValue(try await authorizationHeaderValue(), forHTTPHeaderField: "Authorization")

        do {
            let result = try await ServerConfig.pinnedSession.data(for: authorizedRequest)
            if allowRetry,
               let http = result.1 as? HTTPURLResponse,
               http.statusCode == 401 {
                try? await AuthTokenManager.shared.refreshIfNeeded(force: true)
                return try await performAuthenticatedRequest(request, allowRetry: false)
            }
            return result
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
    }

    private func authorizationHeaderValue() async throws -> String {
        guard let identity = try KeyManager.shared.loadIdentity() else {
            throw SyncError.unauthorized
        }

        do {
            return "Bearer \(try await authTokenProvider())"
        } catch {
            await DebugLogger.shared.log("AUTH", "Using legacy auth fallback for UserSyncService: \(error.localizedDescription)", isError: true)
            return "Bearer \(identity.noisePublicKey.rawRepresentation.base64EncodedString())"
        }
    }
}
