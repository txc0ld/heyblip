import Foundation

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

    private(set) var entries: [Entry] = []
    private let maxEntries = 200

    func log(_ category: String, _ message: String, isError: Bool = false) {
        let entry = Entry(category: category, message: message, isError: isError)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast() }
        print("[Blip-\(category)] \(message)")
    }

    func clear() {
        entries.removeAll()
    }

    /// All entries formatted for clipboard export.
    var exportText: String {
        entries.reversed().map { "[\($0.formattedTime)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }
}
