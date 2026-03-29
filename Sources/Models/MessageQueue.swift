import Foundation
import SwiftData

// MARK: - Enums

enum QueueTransport: String, Codable, CaseIterable {
    case ble
    case wifi
    case cellular
    case any
}

enum QueueStatus: String, Codable, CaseIterable {
    case queued
    case sending
    case failed
    case expired
}

// MARK: - Model

@Model
final class MessageQueue {
    @Attribute(.unique)
    var id: UUID

    var message: Message?
    var attempts: Int
    var maxAttempts: Int
    var nextRetryAt: Date
    var expiresAt: Date
    var transportRaw: String
    var statusRaw: String

    // MARK: - Computed Properties

    var transport: QueueTransport {
        get { QueueTransport(rawValue: transportRaw) ?? .any }
        set { transportRaw = newValue.rawValue }
    }

    var status: QueueStatus {
        get { QueueStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    var canRetry: Bool {
        attempts < maxAttempts && !isExpired && status != .expired
    }

    var isReady: Bool {
        status == .queued && Date() >= nextRetryAt && canRetry
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        message: Message? = nil,
        attempts: Int = 0,
        maxAttempts: Int = 50,
        nextRetryAt: Date = Date(),
        expiresAt: Date? = nil,
        transport: QueueTransport = .any,
        status: QueueStatus = .queued
    ) {
        self.id = id
        self.message = message
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.nextRetryAt = nextRetryAt
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(86_400) // 24 hours
        self.transportRaw = transport.rawValue
        self.statusRaw = status.rawValue
    }
}
