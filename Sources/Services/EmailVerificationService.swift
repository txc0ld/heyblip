import Foundation
import os.log

/// Handles email verification against the FestiChat auth API.
///
/// Sends a 6-digit code via Resend and verifies it.
/// All errors are surfaced as ``EmailVerificationError``.
final class EmailVerificationService: Sendable {

    // MARK: - Configuration

    private static let baseURL = "https://api.festichat.app/v1/auth"

    private let logger = Logger(subsystem: "com.festichat", category: "EmailVerification")

    // MARK: - Errors

    enum EmailVerificationError: LocalizedError, Sendable {
        case invalidEmail
        case networkError(String)
        case rateLimited
        case codeExpired
        case incorrectCode
        case tooManyAttempts
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidEmail:
                return "Please enter a valid email address."
            case .networkError(let detail):
                return "Network error: \(detail)"
            case .rateLimited:
                return "Too many requests. Please try again later."
            case .codeExpired:
                return "Code expired. Please request a new one."
            case .incorrectCode:
                return "Incorrect code. Please try again."
            case .tooManyAttempts:
                return "Too many attempts. Please request a new code."
            case .serverError(let detail):
                return "Server error: \(detail)"
            }
        }
    }

    // MARK: - Send Code

    /// Request a verification code be sent to the given email.
    func sendCode(to email: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard isValidEmail(trimmed) else {
            throw EmailVerificationError.invalidEmail
        }

        let body = ["email": trimmed]
        let (data, response) = try await post(path: "/send-code", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw EmailVerificationError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            logger.info("Verification code sent to \(trimmed)")
        case 429:
            throw EmailVerificationError.rateLimited
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw EmailVerificationError.serverError(message)
        }
    }

    // MARK: - Verify Code

    /// Verify a 6-digit code for the given email. Returns on success, throws on failure.
    func verifyCode(email: String, code: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = ["email": trimmed, "code": code.trimmingCharacters(in: .whitespaces)]

        let (data, response) = try await post(path: "/verify-code", body: body)

        guard let http = response as? HTTPURLResponse else {
            throw EmailVerificationError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            logger.info("Email verified: \(trimmed)")
        case 401:
            throw EmailVerificationError.incorrectCode
        case 410:
            throw EmailVerificationError.codeExpired
        case 429:
            throw EmailVerificationError.tooManyAttempts
        default:
            let message = parseError(data) ?? "Status \(http.statusCode)"
            throw EmailVerificationError.serverError(message)
        }
    }

    // MARK: - Private

    private func post(path: String, body: [String: String]) async throws -> (Data, URLResponse) {
        guard let url = URL(string: Self.baseURL + path) else {
            throw EmailVerificationError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw EmailVerificationError.networkError("Failed to encode request")
        }

        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw EmailVerificationError.networkError(error.localizedDescription)
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }
}
