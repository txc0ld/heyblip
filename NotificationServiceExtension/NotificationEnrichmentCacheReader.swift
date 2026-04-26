import Foundation

/// Reader half of the App Group enrichment cache used by the NSE.
///
/// The WRITER half lives in `Sources/Services/NotificationEnrichmentCache.swift`
/// (main-app target) and is maintained whenever friends/channels change. The
/// NSE must NOT depend on the app target, so we duplicate the `Codable` model
/// here verbatim. The field layout MUST stay in lockstep with the writer —
/// a mismatch breaks enrichment silently (decode fails → generic copy).
///
/// Cache path: `<App Group container>/NotificationEnrichmentCache.json`
/// App Group: `group.com.heyblip.shared` (shared across Debug + Release builds)
///
/// On any failure (missing entitlement, missing file, corrupt JSON) this
/// returns `nil` and the NSE falls back to the payload's `senderUsername`
/// (or "Someone" / "New message" if that's also absent).
struct NotificationEnrichmentCache: Codable, Sendable {
    struct Friend: Codable, Sendable {
        let peerIdHex: String
        let displayName: String
        let avatarURL: String?
    }
    struct Channel: Codable, Sendable {
        let id: UUID
        let name: String
        let kind: String
    }
    var friends: [String: Friend]
    var channels: [String: Channel]
    var updatedAt: Date
}

enum NotificationEnrichmentCacheReader {
    static let appGroupIdentifier = "group.com.heyblip.shared"
    static let fileName = "NotificationEnrichmentCache.json"

    /// Loads the enrichment cache from the shared App Group container.
    ///
    /// This is the ONLY place in the NSE code where bare `try?` is acceptable.
    /// The NSE runs in the system user-notification daemon and must never
    /// throw or crash on a missing/corrupt cache: any read error degrades
    /// gracefully to `nil`, and the caller falls back to generic copy.
    static func load() -> NotificationEnrichmentCache? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let url = container.appendingPathComponent(fileName)
        // Intentional bare `try?` — see doc comment above. No crash allowed in NSE.
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Intentional bare `try?` — a corrupt or schema-mismatched cache must
        // not take down the extension; we prefer generic copy to silence.
        return try? decoder.decode(NotificationEnrichmentCache.self, from: data)
    }
}
