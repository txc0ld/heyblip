import Foundation
import SwiftData

/// One-time cleanup for duplicate DM channels caused by PeerID instability in Build 22.
/// Groups DM channels by dmConversationKey, merges messages into the most-active channel,
/// and deletes duplicates.
@MainActor
enum DuplicateChannelCleaner {

    /// Merge duplicate DM channels that share the same dmConversationKey.
    /// Returns the number of duplicate channels removed.
    @discardableResult
    static func cleanDuplicateDMChannels(context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.typeRaw == "dm" })
        let allDMs = try context.fetch(descriptor)

        // Group by dmConversationKey
        var groups: [String: [Channel]] = [:]
        for channel in allDMs {
            guard let key = channel.dmConversationKey else { continue }
            groups[key, default: []].append(channel)
        }

        var removedCount = 0
        for (key, channels) in groups where channels.count > 1 {
            // Pick the channel with most recent activity (or most messages as tiebreaker)
            let sorted = channels.sorted { a, b in
                if a.lastActivityAt != b.lastActivityAt {
                    return a.lastActivityAt > b.lastActivityAt
                }
                return a.messages.count > b.messages.count
            }
            let keeper = sorted[0]
            let duplicates = sorted.dropFirst()

            for dup in duplicates {
                // Move messages to keeper
                for message in dup.messages {
                    message.channel = keeper
                }
                // Move memberships (avoid duplicates)
                for membership in dup.memberships {
                    let userAlreadyInKeeper = keeper.memberships.contains { $0.user?.id == membership.user?.id }
                    if !userAlreadyInKeeper {
                        membership.channel = keeper
                    } else {
                        context.delete(membership)
                    }
                }
                context.delete(dup)
                removedCount += 1
                DebugLogger.shared.log("CLEANUP", "Merged duplicate DM channel (key=\(DebugLogger.redactHex(key))) into primary")
            }

            // Update keeper activity
            if let latestMsg = keeper.messages.sorted(by: { $0.createdAt > $1.createdAt }).first {
                keeper.lastActivityAt = latestMsg.createdAt
            }
        }

        if removedCount > 0 {
            try context.save()
            DebugLogger.shared.log("CLEANUP", "Removed \(removedCount) duplicate DM channel(s)")
        }

        return removedCount
    }
}
