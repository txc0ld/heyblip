import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Centralized debug logger for the BLE Debug Overlay.
///
/// Stores recent log entries in-memory for real-time display. Used by
/// MessageService, AppCoordinator, and MeshRelayService to surface
/// protocol events in the debug UI without requiring Xcode console access.
@MainActor @Observable
final class DebugLogger {
    static let shared = DebugLogger()

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

    /// Deduplication window — identical category+message within this interval is suppressed.
    private let dedupWindow: TimeInterval = 0.5
    private var lastLogKey: String = ""
    private var lastLogTime: Date = .distantPast

    func log(_ category: String, _ message: String, isError: Bool = false) {
        // Deduplicate: skip if same category+message was logged within the dedup window
        let key = "\(category):\(message)"
        let now = Date()
        if key == lastLogKey, now.timeIntervalSince(lastLogTime) < dedupWindow {
            return
        }
        lastLogKey = key
        lastLogTime = now

        let entry = Entry(category: category, message: message, isError: isError)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast() }
        print("[Blip-\(category)] \(message)")

        // Forward as Sentry breadcrumb so mesh/BLE events appear as crash context
        CrashReportingService.shared.addBreadcrumb(
            category: category,
            message: message,
            level: isError ? .error : .info
        )
    }

    func clear() {
        entries.removeAll()
    }

    /// Thread-safe logging entry point for non-MainActor contexts.
    /// Dispatches to the main actor asynchronously.
    nonisolated static func emit(_ category: String, _ message: String, isError: Bool = false) {
        Task { @MainActor in
            shared.log(category, message, isError: isError)
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
