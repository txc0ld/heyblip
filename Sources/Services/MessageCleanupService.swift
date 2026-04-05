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
        // TODO: BDEV-61 SwiftData's predicate macro still emits Sendable warnings here under the
        // current toolchain. Keep the scoped fetch anyway to avoid loading the full message table.
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.expiresAt != nil }
        )

        do {
            let expired = try context.fetch(descriptor)
                .filter { msg in
                guard let expiresAt = msg.expiresAt else { return false }
                return expiresAt < date
            }
                .sorted { $0.createdAt < $1.createdAt }
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
        // TODO: BDEV-61 Keep these predicates for hot-path performance even though the current
        // SwiftData macro expansion still triggers strict-concurrency Sendable warnings.
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
                    }
                )

                var stale = try context.fetch(msgDescriptor)
                    .sorted { $0.createdAt < $1.createdAt }
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
