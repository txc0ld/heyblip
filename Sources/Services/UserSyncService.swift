import Foundation
import os.log

/// Handles user registration, profile sync, and receipt verification
/// with the Blip backend API.
///
/// All calls are gated on connectivity — callers should check transport mode
/// before invoking (skip if BLE-only mode).
final class UserSyncService: Sendable {

    // MARK: - Configuration

    private static let baseURL = "https://blip-auth.john-mckean.workers.dev/v1"

    private let logger = Logger(subsystem: "com.blip", category: "UserSync")

    // MARK: - Errors

    enum SyncError: LocalizedError, Sendable {
        case networkError(String)
        case serverError(String)
        case usernameTaken
        case userNotFound
        case databaseNotConfigured

        var errorDescription: String? {
            switch self {
            case .networkError(let detail):
                return "Network error: \(detail)"
            case .serverError(let detail):
                return "Server error: \(detail)"
            case .usernameTaken:
                return "Username is already taken."
            case .userNotFound:
                return "User not found on server."
            case .databaseNotConfigured:
                return "Backend database is not yet configured."
            }
        }
    }

    // MARK: - Register User

    /// Register a new user after onboarding completes.
    /// Fire-and-forget — failures are logged but don't block the user.
    func registerUser(
        emailHash: String,
        username: String,
        noisePublicKey: Data? = nil,
        signingPublicKey: Data? = nil
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

        let (data, response) = try await post(path: "/users/register", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 201:
            logger.info("User registered: \(username, privacy: .private)")
        case 409:
            throw SyncError.usernameTaken
        case 503:
            throw SyncError.databaseNotConfigured
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }
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

        let (data, response) = try await post(path: "/users/sync", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            logger.info("Profile synced for \(emailHash.prefix(8), privacy: .private)...")
        case 404:
            throw SyncError.userNotFound
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

        let (data, response) = try await URLSession.shared.data(for: request)

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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid response")
        }

        if http.statusCode == 404 { return nil }

        guard http.statusCode == 200 else {
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw SyncError.serverError(message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userDict = json["user"] as? [String: Any] else {
            throw SyncError.serverError("Invalid response body")
        }

        return RemoteLookupResult(
            id: userDict["id"] as? String ?? "",
            username: userDict["username"] as? String ?? "",
            isVerified: userDict["isVerified"] as? Bool ?? false,
            noisePublicKey: userDict["noisePublicKey"] as? String,
            signingPublicKey: userDict["signingPublicKey"] as? String,
            lastActiveAt: userDict["lastActiveAt"] as? String
        )
    }

    struct RemoteLookupResult: Sendable {
        let id: String
        let username: String
        let isVerified: Bool
        let noisePublicKey: String?
        let signingPublicKey: String?
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

    // MARK: - Private

    private func post(path: String, body: [String: Any]) async throws -> (Data, URLResponse) {
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

        do {
            return try await URLSession.shared.data(for: request)
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
            return try await URLSession.shared.data(for: request)
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
}
