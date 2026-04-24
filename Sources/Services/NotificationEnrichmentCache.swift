import Foundation

// MARK: - App Group container path

/// App Group identifier shared between the main app and the Notification
/// Service Extension.
let blipAppGroupIdentifier = "group.com.heyblip.shared"

/// Filename for the shared enrichment cache inside the App Group container.
private let enrichmentCacheFileName = "NotificationEnrichmentCache.json"

// MARK: - Cache schema

/// Snapshot of the data the Notification Service Extension needs to render
/// a rich push notification: friends (for display name + avatar) and
/// channels (for title + kind-specific sound/category).
///
/// The main app is the only writer. The NSE is a read-only consumer. We
/// accept eventual consistency between devices — the server payload itself
/// carries enough data for a minimally useful notification if this cache
/// is stale or missing.
struct NotificationEnrichmentCache: Codable, Sendable {

    struct Friend: Codable, Sendable {
        let peerIdHex: String
        let displayName: String
        let avatarURL: String?
    }

    struct Channel: Codable, Sendable {
        let id: UUID
        let name: String
        /// "dm" | "group" | "stage" | "locationChannel" | "lostAndFound" | "emergency"
        let kind: String
    }

    var friends: [String: Friend]
    var channels: [String: Channel]
    var updatedAt: Date

    static let empty = NotificationEnrichmentCache(
        friends: [:],
        channels: [:],
        updatedAt: .distantPast
    )
}

// MARK: - Shared helpers

private enum NotificationEnrichmentCacheStorage {

    static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: blipAppGroupIdentifier
        )
    }

    static func fileURL() -> URL? {
        containerURL()?.appendingPathComponent(enrichmentCacheFileName, isDirectory: false)
    }

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}

// MARK: - Reader (NSE-side)

/// Read-only view used by the Notification Service Extension. Returns nil
/// when the file is missing or corrupt; callers must fall back to payload
/// content in that case.
struct NotificationEnrichmentCacheReader {

    static func load() -> NotificationEnrichmentCache? {
        guard let url = NotificationEnrichmentCacheStorage.fileURL() else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try NotificationEnrichmentCacheStorage.decoder.decode(
                NotificationEnrichmentCache.self,
                from: data
            )
        } catch {
            // NSE intentionally does NOT emit via DebugLogger or Sentry here —
            // the extension has a tight memory budget and a missing cache is
            // expected on first launch.
            return nil
        }
    }
}

// MARK: - Writer (main-app-side)

/// Serialised writer used by the main app. Single-process writers make
/// an actor + atomic replace sufficient; we don't need NSFileCoordinator.
actor NotificationEnrichmentCacheWriter {

    static let shared = NotificationEnrichmentCacheWriter()

    private var cache: NotificationEnrichmentCache

    private init() {
        // Hydrate from disk so the first write after launch is incremental,
        // not wholesale. A missing/corrupt file resets to empty.
        self.cache = NotificationEnrichmentCacheReader.load() ?? .empty
    }

    // MARK: Mutations

    func upsertFriend(_ friend: NotificationEnrichmentCache.Friend) async {
        cache.friends[friend.peerIdHex] = friend
        cache.updatedAt = Date()
        await persist()
    }

    func upsertChannel(_ channel: NotificationEnrichmentCache.Channel) async {
        cache.channels[channel.id.uuidString] = channel
        cache.updatedAt = Date()
        await persist()
    }

    func removeFriend(peerIdHex: String) async {
        guard cache.friends.removeValue(forKey: peerIdHex) != nil else { return }
        cache.updatedAt = Date()
        await persist()
    }

    func removeChannel(id: UUID) async {
        guard cache.channels.removeValue(forKey: id.uuidString) != nil else { return }
        cache.updatedAt = Date()
        await persist()
    }

    func snapshot() async -> NotificationEnrichmentCache {
        cache
    }

    // MARK: Persistence

    private func persist() async {
        guard let target = NotificationEnrichmentCacheStorage.fileURL() else {
            DebugLogger.emit(
                "PUSH",
                "Enrichment cache skipped — App Group container unavailable",
                isError: true
            )
            return
        }

        do {
            let data = try NotificationEnrichmentCacheStorage.encoder.encode(cache)

            // Write to temp file in the same container, then atomic replace.
            let tempURL = target.deletingLastPathComponent()
                .appendingPathComponent(
                    "NotificationEnrichmentCache.\(UUID().uuidString).tmp",
                    isDirectory: false
                )
            try data.write(to: tempURL, options: [.atomic])

            let fm = FileManager.default
            do {
                _ = try fm.replaceItemAt(target, withItemAt: tempURL)
            } catch {
                // First write — destination doesn't exist yet. Just move.
                if !fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: tempURL, to: target)
                } else {
                    throw error
                }
            }
        } catch {
            DebugLogger.emit(
                "PUSH",
                "Enrichment cache persist failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
