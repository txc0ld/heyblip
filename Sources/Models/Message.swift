import Foundation
import SwiftData

// MARK: - Enums

enum MessageType: String, Codable, CaseIterable {
    case text
    case voiceNote
    case image
    case pttAudio
}

enum MessageStatus: String, Codable, CaseIterable {
    case composing
    case queued
    case encrypting
    case sent
    case delivered
    case read
}

// MARK: - Model

@Model
final class Message {
    @Attribute(.unique)
    var id: UUID

    var sender: User?
    var channel: Channel?
    var typeRaw: String
    var encryptedPayload: Data
    var statusRaw: String

    @Relationship
    var replyTo: Message?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment] = []

    var fragmentID: UUID?
    var fragmentIndex: Int?
    var fragmentTotal: Int?
    var isRelayed: Bool
    var hopCount: Int
    var createdAt: Date
    var expiresAt: Date?

    // MARK: - Inverse Relationships

    @Relationship(inverse: \MessageQueue.message)
    var queueEntries: [MessageQueue] = []

    // MARK: - Computed Properties

    var type: MessageType {
        get { MessageType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    var isFragmented: Bool {
        fragmentID != nil
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sender: User? = nil,
        channel: Channel? = nil,
        type: MessageType = .text,
        encryptedPayload: Data = Data(),
        status: MessageStatus = .queued,
        replyTo: Message? = nil,
        fragmentID: UUID? = nil,
        fragmentIndex: Int? = nil,
        fragmentTotal: Int? = nil,
        isRelayed: Bool = false,
        hopCount: Int = 0,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.sender = sender
        self.channel = channel
        self.typeRaw = type.rawValue
        self.encryptedPayload = encryptedPayload
        self.statusRaw = status.rawValue
        self.replyTo = replyTo
        self.fragmentID = fragmentID
        self.fragmentIndex = fragmentIndex
        self.fragmentTotal = fragmentTotal
        self.isRelayed = isRelayed
        self.hopCount = hopCount
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
