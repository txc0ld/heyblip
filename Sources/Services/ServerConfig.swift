import Foundation

enum ServerConfig {
    private static func infoPlistValue(for key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    static let authBaseURL: String = {
        infoPlistValue(for: "BLIP_AUTH_BASE_URL") ?? "https://blip-auth.john-mckean.workers.dev/v1"
    }()

    static let relayBaseURL: String = {
        infoPlistValue(for: "BLIP_RELAY_BASE_URL") ?? "https://blip-relay.john-mckean.workers.dev"
    }()

    static let cdnBaseURL: String = {
        infoPlistValue(for: "BLIP_CDN_BASE_URL") ?? "https://blip-cdn.john-mckean.workers.dev"
    }()

    static let relayWebSocketURL: URL = {
        let base = infoPlistValue(for: "BLIP_RELAY_BASE_URL") ?? "https://blip-relay.john-mckean.workers.dev"
        let wsBase = base.replacingOccurrences(of: "https://", with: "wss://")

        guard let url = URL(string: "\(wsBase)/ws") else {
            fatalError("Invalid relay WebSocket URL")
        }

        return url
    }()

    /// Current john-mckean.workers.dev leaf SPKI plus the GTS WE1 issuer backup pin.
    /// Refresh these when the Workers certificate chain rotates.
    static let pinnedCertHashes: Set<String> = [
        "65322daf5b6f90003fcea47d9389234b26435ac1a519b7d7da02de3e9cf07a2f",
        "908769e8d34477cc2cba0632c88605b22d7294c0840f78596d247c645b1afc0e"
    ]

    static let pinnedDomains: Set<String> = [
        "blip-auth.john-mckean.workers.dev",
        "blip-relay.john-mckean.workers.dev",
        "blip-cdn.john-mckean.workers.dev"
    ]

    static let pinnedSession: URLSession = {
        let delegate = CertificatePinningDelegate(
            pinnedHashes: pinnedCertHashes,
            pinnedDomains: pinnedDomains
        )
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    static let eventsManifestURL: String = {
        "\(cdnBaseURL)/manifests/events.json"
    }()
}
