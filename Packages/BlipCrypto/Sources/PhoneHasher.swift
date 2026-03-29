import Foundation
import CryptoKit

// MARK: - PhoneHasher

/// Computes privacy-preserving phone number hashes for contact discovery.
///
/// Per spec Section 7.4:
/// ```
/// SHA256(phone_number_e164 + per_user_salt)
/// ```
///
/// Each user has a unique 32-byte random salt generated on first launch and
/// stored in the Keychain. Salts are exchanged inside Noise-encrypted friend
/// request payloads so each user's hash is unique even for the same phone number,
/// preventing precomputed rainbow table attacks.
public enum PhoneHasher {

    /// Length of the per-user salt in bytes.
    public static let saltLength = 32

    /// Length of the resulting hash in bytes (SHA-256 output).
    public static let hashLength = 32

    // MARK: - Hashing

    /// Compute the salted hash of a phone number.
    ///
    /// - Parameters:
    ///   - phone: The phone number in E.164 format (e.g., "+14155551234").
    ///   - salt: The 32-byte per-user random salt.
    /// - Returns: 32-byte SHA-256 hash.
    public static func hash(phone: String, salt: Data) -> Data {
        var input = Data(phone.utf8)
        input.append(salt)
        let digest = SHA256.hash(data: input)
        return Data(digest)
    }

    // MARK: - Salt generation

    /// Generate a cryptographically secure 32-byte random salt.
    ///
    /// Uses `SecRandomCopyBytes` (iOS CSPRNG) for generation.
    public static func generateSalt() -> Data {
        var bytes = Data(count: saltLength)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr)
        }
        return bytes
    }

    // MARK: - Verification

    /// Verify that a phone hash matches a given phone number and salt.
    ///
    /// Used during mutual friend verification: both sides compute
    /// `SHA256(their_phone + friend's_salt)` and compare.
    ///
    /// - Parameters:
    ///   - phone: The phone number in E.164 format.
    ///   - salt: The salt provided by the other party.
    ///   - expectedHash: The hash to verify against.
    /// - Returns: `true` if the computed hash matches.
    public static func verify(phone: String, salt: Data, expectedHash: Data) -> Bool {
        let computed = hash(phone: phone, salt: salt)
        // Constant-time comparison to prevent timing attacks
        guard computed.count == expectedHash.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(computed, expectedHash) {
            result |= a ^ b
        }
        return result == 0
    }
}
