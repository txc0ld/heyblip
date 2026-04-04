import Foundation
import BackgroundTasks
import UserNotifications
import os.log

/// Manages BGTaskScheduler registration and execution for background mesh sync.
///
/// On background wake: checks BLE state, reconnects if needed, processes queued
/// messages, and schedules the next refresh. Minimum interval is 15 minutes
/// (iOS enforces this floor).
@MainActor
final class BackgroundTaskService {

    // MARK: - Constants

    static let meshSyncTaskID = "com.blip.mesh-sync"
    private static let minimumInterval: TimeInterval = 15 * 60 // 15 minutes

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.blip", category: "BackgroundTask")
    private weak var coordinator: AppCoordinator?

    // MARK: - Init

    init(coordinator: AppCoordinator? = nil) {
        self.coordinator = coordinator
    }

    // MARK: - Registration

    /// Register the background task handler. Call once at app launch
    /// (in `application(_:didFinishLaunchingWithOptions:)`).
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.meshSyncTaskID,
            using: nil
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await self?.handleMeshSync(task: bgTask)
            }
        }
        DebugLogger.shared.log("APP", "BGTask registered: \(Self.meshSyncTaskID)")
    }

    // MARK: - Scheduling

    /// Schedule the next background refresh. Safe to call multiple times —
    /// each call replaces the previous pending request.
    func scheduleNextSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.meshSyncTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            DebugLogger.shared.log("APP", "BGTask scheduled: next sync in ~15 min")
        } catch {
            DebugLogger.shared.log("APP", "BGTask schedule failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Execution

    /// Handle a background mesh sync wake.
    private func handleMeshSync(task: BGAppRefreshTask) async {
        DebugLogger.shared.log("APP", "BGTask executing: mesh-sync")

        // Schedule the next one immediately so it's queued even if this one fails.
        scheduleNextSync()

        // Set expiration handler — clean up if iOS kills the task early.
        // Uses DebugLogger.emit (nonisolated) since this closure runs off MainActor.
        task.expirationHandler = {
            DebugLogger.emit("APP", "BGTask expired", isError: true)
        }

        // Check BLE state and reconnect if needed.
        guard let coordinator else {
            task.setTaskCompleted(success: false)
            return
        }

        // If transports are stopped, restart them.
        if coordinator.isReady, coordinator.bleService?.state != .running {
            coordinator.start()
            DebugLogger.shared.log("APP", "BGTask: restarted transports")
        }

        // Process any queued messages via the retry service.
        if let retryService = coordinator.messageRetryService {
            await retryService.triggerScan()
            DebugLogger.shared.log("APP", "BGTask: processed message retry queue")
        }

        // Broadcast presence so peers know we're still alive.
        do {
            try await coordinator.messageService?.broadcastPresence()
            DebugLogger.shared.log("APP", "BGTask: presence broadcast sent")
        } catch {
            DebugLogger.shared.log("APP", "BGTask: presence broadcast failed: \(error.localizedDescription)", isError: true)
        }

        task.setTaskCompleted(success: true)
        DebugLogger.shared.log("APP", "BGTask completed: mesh-sync")
    }

    // MARK: - Background Notification

    /// Post a local notification informing the user that Blip is active in the background.
    func postBackgroundActiveNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Blip"
        content.body = "Blip is keeping you connected"
        content.sound = nil
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "com.blip.background-active",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DebugLogger.emit("APP", "Background notification failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Remove the background-active notification when the app returns to foreground.
    func removeBackgroundActiveNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["com.blip.background-active"]
        )
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["com.blip.background-active"]
        )
    }
}
