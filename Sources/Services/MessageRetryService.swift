import Foundation
import SwiftData
import os.log
import BlipProtocol
import BlipMesh
import BlipCrypto

// MARK: - Retry Configuration

/// Configuration constants for the message retry service.
enum RetryConfig {
    /// Maximum number of retry attempts per message.
    static let maxAttempts = 50
    /// Maximum time a message can stay in the retry queue (24 hours).
    static let maxQueueLifetime: TimeInterval = 86_400
    /// Maximum number of messages allowed in the retry queue.
    static let maxQueueSize = 500
    /// Base delay for exponential backoff (seconds).
    static let baseDelay: TimeInterval = 1.0
    /// Maximum backoff delay (10 minutes).
    static let maxDelay: TimeInterval = 600.0
    /// Jitter range as a fraction of the computed delay (0.0 to 1.0).
    static let jitterFraction = 0.25
    /// How often the retry loop scans for ready messages (seconds).
    static let scanInterval: TimeInterval = 2.0
}

// MARK: - Retry Service Delegate

protocol MessageRetryServiceDelegate: AnyObject, Sendable {
    func retryService(_ service: MessageRetryService, didPermanentlyFail messageID: UUID)
    func retryService(_ service: MessageRetryService, didSucceedRetry messageID: UUID)
    func retryService(_ service: MessageRetryService, willRetry messageID: UUID, attempt: Int, of maxAttempts: Int)
}

// MARK: - Message Retry Service

/// Monitors the `MessageQueue` and retries failed sends with exponential backoff.
///
/// Behavior:
/// - Scans the queue every 2 seconds for messages ready to retry
/// - Uses exponential backoff: `min(maxDelay, baseDelay * 2^attempt)` + jitter
/// - Messages expire after 24 hours or 50 attempts
/// - Queue is capped at 500 entries; oldest expired entries are evicted first
/// - Marks expired messages as failed and updates the corresponding Message status
final class MessageRetryService: @unchecked Sendable {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.blip", category: "MessageRetryService")

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let messageService: MessageService
    weak var delegate: (any MessageRetryServiceDelegate)?

    // MARK: - State

    private let retryQueue = DispatchQueue(label: "com.blip.retry", qos: .utility)
    private var scanTimer: DispatchSourceTimer?
    private var isRunning = false
    private let lock = NSLock()
    private var activeSends: Set<UUID> = []

    // MARK: - Init

    init(modelContainer: ModelContainer, messageService: MessageService) {
        self.modelContainer = modelContainer
        self.messageService = messageService
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the retry service. Begins periodic scanning of the message queue.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: retryQueue)
        timer.schedule(deadline: .now() + RetryConfig.scanInterval, repeating: RetryConfig.scanInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.scanAndRetry()
            }
        }
        timer.resume()
        scanTimer = timer
    }

    /// Stop the retry service.
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        isRunning = false
        scanTimer?.cancel()
        scanTimer = nil
    }

    // MARK: - Manual Trigger

    /// Manually trigger a retry scan. Useful after connectivity changes.
    @MainActor
    func triggerScan() async {
        await scanAndRetry()
    }

    // MARK: - Queue Management

    /// Remove all expired and failed entries from the queue.
    @MainActor
    func purgeExpired() async throws {
        let context = ModelContext(modelContainer)

        let descriptor = FetchDescriptor<MessageQueue>()
        let allEntries = try context.fetch(descriptor)

        var purgeCount = 0
        for entry in allEntries {
            if entry.isExpired || entry.status == .expired || entry.status == .failed {
                // Update the associated message status
                if let message = entry.message {
                    if message.status != .delivered && message.status != .read {
                        message.statusRaw = MessageStatus.queued.rawValue
                    }
                }
                context.delete(entry)
                purgeCount += 1
            }
        }

        if purgeCount > 0 {
            try context.save()
        }
    }

    /// Get the current queue depth.
    @MainActor
    func queueDepth() throws -> Int {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MessageQueue>()
        return try context.fetchCount(descriptor)
    }

    /// Get counts by status for diagnostics.
    @MainActor
    func queueStats() throws -> (queued: Int, sending: Int, failed: Int, expired: Int) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MessageQueue>()
        let allEntries = try context.fetch(descriptor)

        var queued = 0, sending = 0, failed = 0, expired = 0
        for entry in allEntries {
            switch entry.status {
            case .queued: queued += 1
            case .sending: sending += 1
            case .failed: failed += 1
            case .expired: expired += 1
            }
        }
        return (queued, sending, failed, expired)
    }

    // MARK: - Core Retry Logic

    @MainActor
    private func scanAndRetry() async {
        guard isRunning else { return }

        let context = ModelContext(modelContainer)

        do {
            // Fetch all queue entries sorted by next retry time
            let allEntries = try context.fetch(FetchDescriptor<MessageQueue>())
                .sorted { $0.nextRetryAt < $1.nextRetryAt }

            // Phase 1: Expire old entries
            for entry in allEntries {
                if entry.isExpired && entry.status != .expired {
                    markExpired(entry, context: context)
                }
            }

            // Phase 2: Enforce queue cap by evicting oldest expired entries
            try enforceQueueCap(context: context)

            // Phase 3: Retry ready entries
            let readyEntries = allEntries.filter { $0.isReady }

            for entry in readyEntries {
                // Skip if already being sent concurrently
                let entryID = entry.id
                let isActive: Bool = lock.withLock {
                    if activeSends.contains(entryID) { return true }
                    activeSends.insert(entryID)
                    return false
                }
                if isActive { continue }

                delegate?.retryService(self, willRetry: entryID, attempt: entry.attempts + 1, of: entry.maxAttempts)

                // Mark as sending
                entry.status = .sending
                try context.save()

                // Attempt the retry
                let success = await attemptRetry(entry: entry, context: context)

                if success {
                    // Remove from queue on success
                    if let message = entry.message {
                        message.status = .sent
                    }
                    context.delete(entry)
                    try context.save()

                    delegate?.retryService(self, didSucceedRetry: entryID)
                } else {
                    // Increment attempt counter and compute next backoff
                    entry.attempts += 1

                    if !entry.canRetry {
                        markFailed(entry, context: context)
                        CrashReportingService.shared.captureMessage(
                            "Message permanently failed after \(entry.maxAttempts) retries",
                            level: .warning
                        )
                        delegate?.retryService(self, didPermanentlyFail: entryID)
                    } else {
                        let delay = computeBackoff(attempt: entry.attempts)
                        entry.nextRetryAt = Date().addingTimeInterval(delay)
                        entry.status = .queued
                    }
                    try context.save()
                }

                // Remove from active sends
                lock.withLock { _ = activeSends.remove(entryID) }
            }

        } catch {
            // Log error but don't crash the retry loop
            #if DEBUG
            print("[MessageRetryService] Scan error: \(error)")
            #endif
        }
    }

    /// Attempt to resend a queued message through the message service.
    @MainActor
    private func attemptRetry(entry: MessageQueue, context: ModelContext) async -> Bool {
        guard let message = entry.message else { return false }

        do {
            let outcome = try await messageService.retryQueuedMessage(messageID: message.id)

            switch outcome {
            case .sent:
                return true
            case .deferred(let status):
                message.status = status
                try context.save()
                return false
            }
        } catch {
            logger.error("Retry send failed for \(message.id.uuidString, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private: Backoff Computation

    /// Compute exponential backoff with jitter.
    ///
    /// Formula: `min(maxDelay, baseDelay * 2^attempt)` + random jitter
    private func computeBackoff(attempt: Int) -> TimeInterval {
        let exponential = RetryConfig.baseDelay * pow(2.0, Double(min(attempt, 30)))
        let capped = min(exponential, RetryConfig.maxDelay)

        // Add jitter: +/- jitterFraction of the computed delay
        let jitterRange = capped * RetryConfig.jitterFraction
        let jitter = Double.random(in: -jitterRange ... jitterRange)

        return max(RetryConfig.baseDelay, capped + jitter)
    }

    // MARK: - Private: State Management

    private func markExpired(_ entry: MessageQueue, context: ModelContext) {
        entry.status = .expired
        if let message = entry.message {
            if message.status == .queued || message.status == .composing {
                message.statusRaw = MessageStatus.queued.rawValue
            }
        }
    }

    private func markFailed(_ entry: MessageQueue, context: ModelContext) {
        entry.status = .failed
        if let message = entry.message {
            message.statusRaw = MessageStatus.queued.rawValue
        }
    }

    /// Enforce the 500-message queue cap by evicting the oldest expired/failed entries first,
    /// then the oldest queued entries if still over cap.
    private func enforceQueueCap(context: ModelContext) throws {
        let allEntries = try context.fetch(FetchDescriptor<MessageQueue>())
            .sorted { $0.nextRetryAt < $1.nextRetryAt }

        guard allEntries.count > RetryConfig.maxQueueSize else { return }

        var toRemove = allEntries.count - RetryConfig.maxQueueSize

        // First pass: remove expired/failed
        for entry in allEntries where toRemove > 0 {
            if entry.status == .expired || entry.status == .failed {
                context.delete(entry)
                toRemove -= 1
            }
        }

        // Second pass: remove oldest queued if still over cap
        if toRemove > 0 {
            for entry in allEntries where toRemove > 0 {
                if entry.status == .queued {
                    context.delete(entry)
                    toRemove -= 1
                }
            }
        }

        try context.save()
    }
}
