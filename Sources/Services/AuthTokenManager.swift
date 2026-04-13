import Foundation
import Combine
import Security
@preconcurrency import Sodium
import BlipCrypto

@MainActor
final class AuthTokenManager: ObservableObject {
    static let shared = AuthTokenManager()

    @Published private(set) var currentToken: String?
    @Published private(set) var tokenExpiresAt: Date?

    private let keychainTokenKey = "blip.auth.jwt"
    private let keychainExpiryKey = "blip.auth.jwt.expiry"
    private let refreshThreshold: TimeInterval = 300
    private let keyManager: KeyManager
    private let sodium: Sodium
    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct TokenResponse: Decodable {
        let token: String
        let expiresAt: String
    }

    private enum AuthError: LocalizedError {
        case invalidURL
        case signingFailed
        case invalidResponse
        case invalidPayload
        case missingIdentity
        case missingToken
        case unauthorized(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid auth endpoint URL"
            case .signingFailed:
                return "Failed to sign auth challenge"
            case .invalidResponse:
                return "Invalid auth server response"
            case .invalidPayload:
                return "Invalid auth payload"
            case .missingIdentity:
                return "Local identity not available"
            case .missingToken:
                return "No auth token available"
            case .unauthorized(let detail):
                return detail
            case .serverError(let detail):
                return detail
            }
        }
    }

    init(keyManager: KeyManager = .shared, sodium: Sodium = Sodium()) {
        self.keyManager = keyManager
        self.sodium = sodium
        loadStoredToken()
    }

    func authenticate(noisePublicKey: Data, signingSecretKey: Data) async throws {
        let timestamp = iso8601Formatter.string(from: Date())
        let signature: Data

        do {
            signature = try signTimestamp(timestamp, signingSecretKey: signingSecretKey)
        } catch {
            DebugLogger.shared.log("AUTH", "JWT authenticate signing failed: \(error.localizedDescription)", isError: true)
            throw error
        }

        guard let url = URL(string: ServerConfig.authBaseURL + "/auth/token") else {
            DebugLogger.shared.log("AUTH", "JWT authenticate failed: invalid token endpoint URL", isError: true)
            throw AuthError.invalidURL
        }

        let body: [String: String] = [
            "noisePublicKey": noisePublicKey.base64EncodedString(),
            "timestamp": timestamp,
            "signature": signature.base64EncodedString(),
        ]

        do {
            let response = try await sendRequest(url: url, body: body, bearerToken: nil)
            try store(token: response.token, expiresAtString: response.expiresAt)
            DebugLogger.shared.log("AUTH", "JWT session established")
        } catch {
            DebugLogger.shared.log("AUTH", "JWT authenticate failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    func refreshIfNeeded(force: Bool = false) async throws {
        if force {
            if currentToken != nil {
                try await refreshToken()
                return
            }

            guard let identity = try keyManager.loadIdentity() else {
                throw AuthError.missingIdentity
            }

            try await authenticate(
                noisePublicKey: identity.noisePublicKey.rawRepresentation,
                signingSecretKey: identity.signingSecretKey
            )
            return
        }

        guard let expiry = tokenExpiresAt else {
            if currentToken == nil {
                return
            }
            throw AuthError.invalidPayload
        }

        guard expiry.timeIntervalSinceNow < refreshThreshold else {
            return
        }

        try await refreshToken()
    }

    func validToken() async throws -> String {
        if let token = currentToken, let expiry = tokenExpiresAt, expiry.timeIntervalSinceNow > refreshThreshold {
            return token
        }

        if currentToken != nil {
            do {
                try await refreshIfNeeded()
            } catch {
                DebugLogger.shared.log("AUTH", "JWT refresh before use failed: \(error.localizedDescription)", isError: true)
                clearToken()
            }
        }

        if let token = currentToken, let expiry = tokenExpiresAt, expiry.timeIntervalSinceNow > 0 {
            return token
        }

        guard let identity = try keyManager.loadIdentity() else {
            DebugLogger.shared.log("AUTH", "JWT token unavailable: no local identity", isError: true)
            throw AuthError.missingIdentity
        }

        try await authenticate(
            noisePublicKey: identity.noisePublicKey.rawRepresentation,
            signingSecretKey: identity.signingSecretKey
        )

        guard let token = currentToken else {
            DebugLogger.shared.log("AUTH", "JWT token unavailable after authenticate", isError: true)
            throw AuthError.missingToken
        }

        return token
    }

    func clearToken() {
        do {
            try deleteKeychainValue(for: keychainTokenKey)
            try deleteKeychainValue(for: keychainExpiryKey)
        } catch {
            DebugLogger.shared.log("AUTH", "JWT clear token failed: \(error.localizedDescription)", isError: true)
        }

        currentToken = nil
        tokenExpiresAt = nil
    }

    func clear() throws {
        try deleteKeychainValue(for: keychainTokenKey)
        try deleteKeychainValue(for: keychainExpiryKey)
        currentToken = nil
        tokenExpiresAt = nil
    }

    private func refreshToken() async throws {
        guard let token = currentToken else {
            throw AuthError.missingToken
        }

        guard let url = URL(string: ServerConfig.authBaseURL + "/auth/refresh") else {
            throw AuthError.invalidURL
        }

        do {
            let response = try await sendRequest(url: url, body: nil, bearerToken: token)
            try store(token: response.token, expiresAtString: response.expiresAt)
            DebugLogger.shared.log("AUTH", "JWT session refreshed")
        } catch {
            DebugLogger.shared.log("AUTH", "JWT refresh failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    private func sendRequest(
        url: URL,
        body: [String: String]?,
        bearerToken: String?
    ) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw AuthError.invalidPayload
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ServerConfig.pinnedSession.data(for: request)
        } catch {
            throw AuthError.serverError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = parseErrorMessage(from: data) ?? "Status \(http.statusCode)"
            if http.statusCode == 401 {
                throw AuthError.unauthorized(detail)
            }
            throw AuthError.serverError(detail)
        }

        let decoder = JSONDecoder()
        guard let tokenResponse = try? decoder.decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidResponse
        }

        return tokenResponse
    }

    private func signTimestamp(_ timestamp: String, signingSecretKey: Data) throws -> Data {
        guard let signature = sodium.sign.signature(
            message: Array(timestamp.utf8),
            secretKey: Array(signingSecretKey)
        ) else {
            throw AuthError.signingFailed
        }

        return Data(signature)
    }

    private func store(token: String, expiresAtString: String) throws {
        guard let expiry = iso8601Formatter.date(from: expiresAtString) else {
            throw AuthError.invalidResponse
        }

        do {
            try storeKeychainValue(Data(token.utf8), for: keychainTokenKey)
            try storeKeychainValue(Data(expiresAtString.utf8), for: keychainExpiryKey)
        } catch {
            DebugLogger.shared.log("AUTH", "JWT keychain store failed: \(error.localizedDescription)", isError: true)
            throw error
        }

        currentToken = token
        tokenExpiresAt = expiry
    }

    private func loadStoredToken() {
        do {
            guard
                let tokenData = try loadKeychainValue(for: keychainTokenKey),
                let expiryData = try loadKeychainValue(for: keychainExpiryKey),
                let token = String(data: tokenData, encoding: .utf8),
                let expiryString = String(data: expiryData, encoding: .utf8),
                let expiry = iso8601Formatter.date(from: expiryString)
            else {
                currentToken = nil
                tokenExpiresAt = nil
                return
            }

            currentToken = token
            tokenExpiresAt = expiry
        } catch {
            DebugLogger.shared.log("AUTH", "JWT keychain load failed: \(error.localizedDescription)", isError: true)
            currentToken = nil
            tokenExpiresAt = nil
        }
    }

    private func keychainQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
        ]
    }

    private func storeKeychainValue(_ value: Data, for key: String) throws {
        SecItemDelete(keychainQuery(for: key) as CFDictionary)

        var query = keychainQuery(for: key)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func loadKeychainValue(for key: String) throws -> Data? {
        var query = keychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return data
    }

    private func deleteKeychainValue(for key: String) throws {
        let status = SecItemDelete(keychainQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = object["error"] as? String {
            return error
        }
        if let detail = object["detail"] as? String {
            return detail
        }

        return nil
    }
}
