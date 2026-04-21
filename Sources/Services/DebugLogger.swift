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
        let id = UUID()
        let timestamp = Date()
        let category: String
        let message: String
        let isError: Bool

        var formattedTime: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: timestamp)
        }
    }

    /// Unique session ID to correlate logs across devices.
    let sessionID = UUID()

    private(set) var entries: [Entry] = []
    private let maxEntries = 500

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
