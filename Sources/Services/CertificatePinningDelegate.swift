import CryptoKit
import Foundation
import Security

private enum CertificatePinning {
    private static let rsaAlgorithmIdentifier = Data([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00
    ])

    private static let ecP256AlgorithmIdentifier = Data([
        0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07
    ])

    private static let ecP384AlgorithmIdentifier = Data([
        0x30, 0x10,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22
    ])

    private static let ecP521AlgorithmIdentifier = Data([
        0x30, 0x10,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23
    ])

    static func hashString(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let publicKey = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let subjectPublicKeyInfo = subjectPublicKeyInfo(for: key, publicKey: publicKey) else {
            return nil
        }

        let digest = SHA256.hash(data: subjectPublicKeyInfo)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func subjectPublicKeyInfo(for key: SecKey, publicKey: Data) -> Data? {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String else {
            return nil
        }

        let keySizeInBits = attributes[kSecAttrKeySizeInBits] as? Int ?? (publicKey.count * 8)

        let algorithmIdentifier: Data
        if keyType == (kSecAttrKeyTypeRSA as String) {
            algorithmIdentifier = rsaAlgorithmIdentifier
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            switch keySizeInBits {
            case 256:
                algorithmIdentifier = ecP256AlgorithmIdentifier
            case 384:
                algorithmIdentifier = ecP384AlgorithmIdentifier
            case 521:
                algorithmIdentifier = ecP521AlgorithmIdentifier
            default:
                return nil
            }
        } else {
            return nil
        }
        return derSequence([algorithmIdentifier, derBitString(publicKey)])
    }

    private static func derSequence(_ components: [Data]) -> Data {
        let payload = components.reduce(into: Data()) { result, component in
            result.append(component)
        }
        return derTagged(0x30, payload)
    }

    private static func derBitString(_ data: Data) -> Data {
        var payload = Data([0x00])
        payload.append(data)
        return derTagged(0x03, payload)
    }

    private static func derTagged(_ tag: UInt8, _ payload: Data) -> Data {
        var data = Data([tag])
        data.append(derLength(payload.count))
        data.append(payload)
        return data
    }

    private static func derLength(_ length: Int) -> Data {
        guard length >= 0 else { return Data() }

        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }

        var data = Data([0x80 | UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        return data
    }
}

final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let pinnedHashes: Set<String>
    private let pinnedDomains: Set<String>

    init(pinnedHashes: Set<String>, pinnedDomains: Set<String>) {
        self.pinnedHashes = pinnedHashes
        self.pinnedDomains = pinnedDomains
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              pinnedDomains.contains(challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            DebugLogger.emit(
                "AUTH",
                "TLS trust evaluation failed for \(challenge.protectionSpace.host): \(error?.localizedDescription ?? "unknown")",
                isError: true,
                level: .error
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        for certificate in certificates {
            guard let hash = CertificatePinning.hashString(for: certificate) else {
                continue
            }

            if pinnedHashes.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        DebugLogger.emit(
            "AUTH",
            "Certificate pinning failed for \(challenge.protectionSpace.host)",
            isError: true,
            level: .error
        )
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
