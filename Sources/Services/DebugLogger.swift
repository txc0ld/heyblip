import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - LogLevel

enum LogLevel: Int, Comparable, Sendable {
    case verbose = 0  // RSSI, packet hex dumps, timer ticks
    case debug = 1    // Connection state changes, peer discovery
    case info = 2     // Message sent/received, handshake complete
    case warning = 3  // Retry, timeout, fallback
    case error = 4    // Failures

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Centralized debug logger for the BLE Debug Overlay.
///
/// Stores recent log entries in-memory for real-time display. Used by
/// MessageService, AppCoordinator, and MeshRelayService to surface
/// protocol events in the debug UI without requiring Xcode console access.
@MainActor @Observable
final class DebugLogger {
    static let shared = DebugLogger()

    nonisolated static func redact(_ value: String) -> String {
        #if DEBUG
        return value
        #else
        guard value.count > 2 else { return "***" }
        return String(value.prefix(2)) + "***"
        #endif
    }

    nonisolated static func redactHex(_ value: String) -> String {
        #if DEBUG
        return value
        #else
        guard value.count > 4 else { return "****" }
        return String(value.prefix(4)) + "..."
        #endif
    }

    struct Entry: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let category: String
        let message: String
        let isError: Bool

        init(
            category: String,
            message: String,
            isError: Bool,
            id: UUID = UUID(),
            timestamp: Date = Date()
        ) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.message = message
            self.isError = isError
        }

        var formattedTime: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: timestamp)
        }
    }

    /// Unique session ID to correlate logs across devices.
    nonisolated let sessionID = UUID()

    /// Generate a per-request trace identifier of the form
    /// `<sessionID>-<8-hex-nonce>`. Suitable for the `X-Trace-ID` HTTP header
    /// so a single request can be stitched across the iOS client, Cloudflare
    /// Workers (wrangler tail), and Sentry. (BDEV-403)
    nonisolated func nextTraceID() -> String {
        let nonce = String(format: "%08x", UInt32.random(in: .min ... .max))
        return "\(sessionID.uuidString.lowercased())-\(nonce)"
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 500

    // MARK: - Persistent rolling buffer (BDEV-402)

    /// Rolls hourly JSONL files (one per UTC hour) into the App Group container,
    /// retains 24h worth, and replays the most recent file into `entries` on init
    /// so a force-quit / crash doesn't wipe the post-mortem context.
    nonisolated private static let appGroupID = blipAppGroupIdentifier
    nonisolated private static let logsSubdirectory = "logs"
    nonisolated private static let fileWriterQueue = DispatchQueue(
        label: "com.blip.DebugLogger.fileWriter",
        qos: .utility
    )
    nonisolated private static let logRetentionInterval: TimeInterval = 24 * 3600

    /// Persisted on-disk row format. JSON-encoded one per line in the hourly file.
    private struct PersistedEntry: Codable {
        let ts: String          // ISO8601 with fractional seconds
        let sessionID: String
        let category: String
        let message: String
        let isError: Bool
    }

    nonisolated(unsafe) private static let persistDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static let hourlyFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated private static func logsDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(logsSubdirectory, isDirectory: true)
    }

    nonisolated private static func filename(for date: Date) -> String {
        "debug-\(hourlyFilenameFormatter.string(from: date)).jsonl"
    }

    /// Minimum log level — messages below this are silently dropped.
    #if DEBUG
    var minimumLevel: LogLevel = .debug
    #else
    var minimumLevel: LogLevel = .info
    #endif

    /// Deduplication window — identical category+message within this interval is suppressed.
    private let dedupWindow: TimeInterval = 0.5
    private var recentLogTimes: [String: Date] = [:]
    private let maxDedupEntries = 20
    private let dedupLock = NSLock()

    private init() {
        Self.bootstrapPersistentBuffer { [weak self] historicalEntries in
            // Replay happens off the file queue; hop back to MainActor to mutate
            // `entries`. Force-quit between the two callbacks just means the
            // overlay loads empty and the disk file is still there.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !historicalEntries.isEmpty else { return }
                let merged = (historicalEntries + self.entries).prefix(self.maxEntries)
                self.entries = Array(merged)
            }
        }
    }

    /// On-disk bootstrap: ensure the logs dir exists, prune files older than the
    /// retention window, and read the most recent file back into memory.
    /// Errors are swallowed — disk failure must NEVER crash logging.
    nonisolated private static func bootstrapPersistentBuffer(
        replay: @escaping @Sendable ([Entry]) -> Void
    ) {
        fileWriterQueue.async {
            guard let dir = logsDirectory() else {
                replay([])
                return
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                replay([])
                return
            }
            let cutoff = Date().addingTimeInterval(-logRetentionInterval)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let logFiles = urls.filter {
                $0.lastPathComponent.hasPrefix("debug-")
                && $0.lastPathComponent.hasSuffix(".jsonl")
            }
            for url in logFiles {
                let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
                if let created = attrs?.creationDate, created < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            // Replay most recent surviving file.
            let surviving = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard let recent = surviving
                .filter({ $0.hasPrefix("debug-") && $0.hasSuffix(".jsonl") })
                .sorted()
                .last else {
                replay([])
                return
            }
            let url = dir.appendingPathComponent(recent)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                replay([])
                return
            }
            let decoder = JSONDecoder()
            var loaded: [Entry] = []
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let p = try? decoder.decode(PersistedEntry.self, from: lineData) else { continue }
                let ts = persistDateFormatter.date(from: p.ts) ?? Date()
                loaded.append(Entry(
                    category: p.category,
                    message: p.message,
                    isError: p.isError,
                    timestamp: ts
                ))
            }
            // Newest-first to match in-memory buffer ordering.
            replay(loaded.reversed())
        }
    }

    /// Append one persisted row to the current hour's file. Best-effort — disk
    /// failures fall back to in-memory only and are silently dropped.
    nonisolated private static func persist(_ entry: Entry, sessionID: UUID) {
        fileWriterQueue.async {
            guard let dir = logsDirectory() else { return }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return
            }
            let url = dir.appendingPathComponent(filename(for: entry.timestamp))
            let row = PersistedEntry(
                ts: persistDateFormatter.string(from: entry.timestamp),
                sessionID: sessionID.uuidString,
                category: entry.category,
                message: entry.message,
                isError: entry.isError
            )
            guard var data = try? JSONEncoder().encode(row) else { return }
            data.append(UInt8(ascii: "\n"))
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } catch {
                        // Disk full / permission lost mid-session — drop quietly.
                    }
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func log(_ category: String, _ message: String, isError: Bool = false, level: LogLevel? = nil) {
        let resolvedLevel = level ?? (isError ? .error : .info)
        guard resolvedLevel >= minimumLevel else { return }

        // Deduplicate: skip if same category+message was logged within the dedup window.
        // Lock protects recentLogTimes from concurrent access via emit().
        let isDuplicate: Bool = dedupLock.withLock {
            let key = "\(category):\(message)"
            let now = Date()

            // Evict stale dedup entries
            if recentLogTimes.count > maxDedupEntries {
                recentLogTimes = recentLogTimes.filter { now.timeIntervalSince($0.value) < dedupWindow }
            }

            if let lastTime = recentLogTimes[key], now.timeIntervalSince(lastTime) < dedupWindow {
                return true
            }
            recentLogTimes[key] = now
            return false
        }
        if isDuplicate { return }

        let entry = Entry(category: category, message: message, isError: isError)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast() }
        print("[Blip-\(category)] \(message)")

        // Persist to the rolling 24h on-disk buffer (BDEV-402). Off-main-thread,
        // best-effort — disk failures must not crash the logger.
        Self.persist(entry, sessionID: sessionID)

        // Always add a breadcrumb so non-error logs surface as crash context.
        CrashReportingService.shared.addBreadcrumb(
            category: category,
            message: message,
            level: isError ? .error : .info
        )

        // Promote errors to a searchable Sentry issue. Without this, error-level
        // breadcrumbs only appear inside an enclosing Sentry event — handled
        // failures (network, decode, queue) never surface in the dashboard.
        if isError {
            CrashReportingService.shared.captureMessage("[\(category)] \(message)", level: .error)
        }
    }

    /// Convenience for verbose-level logs (RSSI, raw bytes, timer ticks).
    func verbose(_ category: String, _ message: String) {
        log(category, message, level: .verbose)
    }

    func clear() {
        entries.removeAll()
    }

    /// Load every persisted entry from the 24h on-disk window, oldest-first,
    /// and return them as a single newline-joined export string. Format matches
    /// `exportText` so the share sheet behaves identically. (BDEV-402)
    nonisolated func loadPersistedHistory() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            Self.fileWriterQueue.async {
                continuation.resume(returning: Self.assemblePersistedHistoryText())
            }
        }
    }

    nonisolated private static func assemblePersistedHistoryText() -> String {
        guard let dir = logsDirectory() else { return "(persistent log dir unavailable)" }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let logFiles = names
            .filter { $0.hasPrefix("debug-") && $0.hasSuffix(".jsonl") }
            .sorted()
        guard !logFiles.isEmpty else { return "(no persisted history yet)" }

        let decoder = JSONDecoder()
        var lines: [String] = []
        lines.append("=== Blip Persistent Log (24h) ===")
        lines.append("Files: \(logFiles.count)")
        lines.append("=================================")
        lines.append("")
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        timeFormatter.timeZone = TimeZone(identifier: "UTC")

        for name in logFiles {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            lines.append("--- \(name) ---")
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let row = try? decoder.decode(PersistedEntry.self, from: lineData) else { continue }
                let ts = persistDateFormatter.date(from: row.ts)
                    .map { timeFormatter.string(from: $0) } ?? row.ts
                let prefix = row.isError ? "[ERR]" : "     "
                lines.append("\(prefix) [\(ts)] [\(row.category)] \(row.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Thread-safe logging entry point for non-MainActor contexts.
    /// Dispatches to the main actor asynchronously.
    nonisolated static func emit(
        _ category: String,
        _ message: String,
        isError: Bool = false,
        level: LogLevel? = nil
    ) {
        Task { @MainActor in
            shared.log(category, message, isError: isError, level: level)
        }
    }

    /// All entries formatted for clipboard export, with a header block.
    var exportText: String {
        let deviceName: String
        #if canImport(UIKit)
        deviceName = UIDevice.current.name
        #else
        deviceName = Host.current().localizedName ?? "Mac"
        #endif

        let iso8601 = ISO8601DateFormatter()
        let now = iso8601.string(from: Date())

        var lines: [String] = []
        lines.append("=== Blip Debug Log ===")
        lines.append("Session: \(sessionID.uuidString)")
        lines.append("Device: \(deviceName)")
        lines.append("Build: \(BuildInfo.version) (\(BuildInfo.gitHash))")
        lines.append("Exported: \(now)")
        lines.append("Entries: \(entries.count)")
        lines.append("========================")
        lines.append("")

        let entryLines = entries.reversed().map { "[\($0.formattedTime)] [\($0.category)] \($0.message)" }
        lines.append(contentsOf: entryLines)

        return lines.joined(separator: "\n")
    }

    /// Formatted export specifically for pasting into an LLM for analysis.
    var exportTextForDebug: String {
        let deviceName: String
        #if canImport(UIKit)
        deviceName = UIDevice.current.name
        #else
        deviceName = Host.current().localizedName ?? "Mac"
        #endif

        var lines: [String] = []
        lines.append("The following is a debug log from Blip (BLE mesh chat app).")
        lines.append("We are testing DM messaging between two phones.")
        lines.append("Build: \(BuildInfo.version) (\(BuildInfo.gitHash))")
        lines.append("Device: \(deviceName)")
        lines.append("")
        lines.append(exportText)
        lines.append("")
        lines.append("Please analyze this log and identify where the DM pipeline is failing.")

        return lines.joined(separator: "\n")
    }
}
