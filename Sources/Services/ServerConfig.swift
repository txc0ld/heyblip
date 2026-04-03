import Foundation

/// Central configuration for all Blip server endpoints.
///
/// All server URLs should reference this config instead of hardcoding domains.
/// This makes it easy to switch between environments (dev, staging, production).
enum ServerConfig {

    /// Base URL for the auth/user API (Cloudflare Worker).
    static let authBaseURL = "https://blip-auth.john-mckean.workers.dev/v1"

    /// Base URL for the relay server (WebSocket + state sync).
    static let relayBaseURL = "https://blip-relay.john-mckean.workers.dev"

    /// WebSocket relay endpoint.
    static let relayWebSocketURL = URL(string: "wss://blip-relay.john-mckean.workers.dev/ws")!

    /// Events manifest CDN URL.
    static let eventsManifestURL = "https://cdn.blip.app/manifests/events.json"
}
