import Foundation
import SwiftData
import os

/// Background sweep service that deletes expired messages from SwiftData.
///
/// Runs on a 5-minute timer and handles two cleanup strategies:
/// 1. Messages with an `expiresAt` date in the past
/// 2. Messages older than their channel's `maxRetention` policy
///
/// Deletes are batched to avoid blocking the main thread.
@MainActor
final class MessageCleanupService {

    private let modelContainer: ModelContainer
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.blip.app", category: "cleanup")

    /// How often to run the sweep (every 5 minutes).
    private let interval: TimeInterval = 300

    /// Max messages to delete per sweep to avoid blocking.
    private let batchSize = 100

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func start() {
        guard timer == nil else { return }

        sweep()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweep()
            }
        }

        DebugLogger.shared.log("CLEANUP", "Message cleanup service started (interval: \(Int(interval))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DebugLogger.shared.log("CLEANUP", "Message cleanup service stopped")
    }

    private func sweep() {
        let context = modelContainer.mainContext
        let now = Date()
        var totalDeleted = 0

        totalDeleted += sweepExpiredMessages(before: now, context: context)
        totalDeleted += sweepRetentionPolicy(now: now, context: context)

        if totalDeleted > 0 {
            do {
                try context.save()
                DebugLogger.shared.log("CLEANUP", "Swept \(totalDeleted) expired messages")
                logger.info("Swept \(totalDeleted) expired messages")
            } catch {
                DebugLogger.shared.log("CLEANUP", "Failed to save after sweep: \(error.localizedDescription)", isError: true)
                logger.error("Cleanup save failed: \(error.localizedDescription)")
            }
        }
    }

    /// Delete messages where expiresAt < now.
    private func sweepExpiredMessages(before date: Date, context: ModelContext) -> Int {
        // Fetch all messages with an expiresAt, then filter in memory.
        // SwiftData predicates don't reliably handle optional force-unwraps.
        let descriptor = FetchDescriptor<Message>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        do {
            let allMessages = try context.fetch(descriptor)
            let expired = allMessages.filter { msg in
                guard let expiresAt = msg.expiresAt else { return false }
                return expiresAt < date
            }
            let toDelete = expired.prefix(batchSize)
            for message in toDelete {
                context.delete(message)
            }
            return toDelete.count
        } catch {
            logger.error("Failed to fetch messages for expiry sweep: \(error.localizedDescription)")
            return 0
        }
    }

    /// Delete messages older than their channel's maxRetention.
    private func sweepRetentionPolicy(now: Date, context: ModelContext) -> Int {
        // Filter for channels with a finite retention policy (< 1 year; default is .infinity)
        let maxFiniteRetention: TimeInterval = 31_536_000
        let descriptor = FetchDescriptor<Channel>(
            predicate: #Predicate<Channel> { channel in
                channel.maxRetention > 0 && channel.maxRetention < maxFiniteRetention
            }
        )

        var deleted = 0

        do {
            let channels = try context.fetch(descriptor)
            for channel in channels {
                let cutoff = now.addingTimeInterval(-channel.maxRetention)
                let channelID = channel.id
                let msgDescriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { message in
                        message.channel?.id == channelID && message.createdAt < cutoff
                    },
                    sortBy: [SortDescriptor(\.createdAt, order: .forward)]
                )

                var stale = try context.fetch(msgDescriptor)
                if stale.count > batchSize {
                    stale = Array(stale.prefix(batchSize))
                }
                for message in stale {
                    context.delete(message)
                }
                deleted += stale.count
            }
        } catch {
            logger.error("Failed to sweep retention policy: \(error.localizedDescription)")
        }

        return deleted
    }
}
